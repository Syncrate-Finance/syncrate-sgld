// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldFixture} from "./GoldFixture.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";

contract GoldInventoryIncreaseTest is GoldFixture {
    function raiseInventory() internal {
        canonical.increaseGlobalSupplyCap(300e18);
        base.setPaused(true);
        base.configureExposureLimits(300e18, 300e18, 300e18);
        base.setPaused(false);
    }

    function testIncreaseDoesNotReplenishBudgetOrChangeExistingLimits() public {
        bridge(1e18);
        uint256 before_ = base.availableExposure();
        canonical.increaseGlobalSupplyCap(300e18);
        assertEq(base.maxOutstandingBacking(), 193e18);
        base.setPaused(true);
        base.configureExposureLimits(300e18, 300e18, 300e18);
        assertEq(base.availableExposure(), before_);
        vm.expectRevert();
        base.configureExposureLimits(300e18, 301e18, 300e18);
    }

    function testControllerCanDeployAfterInventoryIncrease() public {
        canonical.increaseGlobalSupplyCap(300e18);
        BaseGoldController next = new BaseGoldController(
            address(baseEndpoint), address(this), BASE, ROBIN, address(canonical), address(oracle)
        );
        assertTrue(next.paused());
        next.configureExposureLimits(300e18, 300e18, 300e18);
    }

    function testRemoteMintCrossesOldCeilingOnlyAfterCanonicalIncrease() public {
        canonical.mint(bob, 183e18);
        bytes32 rejected = settleMint(4000e6);
        assertEq(uint8(remote.states(rejected)), uint8(G.State.Rejected));
        assertEq(remote.refundableUSDG(), 4000e6);
        raiseInventory();
        bytes32 accepted = settleMint(4000e6);
        assertEq(uint8(remote.states(accepted)), uint8(G.State.Accepted));
        assertEq(canonical.totalSupply(), 194e18);
        assertEq(remote.totalSupply(), 1e18);
        assertBacking();
    }

    function testCreditAndRejectedRedemptionAbove193DoNotStrandFunds() public {
        raiseInventory();
        canonical.mint(alice, 240e18); // total250, all backed under the new300 inventory.
        bridge(190e18);
        vm.warp(block.timestamp + 1 days);
        bridge(60e18);
        assertEq(remote.totalSupply(), 250e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(200e18, type(uint256).max);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(uint8(remote.states(id)), uint8(G.State.Rejected));
        assertEq(remote.totalSupply(), 250e18);
        assertBacking();
        vm.prank(alice);
        (, bytes32 back) = remote.bridgeToBase(250e18, alice);
        relay(remote, back);
        assertEq(remote.totalSupply(), 0);
        assertEq(base.backingLiability(), 0);
        assertEq(canonical.balanceOf(alice), 250e18);
    }

    function testMintCreditOver193AndCapFailureRemainRecoverable() public {
        raiseInventory();
        vm.warp(block.timestamp + 1 days);
        goldFeed.set(4000e8, block.timestamp, 2, 2);
        usdgFeed.set(1e8, block.timestamp, 2, 2);
        bytes32 accepted = settleMint(800_000e6); //200SGLD backed mint.
        assertEq(uint8(remote.states(accepted)), uint8(G.State.Accepted));
        assertEq(remote.totalSupply(), 200e18);
        assertEq(canonical.totalSupply(), 210e18);
        canonical.mint(bob, 90e18);
        bytes32 rejected = settleMint(4000e6);
        assertEq(uint8(remote.states(rejected)), uint8(G.State.Rejected));
        assertEq(remote.refundableUSDG(), 4000e6);
        assertBacking();
    }
}
