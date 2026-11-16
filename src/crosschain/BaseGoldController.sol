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
    mapping(bytes32 => bytes32) public requestHashes;
    mapping(bytes32 => G.State) public states;
    mapping(bytes32 => bytes32) public responseMessages;
    mapping(bytes32 => bool) public returnsProcessed;
    event BackingLocked(bytes32 indexed id, address indexed recipient, uint256 amount, bytes32 messageId);
    event RequestSettled(bytes32 indexed id, bool accepted, uint256 output, bytes32 messageId);
    event BackingReturned(bytes32 indexed id, address indexed recipient, uint256 amount);

    constructor(address endpoint_, address admin, uint32 local_, uint32 remote_, address asset_, address oracle_)
        GoldMailbox(endpoint_, admin, local_, remote_)
    {
        if (asset_.code.length == 0 || oracle_.code.length == 0) revert InvalidConfiguration();
        asset = ICanonicalGold(asset_);
        if (asset.MAX_CANONICAL_SUPPLY() != 193e18 || !asset.globalSupplyCapInitialized()) {
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
        if (kind != G.Kind.Cancel && block.timestamp <= r.deadline) {
            if (r.kind == G.Kind.Mint) {
                try oracle.mintOutput(r.amount) returns (uint256 quote) {
                    if (quote > 0 && quote >= r.minOutput) {
                        try asset.mint(address(this), quote) {
                            backingLiability += quote;
                            output = quote;
                            accepted = true;
                        } catch {} // Terminal rejection, never an unbacked remote credit.
                    }
                } catch {}
            } else {
                try oracle.redeemOutput(r.amount) returns (uint256 quote) {
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
