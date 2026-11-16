// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GoldFixture, GoldEndpointMock, GoldFeedMock} from "./GoldFixture.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {GoldMailbox} from "../../src/crosschain/GoldMailbox.sol";
import {GoldSettlementOracle} from "../../src/crosschain/GoldSettlementOracle.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {RobinhoodGold} from "../../src/crosschain/RobinhoodGold.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract GoldCrosschainTest is GoldFixture {
    function testBridgeRoundTripRetainsAll18DecimalsAndSupply() public {
        uint256 amount = 1e18 + 123456789;
        bridge(amount);
        assertEq(remote.balanceOf(alice), amount);
        assertEq(base.backingLiability(), amount);
        assertEq(canonical.totalSupply(), 10e18);
        vm.prank(alice);
        (, bytes32 messageId) = remote.bridgeToBase(amount, bob);
        assertEq(remote.totalSupply(), 0);
        assertEq(base.backingLiability(), amount);
        relay(remote, messageId);
        assertEq(canonical.balanceOf(bob), amount);
        assertEq(base.backingLiability(), 0);
        assertEq(canonical.totalSupply(), 10e18);
        assertBacking();
    }

    function testMintReservesUSDGUntilCanonicalBackingThenCreditsOnce() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 1e18);
        assertEq(remote.pendingUSDG(), 4000e6);
        assertEq(remote.balanceOf(alice), 0);
        relay(remote, messageId);
        assertEq(canonical.totalSupply(), 11e18);
        assertEq(base.backingLiability(), 1e18);
        assertEq(remote.pendingUSDG(), 4000e6);
        bytes32 response = base.responseMessages(id);
        relay(base, response);
        relay(base, response);
        relay(remote, messageId);
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(canonical.totalSupply(), 11e18);
        assertEq(remote.pendingUSDG(), 0);
        assertEq(uint8(remote.states(id)), uint8(G.State.Accepted));
        assertBacking();
    }

    function testCancelBeforeOriginalRejectsBothAndRefundIsPullOnly() public {
        (bytes32 id, bytes32 original) = mintRequest(4000e6, 0);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        bytes32 cancel = remote.requestCancellation(id);
        vm.prank(alice);
        vm.expectRevert();
        remote.claimRefund(id, alice);
        relay(remote, cancel);
        relay(base, base.responseMessages(id));
        relay(remote, original);
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(remote.totalSupply(), 0);
        uint256 before_ = usdg.balanceOf(alice);
        vm.prank(alice);
        remote.claimRefund(id, alice);
        assertEq(usdg.balanceOf(alice), before_ + 4000e6);
        assertEq(remote.refundableUSDG(), 0);
        vm.prank(alice);
        vm.expectRevert();
        remote.claimRefund(id, alice);
    }

    function testAcceptedMintCannotBeCancelledWhenReplyIsDelayed() public {
        (bytes32 id, bytes32 original) = mintRequest(4000e6, 0);
        relay(remote, original);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        bytes32 cancel = remote.requestCancellation(id);
        relay(remote, cancel);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(remote.refundableUSDG(), 0);
        vm.prank(alice);
        vm.expectRevert();
        remote.claimRefund(id, alice);
        assertBacking();
    }

    function testExpiredOriginalIsTerminalReject() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        vm.warp(block.timestamp + 2 hours);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(canonical.totalSupply(), 10e18);
    }

    function testConcurrentBaseMinterConsumesSharedCapacityBeforeRemoteRequest() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        canonical.mint(bob, 183e18);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(remote.totalSupply(), 0);
        assertEq(canonical.totalSupply(), 193e18);
        assertBacking();
    }

    function testSlippageAndStaleOracleRejectWithoutMint() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 2e18);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
        (id, messageId) = mintRequest(4000e6, 0);
        goldFeed.set(4000e8, block.timestamp - 2 days, 1, 1);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 8000e6);
        assertEq(canonical.totalSupply(), 10e18);
    }

    function testRedemptionBurnsBackingAndQueuesFeeProtectedPayout() public {
        settleMint(4000e6);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 3990e6);
        assertEq(remote.totalSupply(), 0);
        assertEq(canonical.totalSupply(), 11e18);
        relay(remote, messageId);
        assertEq(canonical.totalSupply(), 10e18);
        assertEq(base.backingLiability(), 0);
        relay(base, base.responseMessages(id));
        assertEq(remote.queuedUSDG(), 4000e6);
        remote.processPayouts(1);
        assertEq(remote.claimablePayout(id), 4000e6);
        uint256 before_ = usdg.balanceOf(alice);
        vm.prank(alice);
        remote.claimRedemption(id, alice);
        assertEq(usdg.balanceOf(alice), before_ + 3990e6);
        assertEq(usdg.balanceOf(remote.FEE_RECIPIENT()), 10e6);
        assertEq(remote.totalReservedUSDG(), 0);
        relay(base, base.responseMessages(id));
        assertEq(remote.payoutCount(), 1);
        assertBacking();
    }

    function testRejectedRedemptionRestoresReceiptOnlyAfterBaseRejection() public {
        bridge(1e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 5000e6);
        assertEq(remote.balanceOf(alice), 0);
        relay(remote, messageId);
        assertEq(base.backingLiability(), 1e18);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(canonical.totalSupply(), 10e18);
        assertEq(remote.queuedUSDG(), 0);
        assertBacking();
    }

    function testRedemptionCancellationBeforeOriginalRestoresTokensWithoutBurningBacking() public {
        bridge(1e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 0);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        bytes32 cancel = remote.requestCancellation(id);
        relay(remote, cancel);
        relay(base, base.responseMessages(id));
        relay(remote, messageId);
        assertEq(remote.totalSupply(), 1e18);
        assertEq(base.backingLiability(), 1e18);
        assertEq(remote.payoutCount(), 0);
        assertBacking();
    }

    function testQueueCannotSpendPendingOrRefundableUSDGAndIsFIFO() public {
        bridge(2e18);
        (bytes32 first, bytes32 m1) = redeemRequest(1e18, 0);
        relay(remote, m1);
        relay(base, base.responseMessages(first));
        (bytes32 second, bytes32 m2) = redeemRequest(1e18, 0);
        relay(remote, m2);
        relay(base, base.responseMessages(second));
        (bytes32 deposit, bytes32 mintMessage) = mintRequest(4000e6, 2e18);
        remote.processPayouts(100);
        assertEq(remote.payoutHead(), 0);
        relay(remote, mintMessage);
        relay(base, base.responseMessages(deposit));
        remote.processPayouts(100);
        assertEq(remote.payoutHead(), 0);
        usdg.mint(address(this), 4000e6);
        usdg.approve(address(remote), 4000e6);
        remote.fundLiquidity(4000e6);
        remote.processPayouts(100);
        assertEq(remote.payoutHead(), 1);
        assertEq(remote.claimablePayout(first), 4000e6);
        assertEq(remote.claimablePayout(second), 0);
        assertEq(remote.refundableUSDG(), 4000e6);
        vm.prank(alice);
        remote.claimRefund(deposit, alice);
        remote.processPayouts(100);
        assertEq(remote.payoutHead(), 1);
        assertEq(remote.queuedUSDG(), 4000e6);
        vm.prank(alice);
        remote.claimRedemption(first, alice);
        assertEq(usdg.balanceOf(address(remote)), 0);
    }

    function testFrozenRecipientDoesNotBlockFIFOAllocationAndCanRedirectClaim() public {
        settleMint(8000e6);
        (bytes32 first, bytes32 m1) = redeemRequest(1e18, 0);
        (bytes32 second, bytes32 m2) = redeemRequest(1e18, 0);
        relay(remote, m1);
        relay(base, base.responseMessages(first));
        relay(remote, m2);
        relay(base, base.responseMessages(second));
        usdg.setFrozen(alice);
        remote.processPayouts(100);
        assertEq(remote.payoutHead(), 2);
        vm.prank(alice);
        vm.expectRevert();
        remote.claimRedemption(first, alice);
        assertEq(remote.claimablePayout(first), 4000e6);
        vm.prank(bob);
        vm.expectRevert();
        remote.claimRedemption(first, bob);
        vm.prank(alice);
        remote.claimRedemption(first, bob);
        assertEq(usdg.balanceOf(bob), 3990e6);
        assertEq(remote.claimablePayout(second), 4000e6);
    }

    function testOnlyEndpointAndCorrectPeerMayDeliver() public {
        bytes memory payload = G.encode(G.Kind.Credit, abi.encode(G.Transfer(bytes32(uint256(1)), alice, 1e18)));
        vm.expectRevert();
        remote.lzReceive(
            Origin(BASE, bytes32(uint256(uint160(address(base)))), 1), bytes32(0), payload, address(this), ""
        );
        vm.expectRevert();
        remoteEndpoint.inject(address(remote), BASE, bob, payload);
        vm.expectRevert();
        remoteEndpoint.inject(address(remote), BASE + 1, address(base), payload);
        vm.expectRevert();
        remoteEndpoint.inject{value: 1}(address(remote), BASE, address(base), payload);
        assertEq(remote.totalSupply(), 0);
    }

    function testConflictingRequestAndResponseCannotOverwriteTerminalState() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        relay(remote, messageId);
        (,, bytes memory body) = abi.decode(remote.outbox(messageId), (uint8, G.Kind, bytes));
        G.Request memory r = abi.decode(body, (G.Request));
        ++r.amount;
        vm.expectRevert();
        baseEndpoint.inject(address(base), ROBIN, address(remote), G.encode(G.Kind.Mint, abi.encode(r)));
        G.Result memory fake = G.Result(id, bytes32(0), false, 0);
        vm.expectRevert();
        remoteEndpoint.inject(address(remote), BASE, address(base), G.encode(G.Kind.Result, abi.encode(fake)));
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
    }

    function testSendFailureAndDuplicateTransferAreRetryableAndIdempotent() public {
        vm.prank(alice);
        (, bytes32 id) = base.bridgeToRobinhood(1e18, alice);
        baseEndpoint.setSendFails(true);
        vm.expectRevert();
        base.dispatch{value: 1}(id, "");
        assertEq(base.backingLiability(), 1e18);
        baseEndpoint.setSendFails(false);
        relay(base, id);
        relay(base, id);
        assertEq(remote.totalSupply(), 1e18);
        vm.prank(alice);
        (, id) = remote.bridgeToBase(1e18, bob);
        relay(remote, id);
        relay(remote, id);
        assertEq(canonical.balanceOf(bob), 1e18);
        assertEq(base.backingLiability(), 0);
    }

    function testPauseBlocksNewRiskButAllowsDeliveryCancellationAndExits() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        base.setPaused(true);
        remote.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        remote.requestMint(1e6, 0, block.timestamp + 10 minutes, alice);
        remote.dispatch{value: 1}(messageId, "");
        uint256 packetIndex = remoteEndpoint.count() - 1;
        vm.expectRevert();
        baseEndpoint.deliverPacket(remoteEndpoint, packetIndex);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        bytes32 cancel = remote.requestCancellation(id);
        relay(remote, cancel);
        relay(base, base.responseMessages(id));
        vm.prank(alice);
        remote.claimRefund(id, alice);
        assertEq(remote.totalReservedUSDG(), 0);
    }

    function testPeerCannotBeChangedAndOnlyOwnerControlsPause() public {
        vm.expectRevert();
        base.setPeer(ROBIN, bytes32(uint256(uint160(bob))));
        vm.prank(alice);
        vm.expectRevert();
        remote.setPaused(true);
        vm.expectRevert();
        remote.renounceOwnership();
    }

    function testFeeOnTransferAndReentrantCollateralCannotCorruptReservations() public {
        usdg.setTaxed(true);
        vm.prank(alice);
        vm.expectRevert();
        remote.requestMint(4000e6, 0, block.timestamp + 10 minutes, alice);
        assertEq(remote.pendingUSDG(), 0);
        usdg.setTaxed(false);
        usdg.setCallback(
            address(remote), abi.encodeCall(remote.requestMint, (1e6, 0, block.timestamp + 10 minutes, alice))
        );
        mintRequest(4000e6, 0);
        assertFalse(usdg.callbackSucceeded());
        assertEq(remote.pendingUSDG(), 4000e6);
    }

    function testOracleDepegAndRoundValidation() public {
        G.PriceSnapshot memory p = remote.currentUSDGPrice();
        assertEq(oracle.mintOutput(4000e6, p), 1e18);
        assertEq(oracle.redeemOutput(1e18, p), 4000e6);
        usdgFeed.set(0.5e8, block.timestamp, 2, 2);
        p = remote.currentUSDGPrice();
        assertEq(oracle.mintOutput(4000e6, p), 0.5e18);
        assertEq(oracle.redeemOutput(1e18, p), 8000e6);
        goldFeed.set(-1, block.timestamp, 2, 2);
        vm.expectRevert();
        oracle.mintOutput(1e6, p);
        goldFeed.set(4000e8, block.timestamp + 1, 2, 2);
        vm.expectRevert();
        oracle.mintOutput(1e6, p);
        goldFeed.set(4000e8, block.timestamp, 2, 1);
        vm.expectRevert();
        oracle.mintOutput(1e6, p);
        goldFeed.set(4000e8, 0, 1, 1);
        vm.expectRevert();
        oracle.mintOutput(1e6, p);
    }

    function testFuzzBridgePrecision(uint256 amount) public {
        amount = bound(amount, 1, 10e18);
        bridge(amount);
        assertEq(remote.balanceOf(alice), amount);
        vm.prank(alice);
        (, bytes32 id) = remote.bridgeToBase(amount, bob);
        relay(remote, id);
        assertEq(canonical.balanceOf(bob), amount);
        assertBacking();
    }

    function testCanonicalPauseRollsBackDeliveryAndAllowsRetry() public {
        bridge(1e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 0);
        remote.dispatch{value: 1}(messageId, "");
        uint256 packetIndex = remoteEndpoint.count() - 1;
        canonical.pause();
        vm.expectRevert();
        baseEndpoint.deliverPacket(remoteEndpoint, packetIndex);
        assertEq(uint8(base.states(id)), uint8(G.State.None));
        assertEq(base.backingLiability(), 1e18);
        assertFalse(base.received(messageId));
        canonical.unpause();
        baseEndpoint.deliverPacket(remoteEndpoint, packetIndex);
        relay(base, base.responseMessages(id));
        assertEq(base.backingLiability(), 0);
        assertEq(remote.queuedUSDG(), 4000e6);
        assertBacking();
    }

    function testBasePauseBlocksNewRedemptionQuoteButCancellationRestoresTokens() public {
        bridge(1e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 0);
        base.setPaused(true);
        remote.dispatch{value: 1}(messageId, "");
        uint256 packetIndex = remoteEndpoint.count() - 1;
        vm.expectRevert();
        baseEndpoint.deliverPacket(remoteEndpoint, packetIndex);
        assertEq(uint8(base.states(id)), uint8(G.State.None));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        bytes32 cancel = remote.requestCancellation(id);
        relay(remote, cancel);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(remote.payoutCount(), 0);
        assertBacking();
    }

    function testTaxedRefundCannotConsumeProtectedFunds() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 2e18);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        usdg.setTaxed(true);
        vm.prank(alice);
        vm.expectRevert();
        remote.claimRefund(id, alice);
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(uint8(remote.states(id)), uint8(G.State.Rejected));
        usdg.setTaxed(false);
        vm.prank(alice);
        remote.claimRefund(id, alice);
        assertEq(remote.refundableUSDG(), 0);
    }

    function testMultipleRemoteRequestsRaceForOneSharedCeiling() public {
        canonical.mint(bob, 182e18);
        (bytes32 first, bytes32 m1) = mintRequest(4000e6, 1e18);
        (bytes32 second, bytes32 m2) = mintRequest(4000e6, 1e18);
        relay(remote, m2);
        relay(remote, m1);
        relay(base, base.responseMessages(first));
        relay(base, base.responseMessages(second));
        assertEq(uint8(remote.states(first)), uint8(G.State.Rejected));
        assertEq(uint8(remote.states(second)), uint8(G.State.Accepted));
        assertEq(remote.totalSupply(), 1e18);
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(canonical.totalSupply(), 193e18);
        assertBacking();
    }

    function testMixedOracleDecimalsAndUSDGStaleness() public {
        GoldFeedMock g = new GoldFeedMock(18, 4000e18);
        GoldFeedMock u = new GoldFeedMock(6, 1e6);
        GoldSettlementOracle candidate = new GoldSettlementOracle(address(g), 60);
        RobinhoodGold source =
            new RobinhoodGold(address(remoteEndpoint), address(this), ROBIN, BASE, address(usdg), address(u));
        G.PriceSnapshot memory p = source.currentUSDGPrice();
        assertEq(p.priceUSD18, 1e18);
        assertEq(candidate.mintOutput(4000e6, p), 1e18);
        assertEq(candidate.redeemOutput(1e18, p), 4000e6);
        u.set(1e6, block.timestamp - 1 days - 1, 2, 2);
        vm.expectRevert();
        source.currentUSDGPrice();
        vm.expectRevert();
        new GoldSettlementOracle(address(0), 60);
        vm.expectRevert();
        new GoldSettlementOracle(address(g), 0);
    }

    function testCannotBridgeIntoDestinationGatewayOrDispatchInventedPayload() public {
        vm.prank(alice);
        vm.expectRevert();
        base.bridgeToRobinhood(1e18, address(remote));
        bridge(1e18);
        vm.prank(alice);
        vm.expectRevert();
        remote.bridgeToBase(1e18, address(base));
        vm.expectRevert();
        remote.dispatch{value: 1}(bytes32(uint256(123)), "");
        GoldEndpointMock wrongEndpoint = new GoldEndpointMock(BASE + 1);
        vm.expectRevert();
        new BaseGoldController(address(wrongEndpoint), address(this), BASE, ROBIN, address(canonical), address(oracle));
    }

    function testOnlyRequesterCanCancelOrClaimRefund() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 2e18);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        vm.expectRevert();
        remote.requestCancellation(id);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        vm.prank(bob);
        vm.expectRevert();
        remote.claimRefund(id, bob);
        assertEq(remote.refundableUSDG(), 4000e6);
    }
}
