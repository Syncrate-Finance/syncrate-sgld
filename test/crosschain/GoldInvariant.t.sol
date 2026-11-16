// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {GoldFixture, GoldEndpointMock, GoldUSDGMock, GoldFeedMock} from "./GoldFixture.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {RobinhoodGold} from "../../src/crosschain/RobinhoodGold.sol";
import {GoldMailbox} from "../../src/crosschain/GoldMailbox.sol";

/// @dev Ghost claims track actual pending economic rights, not just E minus remote supply.
contract GoldCrosschainHandler is Test {
    SGLDTokenCapped canonical;
    BaseGoldController base;
    RobinhoodGold remote;
    GoldUSDGMock usdg;
    GoldEndpointMock baseEndpoint;
    GoldEndpointMock remoteEndpoint;
    GoldFeedMock goldFeed;
    GoldFeedMock usdgFeed;

    struct Entry {
        bool fromBase;
        bytes32 messageId;
    }
    Entry[] public messages;
    bytes32[] public intents;
    mapping(bytes32 => bool) applied;
    int256 public pendingCredits;
    int256 public pendingReturns;
    int256 public pendingRetirements;
    uint256 public deliveries;

    constructor(
        SGLDTokenCapped c,
        BaseGoldController b,
        RobinhoodGold r,
        GoldUSDGMock u,
        GoldEndpointMock be,
        GoldEndpointMock re,
        GoldFeedMock gf,
        GoldFeedMock uf
    ) {
        canonical = c;
        base = b;
        remote = r;
        usdg = u;
        baseEndpoint = be;
        remoteEndpoint = re;
        goldFeed = gf;
        usdgFeed = uf;
        c.approve(address(b), type(uint256).max);
        u.approve(address(r), type(uint256).max);
    }

    function bridgeIn(uint256 amount) external {
        uint256 balance = canonical.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        (, bytes32 messageId) = base.bridgeToRobinhood(amount, address(this));
        pendingCredits += int256(amount);
        messages.push(Entry(true, messageId));
    }

    function bridgeOut(uint256 amount) external {
        uint256 balance = remote.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        (, bytes32 messageId) = remote.bridgeToBase(amount, address(this));
        pendingReturns += int256(amount);
        messages.push(Entry(false, messageId));
    }

    function mint(uint256 amount, bool unfavorable) external {
        amount = bound(amount, 1, 800_000e6);
        if (amount > usdg.balanceOf(address(this))) return;
        (bytes32 id, bytes32 messageId) =
            remote.requestMint(amount, unfavorable ? 193e18 : 0, block.timestamp + 1 hours, address(this));
        intents.push(id);
        messages.push(Entry(false, messageId));
    }

    function redeem(uint256 amount, bool unfavorable) external {
        uint256 balance = remote.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        (bytes32 id, bytes32 messageId) = remote.requestRedemption(
            amount, unfavorable ? type(uint128).max : 0, block.timestamp + 1 hours, address(this)
        );
        pendingRetirements += int256(amount);
        intents.push(id);
        messages.push(Entry(false, messageId));
    }

    function cancel(uint256 seed) external {
        if (intents.length == 0) return;
        bytes32 id = intents[seed % intents.length];
        G.Request memory r = _request(id);
        if (remote.states(id) != G.State.Pending || block.timestamp <= r.deadline) return;
        messages.push(Entry(false, remote.requestCancellation(id)));
    }

    function advance(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 0, 2 hours));
        // Keep prices fresh here; unit tests cover each oracle failure case separately.
        goldFeed.set(4000e8, block.timestamp, 1, 1);
        usdgFeed.set(1e8, block.timestamp, 1, 1);
    }

    function competingMint(uint256 amount) external {
        amount = bound(amount, 0, 194e18);
        try canonical.mint(address(this), amount) {} catch {}
    }

    function deliver(uint256 seed) external {
        if (messages.length == 0) return;
        Entry memory e = messages[seed % messages.length];
        GoldMailbox source = e.fromBase ? GoldMailbox(address(base)) : GoldMailbox(address(remote));
        bytes memory payload = source.outbox(e.messageId);
        (, G.Kind kind, bytes memory body) = abi.decode(payload, (uint8, G.Kind, bytes));
        source.dispatch{value: 1}(e.messageId, "");
        G.State beforeState;
        G.Request memory r;
        if (!e.fromBase && (kind == G.Kind.Mint || kind == G.Kind.Redeem || kind == G.Kind.Cancel)) {
            r = abi.decode(body, (G.Request));
            beforeState = base.states(r.id);
        }
        if (e.fromBase) remoteEndpoint.deliverPacket(baseEndpoint, baseEndpoint.count() - 1);
        else baseEndpoint.deliverPacket(remoteEndpoint, remoteEndpoint.count() - 1);
        ++deliveries;
        if (applied[e.messageId]) return;
        applied[e.messageId] = true;
        if (kind == G.Kind.Credit) {
            pendingCredits -= int256(abi.decode(body, (G.Transfer)).amount);
        } else if (kind == G.Kind.Return) {
            pendingReturns -= int256(abi.decode(body, (G.Transfer)).amount);
        } else if (kind == G.Kind.Result) {
            G.Result memory outcome = abi.decode(body, (G.Result));
            G.Request memory request = _request(outcome.id);
            if (request.kind == G.Kind.Mint && outcome.accepted) pendingCredits -= int256(outcome.output);
            if (request.kind == G.Kind.Redeem && !outcome.accepted) pendingRetirements -= int256(request.amount);
        } else if (beforeState == G.State.None) {
            bytes32 response = base.responseMessages(r.id);
            messages.push(Entry(true, response));
            (,, bytes memory resultBody) = abi.decode(base.outbox(response), (uint8, G.Kind, bytes));
            G.Result memory outcome = abi.decode(resultBody, (G.Result));
            if (outcome.accepted && r.kind == G.Kind.Mint) pendingCredits += int256(outcome.output);
            if (outcome.accepted && r.kind == G.Kind.Redeem) pendingRetirements -= int256(r.amount);
        }
    }

    function claim(uint256 seed) external {
        remote.processPayouts(100);
        if (intents.length == 0) return;
        bytes32 id = intents[seed % intents.length];
        G.Request memory r = _request(id);
        if (r.kind == G.Kind.Mint && remote.states(id) == G.State.Rejected) remote.claimRefund(id, address(this));
        if (remote.claimablePayout(id) != 0) remote.claimRedemption(id, address(this));
    }

    function topUp(uint256 amount) external {
        amount = bound(amount, 0, usdg.balanceOf(address(this)));
        remote.fundLiquidity(amount);
    }

    function _request(bytes32 id) private view returns (G.Request memory r) {
        (r.id, r.kind, r.owner, r.recipient, r.amount, r.minOutput, r.deadline) = remote.requests(id);
    }
}

contract GoldCrosschainInvariant is StdInvariant, GoldFixture {
    GoldCrosschainHandler handler;

    function setUp() public override {
        super.setUp();
        handler =
            new GoldCrosschainHandler(canonical, base, remote, usdg, baseEndpoint, remoteEndpoint, goldFeed, usdgFeed);
        canonical.mint(address(handler), 20e18);
        canonical.grantRole(canonical.MINTER_ROLE(), address(handler));
        usdg.mint(address(handler), 10_000_000e6);
        vm.deal(address(handler), 1 ether);
        targetContract(address(handler));
    }

    function invariantGlobalEconomicSupplyIncludesEveryInFlightClaim() public view {
        assertGe(handler.pendingCredits(), 0);
        assertGe(handler.pendingReturns(), 0);
        assertGe(handler.pendingRetirements(), 0);
        uint256 inFlight = uint256(handler.pendingCredits() + handler.pendingReturns() + handler.pendingRetirements());
        assertEq(remote.totalSupply() + inFlight, base.backingLiability());
        assertBacking();
        uint256 economic = canonical.totalSupply() - base.backingLiability() + remote.totalSupply() + inFlight;
        assertEq(economic, canonical.totalSupply());
        assertLe(economic, 193e18);
    }

    function invariantPendingRefundAndAllocatedUSDGCannotBeSpentByQueue() public view {
        assertGe(
            usdg.balanceOf(address(remote)), remote.pendingUSDG() + remote.refundableUSDG() + remote.claimableUSDG()
        );
    }
}
