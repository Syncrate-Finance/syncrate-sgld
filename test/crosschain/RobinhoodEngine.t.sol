// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldEngineFixture, GoldFeedMock} from "./GoldEngineFixture.sol";
import {RobinhoodGoldEngine} from "../../src/crosschain/RobinhoodGoldEngine.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RobinhoodEngineV2 is RobinhoodGoldEngine {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract RobinhoodEngineTest is GoldEngineFixture {
    function testRevokingAdminAlsoClearsItsEndpointDelegatePermission() public {
        remote.grantRole(bytes32(0), bob);
        remote.setDelegate(bob);
        assertEq(remoteEndpoint.delegates(address(remote)), bob);
        remote.revokeRole(bytes32(0), bob);
        assertEq(remote.messagingDelegate(), address(remote));
        assertEq(remoteEndpoint.delegates(address(remote)), address(remote));
        vm.prank(bob);
        vm.expectRevert();
        remote.pause();
    }

    function testNoDailyThrottleBeyondSharedCanonicalInventory() public {
        uint256 timestamp = block.timestamp;
        for (uint256 i; i < 3; i++) {
            settleMint(732000e6);
            assertEq(remote.balanceOf(alice), 183e18);
            (bytes32 id, bytes32 messageId) = redeemRequest(183e18, 0);
            relay(remote, messageId);
            relay(base, base.responseMessages(id));
            remote.processQueue(1);
            vm.prank(alice);
            remote.claimRedemption(id, alice);
            assertBacking();
        }
        assertEq(block.timestamp, timestamp);
    }

    function testCanonicalInventoryIncreaseNeedsNoRemoteLimitChange() public {
        canonical.increaseGlobalSupplyCap(250e18);
        settleMint(960000e6);
        assertEq(remote.balanceOf(alice), 240e18);
        assertBacking();
    }

    function testFuzzGrossMinimumExactlyMatchesSnapshottedNet(uint256 fee, uint256 net) public {
        fee = bound(fee, 0, 500);
        net = bound(net, 1, 4000e6);
        settleMint(4000e6);
        remote.setRedeemFee(fee);
        (bytes32 id,) = redeemRequest(1e18, net);
        G.Request memory request = remote.getRequest(id);
        uint256 gross = request.minOutput;
        assertGe(gross - gross * fee / 10000, net);
        assertLt((gross - 1) - (gross - 1) * fee / 10000, net);
    }

    function testSuccessfulMintProceedsSweepFortyPercentToTreasury() public {
        settleMint(4000e6);
        uint256 balance = usdg.balanceOf(remote.TREASURY());
        remote.sweepToTreasury(address(usdg));
        assertEq(usdg.balanceOf(remote.TREASURY()) - balance, 1600e6);
        assertEq(usdg.balanceOf(address(remote)), 2400e6);
        assertEq(remote.balanceOf(alice), 1e18);
        assertBacking();
    }

    function testPendingAndRefundableDepositsCannotBeSwept() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 2e18);
        assertEq(remote.availableTreasuryUSDG(), 0);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        vm.prank(alice);
        remote.claimRefund(id, alice);
        assertEq(usdg.balanceOf(address(remote)), 0);
    }

    function testQueuedAndClaimablePayoutsCannotBeSwept() public {
        settleMint(4000e6);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 3990e6);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.queuedUSDG(), 4000e6);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        remote.processQueue(1);
        assertEq(remote.claimableUSDG(), 4000e6);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        vm.prank(alice);
        remote.claimRedemption(id, alice);
        assertEq(remote.totalReservedUSDG(), 0);
    }

    function testOnlyUnreservedPartCanBeSweptWithMixedObligations() public {
        settleMint(4000e6);
        mintRequest(1000e6, 0);
        remote.sweepToTreasury(address(usdg));
        assertEq(usdg.balanceOf(address(remote)), 3400e6);
        assertEq(remote.pendingUSDG(), 1000e6);
        assertEq(remote.availableTreasuryUSDG(), 2400e6);
    }

    function testSweepThenRedemptionQueuesUntilLiquidityReplenished() public {
        settleMint(4000e6);
        remote.sweepToTreasury(address(usdg));
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 3990e6);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        remote.processQueue(1);
        assertEq(remote.claimablePayout(id), 0);
        vm.startPrank(alice);
        usdg.approve(address(remote), 1600e6);
        remote.fundLiquidity(1600e6);
        vm.stopPrank();
        remote.processQueue(1);
        assertEq(remote.claimablePayout(id), 4000e6);
        vm.prank(alice);
        remote.claimRedemption(id, alice);
        assertBacking();
    }

    function testFeeSnapshotSurvivesAdminChangeDuringCrosschainSettlement() public {
        settleMint(4000e6);
        remote.setRedeemFee(500);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 3800e6);
        remote.setRedeemFee(0);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        remote.processQueue(1);
        uint256 before_ = usdg.balanceOf(alice);
        vm.prank(alice);
        remote.claimRedemption(id, alice);
        assertEq(usdg.balanceOf(alice) - before_, 3800e6);
        assertEq(usdg.balanceOf(remote.TREASURY()), 200e6);
    }

    function testFeeAndOracleControlsValidateAndRestrictCallers() public {
        vm.prank(alice);
        vm.expectRevert();
        remote.setRedeemFee(0);
        vm.expectRevert();
        remote.setRedeemFee(501);
        vm.expectRevert();
        remote.setOracleStalenessThreshold(0);
        vm.expectRevert();
        remote.setOracleStalenessThreshold(86401);
        vm.expectRevert();
        remote.setUSDGPriceFeed(address(usdg));
        remote.setOracleStalenessThreshold(60);
        vm.warp(block.timestamp + 61);
        vm.expectRevert();
        remote.currentUSDGPrice();
    }

    function testBaseStyleMintAndRedeemEntryPointsAndCollateralDisable() public {
        remote.setCollateralToken(address(usdg), false);
        vm.prank(alice);
        vm.expectRevert();
        remote.mint(4000e6, address(usdg));
        remote.setCollateralToken(address(usdg), true);
        vm.prank(alice);
        (bytes32 id, bytes32 messageId) = remote.mint(4000e6, address(usdg));
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        vm.prank(alice);
        (id, messageId) = remote.redeem(1e18, address(usdg));
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.getQueueLength(), 1);
        assertBacking();
    }

    function testSweepRejectsWrongTokenUnauthorizedCallerAndTaxedTransfer() public {
        settleMint(4000e6);
        vm.prank(alice);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        vm.expectRevert();
        remote.sweepToTreasury(address(canonical));
        usdg.setTaxed(true);
        vm.expectRevert();
        remote.sweepToTreasury(address(usdg));
        assertEq(usdg.balanceOf(address(remote)), 4000e6);
    }

    function testProxyAndImplementationCannotBeReinitialized() public {
        RobinhoodGoldEngine.InitConfig memory c;
        vm.expectRevert();
        remote.initialize(c);
        RobinhoodGoldEngine implementation = new RobinhoodGoldEngine();
        vm.expectRevert();
        implementation.initialize(c);
    }

    function testUpgradeRoleAndOutstandingStateArePreserved() public {
        settleMint(4000e6);
        (bytes32 id, bytes32 messageId) = mintRequest(1000e6, 0);
        remote.setRedeemFee(100);
        RobinhoodEngineV2 next = new RobinhoodEngineV2();
        vm.prank(alice);
        vm.expectRevert();
        remote.upgradeToAndCall(address(next), "");
        remote.revokeRole(remote.UPGRADER_ROLE(), address(this));
        vm.expectRevert();
        remote.upgradeToAndCall(address(next), "");
        remote.grantRole(remote.UPGRADER_ROLE(), bob);
        vm.prank(bob);
        remote.upgradeToAndCall(address(next), "");
        assertEq(RobinhoodEngineV2(address(remote)).version(), 2);
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(remote.pendingUSDG(), 1000e6);
        assertEq(remote.redeemFeeBps(), 100);
        assertEq(remote.symbol(), "SGLD");
        assertTrue(remote.hasRole(remote.UPGRADER_ROLE(), bob));
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1.25e18);
        assertBacking();
    }

    function testAuthenticatedDeliveryRejectsForgedPeerAndReplaysSafely() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        bytes memory payload = remote.outbox(messageId);
        vm.expectRevert();
        remoteEndpoint.inject(address(remote), BASE, bob, payload);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
        assertBacking();
    }
}
