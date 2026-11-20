// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldMailboxUpgradeable} from "./GoldMailboxUpgradeable.sol";
import {GoldMessages as G} from "./GoldMessages.sol";
import {GoldFeedReader, IGoldAggregator} from "./GoldFeedReader.sol";

/// @notice Development remote token AND USDG intent engine. Only authenticated Base results mint.
/// @dev UUPS engine: only authenticated canonical backing credits mint. Sweeps exclude user liabilities.
contract RobinhoodGoldEngine is GoldMailboxUpgradeable, ERC20Upgradeable, UUPSUpgradeable {
    /// @notice Explicit target-chain treasury; never assumes a Base contract exists on Robinhood.
    address public FEE_RECIPIENT;
    IERC20Metadata public usdg;
    IGoldAggregator public usdgPriceFeed;
    uint256 private usdgScale;
    mapping(bytes32 => G.Request) public requests;
    mapping(bytes32 => G.State) public states;
    mapping(bytes32 => bool) public creditsProcessed;
    uint256 public pendingUSDG;
    uint256 public refundableUSDG;
    uint256 public queuedUSDG;
    uint256 public claimableUSDG;
    mapping(bytes32 => uint256) public claimablePayout;

    struct Payout {
        bytes32 id;
        address recipient;
        uint256 gross;
    }
    Payout[] public payouts;
    uint256 public payoutHead;
    event IntentCreated(bytes32 indexed id, G.Kind kind, address indexed owner, bytes32 messageId);
    event CancellationRequested(bytes32 indexed id, bytes32 messageId);
    event IntentResolved(bytes32 indexed id, bool accepted, uint256 output);
    event RefundClaimed(bytes32 indexed id, address indexed recipient, uint256 amount);
    event RedemptionPaid(bytes32 indexed id, address indexed recipient, uint256 net, uint256 fee);
    event RedemptionReady(bytes32 indexed id, address indexed recipient, uint256 gross);
    event BridgeBurned(bytes32 indexed id, address indexed recipient, uint256 amount, bytes32 messageId);

    bytes32 public constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public redeemFeeBps;
    uint256 public oracleStalenessThreshold;
    mapping(address => bool) public isAllowedCollateral;
    mapping(bytes32 => uint256) public requestFeeBps;
    mapping(bytes32 => uint256) public requestMinimumNet;
    event SweptToTreasury(address indexed token, uint256 amount);
    event CollateralStatusUpdated(address indexed token, bool allowed);
    event RedeemFeeUpdated(uint256 previousFee, uint256 newFee);
    event USDGPriceFeedUpdated(address indexed feed);
    event OracleStalenessThresholdUpdated(uint256 threshold);

    struct InitConfig {
        address endpoint;
        address admin;
        address reserveManager;
        address upgrader;
        uint32 localEid;
        uint32 remoteEid;
        address usdg;
        address usdgFeed;
        address treasury;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(InitConfig calldata c) external initializer {
        if (
            c.reserveManager == address(0) || c.upgrader == address(0) || c.usdg.code.length == 0
                || IERC20Metadata(c.usdg).decimals() != 6 || c.treasury == address(0) || c.treasury == address(this)
        ) revert InvalidConfiguration();
        __GoldMailbox_init(c.endpoint, c.admin, c.localEid, c.remoteEid);
        __ERC20_init("Syncrate Gold", "SGLD");
        _grantRole(RESERVE_MANAGER_ROLE, c.reserveManager);
        _grantRole(UPGRADER_ROLE, c.upgrader);
        usdg = IERC20Metadata(c.usdg);
        FEE_RECIPIENT = c.treasury;
        _setUSDGFeed(c.usdgFeed);
        oracleStalenessThreshold = G.MAX_FEED_AGE;
        redeemFeeBps = 25;
        isAllowedCollateral[c.usdg] = true;
    }

    function TREASURY() external view returns (address) {
        return FEE_RECIPIENT;
    }
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function setCollateralToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token != address(usdg)) revert InvalidConfiguration();
        isAllowedCollateral[token] = allowed;
        emit CollateralStatusUpdated(token, allowed);
    }

    function setRedeemFee(uint256 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee > MAX_FEE_BPS) revert InvalidConfiguration();
        emit RedeemFeeUpdated(redeemFeeBps, fee);
        redeemFeeBps = fee;
    }

    function setOracleStalenessThreshold(uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold == 0 || threshold > G.MAX_FEED_AGE) revert InvalidConfiguration();
        oracleStalenessThreshold = threshold;
        emit OracleStalenessThresholdUpdated(threshold);
    }

    function _setUSDGFeed(address feed) internal {
        if (feed.code.length == 0) revert InvalidConfiguration();
        (bool ok, bytes memory value) = feed.staticcall(abi.encodeWithSignature("description()"));
        if (!ok || keccak256(bytes(abi.decode(value, (string)))) != keccak256("USDG / USD")) {
            revert InvalidConfiguration();
        }
        usdgPriceFeed = IGoldAggregator(feed);
        usdgScale = GoldFeedReader.scale(usdgPriceFeed);
        emit USDGPriceFeedUpdated(feed);
    }

    function setUSDGPriceFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setUSDGFeed(feed);
    }

    function availableTreasuryUSDG() public view returns (uint256) {
        uint256 balance = usdg.balanceOf(address(this));
        uint256 reserved = totalReservedUSDG();
        return balance > reserved ? balance - reserved : 0;
    }

    function sweepToTreasury(address token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token != address(usdg)) revert InvalidConfiguration();
        uint256 amount = Math.mulDiv(availableTreasuryUSDG(), 40, 100);
        if (amount == 0) revert InvalidTransfer();
        _payExact(usdg, FEE_RECIPIENT, amount);
        emit SweptToTreasury(token, amount);
    }

    function mint(uint256 amount, address token) external returns (bytes32 id, bytes32 messageId) {
        if (token != address(usdg)) revert InvalidConfiguration();
        return requestMint(amount, 0, block.timestamp + G.MAX_REQUEST_AGE, msg.sender);
    }

    function redeem(uint256 amount, address token) external returns (bytes32 id, bytes32 messageId) {
        if (token != address(usdg)) revert InvalidConfiguration();
        return requestRedemption(amount, 0, block.timestamp + G.MAX_REQUEST_AGE, msg.sender);
    }

    function processQueue(uint256 count) external {
        processPayouts(count);
    }

    function getQueueLength() external view returns (uint256) {
        return payouts.length;
    }

    function currentUSDGPrice() public view returns (G.PriceSnapshot memory) {
        return GoldFeedReader.snapshot(usdgPriceFeed, usdgScale, oracleStalenessThreshold);
    }

    function getRequest(bytes32 id) external view returns (G.Request memory) {
        return requests[id];
    }

    function requestMint(uint256 amount, uint256 minOutput, uint256 deadline, address recipient)
        public
        whenNotPaused
        nonReentrant
        returns (bytes32 id, bytes32 messageId)
    {
        if (!isAllowedCollateral[address(usdg)]) revert InvalidConfiguration();
        _takeExact(usdg, msg.sender, amount);
        pendingUSDG += amount;
        return _request(G.Kind.Mint, amount, minOutput, deadline, recipient);
    }

    function requestRedemption(uint256 amount, uint256 minOutput, uint256 deadline, address recipient)
        public
        nonReentrant
        returns (bytes32 id, bytes32 messageId)
    {
        _burn(msg.sender, amount); // No spendable remote claim while Base retires its backing.
        return _request(G.Kind.Redeem, amount, minOutput, deadline, recipient);
    }

    function _request(G.Kind kind, uint256 amount, uint256 minOutput, uint256 deadline, address recipient)
        private
        returns (bytes32 id, bytes32 messageId)
    {
        if (
            amount == 0 || recipient == address(0) || recipient == address(this) || deadline <= block.timestamp
                || deadline - block.timestamp > G.MAX_REQUEST_AGE
        ) revert InvalidTransfer();
        _peer();
        id = _newId();
        if (kind == G.Kind.Redeem) {
            requestFeeBps[id] = redeemFeeBps;
            requestMinimumNet[id] = minOutput;
            // net = gross - floor(gross * fee / BPS); invert without rejecting a valid one-unit payout.
            minOutput = minOutput == 0
                ? 0
                : Math.mulDiv(minOutput - 1, BPS_DENOMINATOR, BPS_DENOMINATOR - redeemFeeBps) + 1;
        }
        G.Request memory r = G.Request(id, kind, msg.sender, recipient, amount, minOutput, deadline, currentUSDGPrice());
        requests[id] = r;
        states[id] = G.State.Pending;
        messageId = _queue(kind, abi.encode(r));
        emit IntentCreated(id, kind, msg.sender, messageId);
    }

    /// @notice Only asks Base for a terminal outcome. Passing a deadline NEVER refunds locally.
    function requestCancellation(bytes32 id) external nonReentrant returns (bytes32 messageId) {
        G.Request memory r = requests[id];
        if (r.owner != msg.sender || states[id] != G.State.Pending || block.timestamp <= r.deadline) {
            revert InvalidMessage();
        }
        messageId = _queue(G.Kind.Cancel, abi.encode(r));
        emit CancellationRequested(id, messageId);
    }

    function claimRefund(bytes32 id, address recipient) external nonReentrant {
        G.Request memory r = requests[id];
        if (r.owner != msg.sender || r.kind != G.Kind.Mint || states[id] != G.State.Rejected) revert InvalidMessage();
        states[id] = G.State.Refunded;
        refundableUSDG -= r.amount;
        _payExact(usdg, recipient, r.amount);
        emit RefundClaimed(id, recipient, r.amount);
    }

    function bridgeToBase(uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 id, bytes32 messageId)
    {
        if (amount == 0 || recipient == address(0) || bytes32(uint256(uint160(recipient))) == peers[remoteEid]) revert InvalidTransfer();
        _peer();
        _burn(msg.sender, amount);
        id = _newId();
        messageId = _queue(G.Kind.Return, abi.encode(G.Transfer(id, recipient, amount)));
        emit BridgeBurned(id, recipient, amount, messageId);
    }

    function fundLiquidity(uint256 amount) external nonReentrant {
        _takeExact(usdg, msg.sender, amount);
    }

    function totalReservedUSDG() public view returns (uint256) {
        return pendingUSDG + refundableUSDG + queuedUSDG + claimableUSDG;
    }

    function payoutCount() external view returns (uint256) {
        return payouts.length;
    }

    /// @notice Permissionless FIFO; pending deposits and refundable funds cannot fund payouts.
    function processPayouts(uint256 maxCount) public nonReentrant {
        if (maxCount == 0 || maxCount > 100) revert InvalidMessage();
        uint256 count;
        while (payoutHead < payouts.length && count < maxCount) {
            Payout memory p = payouts[payoutHead];
            uint256 balance = usdg.balanceOf(address(this));
            uint256 protected = pendingUSDG + refundableUSDG + claimableUSDG;
            if (balance < protected || balance - protected < p.gross) break;
            ++payoutHead;
            ++count;
            queuedUSDG -= p.gross;
            claimableUSDG += p.gross;
            claimablePayout[p.id] = p.gross;
            emit RedemptionReady(p.id, p.recipient, p.gross);
        }
    }

    /// @notice Pull payout prevents a frozen recipient or treasury from blocking the FIFO allocator.
    function claimRedemption(bytes32 id, address recipient) external nonReentrant {
        G.Request memory r = requests[id];
        uint256 gross = claimablePayout[id];
        if (msg.sender != r.recipient || gross == 0) revert InvalidMessage();
        claimablePayout[id] = 0;
        claimableUSDG -= gross;
        uint256 fee = Math.mulDiv(gross, requestFeeBps[id], BPS_DENOMINATOR);
        _payExact(usdg, recipient, gross - fee);
        if (fee != 0) _payExact(usdg, FEE_RECIPIENT, fee);
        emit RedemptionPaid(id, recipient, gross - fee, fee);
    }

    function _handle(G.Kind kind, bytes memory body) internal override {
        if (kind == G.Kind.Credit) {
            G.Transfer memory t = abi.decode(body, (G.Transfer));
            if (creditsProcessed[t.id] || t.amount == 0 || t.recipient == address(this)) revert InvalidMessage();
            creditsProcessed[t.id] = true;
            _credit(t.recipient, t.amount);
            return;
        }
        if (kind != G.Kind.Result) revert InvalidMessage();
        G.Result memory result = abi.decode(body, (G.Result));
        G.Request memory r = requests[result.id];
        if (states[result.id] != G.State.Pending || keccak256(abi.encode(r)) != result.requestHash) {
            revert InvalidMessage();
        }
        states[result.id] = result.accepted ? G.State.Accepted : G.State.Rejected;
        if (r.kind == G.Kind.Mint) {
            pendingUSDG -= r.amount;
            if (result.accepted) {
                if (result.output == 0 || result.output < r.minOutput) revert InvalidMessage();
                _credit(r.recipient, result.output);
            } else {
                if (result.output != 0) revert InvalidMessage();
                refundableUSDG += r.amount;
            }
        } else if (r.kind == G.Kind.Redeem) {
            if (result.accepted) {
                uint256 net = result.output - Math.mulDiv(result.output, requestFeeBps[result.id], BPS_DENOMINATOR);
                if (result.output == 0 || net < requestMinimumNet[result.id]) revert InvalidMessage();
                queuedUSDG += result.output;
                payouts.push(Payout(result.id, r.recipient, result.output));
            } else {
                if (result.output != 0) revert InvalidMessage();
                _credit(r.owner, r.amount);
            }
        } else {
            revert InvalidMessage();
        }
        emit IntentResolved(result.id, result.accepted, result.output);
    }

    function _credit(address recipient, uint256 amount) private {
        // Called only for authenticated Base backing credits, accepted mints or
        // rejected redemption restorations. Base's inventory cap is authoritative;
        // a second fixed remote ceiling would strand valid credits after increases.
        _mint(recipient, amount);
    }
}
