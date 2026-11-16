// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldFixture} from "./GoldFixture.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";

contract GoldExposureLimitsTest is GoldFixture {
    function profile(uint256 perOperation, uint256 outstanding, uint256 daily) internal {
        base.setPaused(true);
        base.configureExposureLimits(perOperation, outstanding, daily);
        base.setPaused(false);
    }

    function testNewControllerCannotActivateWithoutExplicitLimits() public {
        BaseGoldController fresh = new BaseGoldController(
            address(baseEndpoint), address(this), BASE, ROBIN, address(canonical), address(oracle)
        );
        fresh.setPeer(ROBIN, bytes32(uint256(uint160(address(remote)))));
        assertEq(fresh.availableExposure(), 0);
        vm.expectRevert();
        fresh.setPaused(false);
        fresh.configureExposureLimits(1e18, 3e18, 2e18);
        fresh.setPaused(false);
        assertFalse(fresh.paused());
    }

    function testLimitsAreOwnerOnlyPausedAndBounded() public {
        vm.expectRevert();
        base.configureExposureLimits(1e18, 3e18, 2e18);
        base.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        base.configureExposureLimits(1e18, 3e18, 2e18);
        vm.expectRevert();
        base.configureExposureLimits(0, 3e18, 2e18);
        vm.expectRevert();
        base.configureExposureLimits(1e18, 194e18, 2e18);
        vm.expectRevert();
        base.configureExposureLimits(3e18, 3e18, 2e18);
        vm.expectRevert();
        base.configureExposureLimits(1e18, 3e18, 194e18);
    }

    function testPerOperationAndOutstandingCap() public {
        profile(1e18, 1.5e18, 3e18);
        uint256 before_ = canonical.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        base.bridgeToRobinhood(1e18 + 1, alice);
        assertEq(canonical.balanceOf(alice), before_);
        bridge(1e18);
        bridge(0.5e18);
        vm.prank(alice);
        vm.expectRevert();
        base.bridgeToRobinhood(1, alice);
        assertEq(base.backingLiability(), 1.5e18);
    }

    function testBucketRefillsGraduallyNotAtCalendarBoundary() public {
        profile(1e18, 10e18, 2e18);
        bridge(1e18);
        bridge(1e18);
        assertEq(base.availableExposure(), 0);
        vm.warp(block.timestamp + 6 hours);
        assertEq(base.availableExposure(), 0.5e18);
        bridge(0.5e18);
        assertEq(base.availableExposure(), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(base.availableExposure(), 2e18);
    }

    function testRemoteMintOverLimitRejectsRefundablyAndDoesNotConsumeBudget() public {
        profile(0.5e18, 2e18, 2e18);
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(uint8(remote.states(id)), uint8(G.State.Rejected));
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(base.availableExposure(), 2e18);
        assertEq(canonical.totalSupply(), 10e18);
    }

    function testBaseCapFailureDoesNotConsumeBudget() public {
        profile(1e18, 2e18, 2e18);
        canonical.mint(bob, 183e18);
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(base.availableExposure(), 2e18);
        assertEq(remote.refundableUSDG(), 4000e6);
    }

    function testBridgeReturnWorksWhenBudgetExhaustedAndDoesNotRestoreBudget() public {
        profile(1e18, 2e18, 1e18);
        bridge(1e18);
        vm.prank(alice);
        (, bytes32 messageId) = remote.bridgeToBase(1e18, alice);
        base.setPaused(true);
        relay(remote, messageId);
        assertEq(base.backingLiability(), 0);
        assertEq(base.availableExposure(), 0);
        base.configureExposureLimits(2e18, 4e18, 4e18);
        assertEq(base.availableExposure(), 0); // Updating capacity never creates fresh burst allowance.
    }

    function testLoweringOutstandingBelowExistingBackingPreservesExits() public {
        bridge(2e18);
        profile(0.5e18, 0.5e18, 1e18);
        assertFalse(base.canAddBacking(1));
        vm.prank(alice);
        (, bytes32 messageId) = remote.bridgeToBase(2e18, alice);
        relay(remote, messageId);
        assertEq(base.backingLiability(), 0);
        assertTrue(base.canAddBacking(0.5e18));
    }

    function testAcceptedMintAndDirectBridgeShareSameBucket() public {
        profile(1e18, 4e18, 2e18);
        settleMint(4000e6);
        assertEq(base.availableExposure(), 1e18);
        bridge(1e18);
        assertEq(base.availableExposure(), 0);
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
    }

    function testFuzzRefillCannotExceedCapacity(uint256 elapsed) public {
        profile(1e18, 4e18, 2e18);
        bridge(1e18);
        elapsed = bound(elapsed, 0, 100 days);
        vm.warp(block.timestamp + elapsed);
        assertLe(base.availableExposure(), 2e18);
        uint256 expected = elapsed >= 1 days ? 2e18 : 1e18 + 2e18 * elapsed / 1 days;
        if (expected > 2e18) expected = 2e18;
        assertEq(base.availableExposure(), expected);
    }
}
