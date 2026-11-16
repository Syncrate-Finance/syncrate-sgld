// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldMailbox} from "./GoldMailbox.sol";
import {GoldMessages as G} from "./GoldMessages.sol";

/// @notice Development remote token AND USDG intent engine. Only authenticated Base results mint.
/// @dev No owner mint, timeout refund, liquidity sweep or separate local mint role.
contract RobinhoodGold is GoldMailbox, ERC20 {
    uint256 public constant MAX_SUPPLY = 193e18;
    address public constant FEE_RECIPIENT = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;
    IERC20Metadata public immutable usdg;
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

    constructor(address endpoint_, address admin, uint32 local_, uint32 remote_, address usdg_)
        GoldMailbox(endpoint_, admin, local_, remote_)
        ERC20("Syncrate Gold", "SGLD")
    {
        if (usdg_.code.length == 0 || IERC20Metadata(usdg_).decimals() != 6) revert InvalidConfiguration();
        usdg = IERC20Metadata(usdg_);
    }

    function requestMint(uint256 amount, uint256 minOutput, uint256 deadline, address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 id, bytes32 messageId)
    {
        _takeExact(usdg, msg.sender, amount);
        pendingUSDG += amount;
        return _request(G.Kind.Mint, amount, minOutput, deadline, recipient);
    }

    function requestRedemption(uint256 amount, uint256 minOutput, uint256 deadline, address recipient)
        external
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
        if (amount == 0 || recipient == address(0) || recipient == address(this) || deadline <= block.timestamp) revert InvalidTransfer();
        _getPeerOrRevert(remoteEid);
        id = _newId();
        G.Request memory r = G.Request(id, kind, msg.sender, recipient, amount, minOutput, deadline);
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
        _getPeerOrRevert(remoteEid);
        _burn(msg.sender, amount);
        id = _newId();
        messageId = _queue(G.Kind.Return, abi.encode(G.Transfer(id, recipient, amount)));
        emit BridgeBurned(id, recipient, amount, messageId);
    }

    function fundLiquidity(uint256 amount) external nonReentrant {
        _takeExact(usdg, msg.sender, amount);
    }

    function totalReservedUSDG() external view returns (uint256) {
        return pendingUSDG + refundableUSDG + queuedUSDG + claimableUSDG;
    }

    function payoutCount() external view returns (uint256) {
        return payouts.length;
    }

    /// @notice Permissionless FIFO; pending deposits and refundable funds cannot fund payouts.
    function processPayouts(uint256 maxCount) external nonReentrant {
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
        uint256 fee = Math.mulDiv(gross, 25, 10000);
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
                uint256 net = result.output - Math.mulDiv(result.output, 25, 10000);
                if (result.output == 0 || net < r.minOutput) revert InvalidMessage();
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
        if (amount > MAX_SUPPLY - totalSupply()) revert InvalidTransfer();
        _mint(recipient, amount);
    }
}
