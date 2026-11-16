// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldMailbox} from "./GoldMailbox.sol";
import {GoldMessages as G, IGoldSettlementOracle} from "./GoldMessages.sol";

interface ICanonicalGold is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function MAX_CANONICAL_SUPPLY() external view returns (uint256);
    function globalSupplyCapInitialized() external view returns (bool);
}

/// @notice Development canonical escrow and terminal request authority. Not deployed.
contract BaseGoldController is GoldMailbox {
    ICanonicalGold public immutable asset;
    IGoldSettlementOracle public immutable oracle;
    uint256 public backingLiability;
    uint256 public maxPerOperation;
    uint256 public maxOutstandingBacking;
    uint256 public exposureCapacity;
    uint256 private exposureAvailable;
    uint256 private exposureUpdatedAt;
    mapping(bytes32 => bytes32) public requestHashes;
    mapping(bytes32 => G.State) public states;
    mapping(bytes32 => bytes32) public responseMessages;
    mapping(bytes32 => bool) public returnsProcessed;
    event BackingLocked(bytes32 indexed id, address indexed recipient, uint256 amount, bytes32 messageId);
    event RequestSettled(bytes32 indexed id, bool accepted, uint256 output, bytes32 messageId);
    event BackingReturned(bytes32 indexed id, address indexed recipient, uint256 amount);
    event ExposureLimitsConfigured(uint256 maxPerOperation, uint256 maxOutstandingBacking, uint256 capacityPerDay);
    error ExposureLimitExceeded();

    /// @notice Configure staged exposure while paused. Changes never replenish previously spent budget.
    /// @dev Token bucket refills at capacity/24h; exits never depend on these entry limits.
    function configureExposureLimits(uint256 perOperation, uint256 outstanding, uint256 capacityPerDay)
        external
        onlyOwner
        whenPaused
    {
        uint256 cap = asset.MAX_CANONICAL_SUPPLY();
        if (
            perOperation == 0 || outstanding == 0 || capacityPerDay == 0 || outstanding > cap || capacityPerDay > cap
                || perOperation > outstanding || perOperation > capacityPerDay
        ) revert InvalidConfiguration();
        uint256 previous = availableExposure();
        exposureAvailable = exposureUpdatedAt == 0 ? capacityPerDay : Math.min(previous, capacityPerDay);
        exposureCapacity = capacityPerDay;
        exposureUpdatedAt = block.timestamp;
        maxPerOperation = perOperation;
        maxOutstandingBacking = outstanding;
        emit ExposureLimitsConfigured(perOperation, outstanding, capacityPerDay);
    }

    function availableExposure() public view returns (uint256) {
        if (exposureCapacity == 0) return 0;
        uint256 elapsed = block.timestamp - exposureUpdatedAt;
        if (elapsed >= 1 days) return exposureCapacity;
        return Math.min(exposureCapacity, exposureAvailable + Math.mulDiv(exposureCapacity, elapsed, 1 days));
    }

    function canAddBacking(uint256 amount) public view returns (bool) {
        return amount > 0 && amount <= maxPerOperation && backingLiability <= maxOutstandingBacking
            && amount <= maxOutstandingBacking - backingLiability && amount <= availableExposure();
    }

    function setPaused(bool value) public override onlyOwner {
        if (!value && exposureCapacity == 0) revert InvalidConfiguration();
        super.setPaused(value);
    }

    function _consumeExposure(uint256 amount) private {
        // Called only after canAddBacking succeeds, inside a nonreentrant entry/delivery.
        exposureAvailable = availableExposure() - amount;
        exposureUpdatedAt = block.timestamp;
    }

    constructor(address endpoint_, address admin, uint32 local_, uint32 remote_, address asset_, address oracle_)
        GoldMailbox(endpoint_, admin, local_, remote_)
    {
        if (asset_.code.length == 0 || oracle_.code.length == 0) revert InvalidConfiguration();
        asset = ICanonicalGold(asset_);
        if (asset.MAX_CANONICAL_SUPPLY() == 0 || !asset.globalSupplyCapInitialized()) {
            revert InvalidConfiguration();
        }
        oracle = IGoldSettlementOracle(oracle_);
    }

    function bridgeToRobinhood(uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 id, bytes32 messageId)
    {
        if (amount == 0 || recipient == address(0) || bytes32(uint256(uint160(recipient))) == peers[remoteEid]) revert InvalidTransfer();
        if (!canAddBacking(amount)) revert ExposureLimitExceeded();
        _consumeExposure(amount);
        _takeExact(asset, msg.sender, amount);
        backingLiability += amount;
        id = _newId();
        messageId = _queue(G.Kind.Credit, abi.encode(G.Transfer(id, recipient, amount)));
        emit BackingLocked(id, recipient, amount, messageId);
    }

    function _handle(G.Kind kind, bytes memory body) internal override {
        if (kind == G.Kind.Return) {
            G.Transfer memory t = abi.decode(body, (G.Transfer));
            if (returnsProcessed[t.id]) revert InvalidMessage();
            if (t.amount == 0 || t.amount > backingLiability) revert InvalidTransfer();
            returnsProcessed[t.id] = true;
            backingLiability -= t.amount;
            _payExact(asset, t.recipient, t.amount);
            emit BackingReturned(t.id, t.recipient, t.amount);
            return;
        }
        if (kind != G.Kind.Mint && kind != G.Kind.Redeem && kind != G.Kind.Cancel) revert InvalidMessage();
        G.Request memory r = abi.decode(body, (G.Request));
        if (
            (r.kind != G.Kind.Mint && r.kind != G.Kind.Redeem) || (kind != G.Kind.Cancel && kind != r.kind)
                || r.id == bytes32(0) || r.owner == address(0) || r.recipient == address(0) || r.amount == 0
        ) revert InvalidMessage();
        bytes32 digest = keccak256(body);
        if (requestHashes[r.id] != bytes32(0)) {
            if (requestHashes[r.id] != digest) revert InvalidMessage();
            return; // A terminal outcome already exists, dispatchable without recomputation.
        }
        // Pause new oracle decisions in either direction; cancellations and already terminal outcomes remain available.
        if (kind != G.Kind.Cancel && paused()) revert EnforcedPause();
        requestHashes[r.id] = digest;
        uint256 output;
        bool accepted;
        if (
            kind != G.Kind.Cancel && block.timestamp <= r.deadline && G.validPrice(r.usdgPrice)
                && r.deadline >= r.usdgPrice.observedAt && r.deadline - r.usdgPrice.observedAt <= G.MAX_REQUEST_AGE
        ) {
            if (r.kind == G.Kind.Mint) {
                try oracle.mintOutput(r.amount, r.usdgPrice) returns (uint256 quote) {
                    if (quote > 0 && quote >= r.minOutput && canAddBacking(quote)) {
                        try asset.mint(address(this), quote) {
                            _consumeExposure(quote);
                            backingLiability += quote;
                            output = quote;
                            accepted = true;
                        } catch {} // Terminal rejection, never an unbacked remote credit.
                    }
                } catch {}
            } else {
                try oracle.redeemOutput(r.amount, r.usdgPrice) returns (uint256 quote) {
                    uint256 net = quote - Math.mulDiv(quote, 25, 10000);
                    if (quote > 0 && net >= r.minOutput && r.amount <= backingLiability) {
                        // A failed canonical burn retries delivery; it does not pay or restore remote tokens.
                        asset.burn(r.amount);
                        backingLiability -= r.amount;
                        output = quote;
                        accepted = true;
                    }
                } catch {}
            }
        }
        states[r.id] = accepted ? G.State.Accepted : G.State.Rejected;
        bytes32 messageId = _queue(G.Kind.Result, abi.encode(G.Result(r.id, digest, accepted, output)));
        responseMessages[r.id] = messageId;
        emit RequestSettled(r.id, accepted, output, messageId);
    }
}
