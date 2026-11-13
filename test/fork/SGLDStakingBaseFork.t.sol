// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SGLDStaking} from "../../src/SGLDStaking.sol";

/// @notice Uses real Base SGLD code/state in a disposable local fork. No transactions are broadcast.
contract SGLDStakingBaseForkTest is Test {
    address constant ASSET = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;
    address constant OWNER = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
    address constant TREASURY = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;

    function testBaseForkPausedDeploymentExitAndLateInterest() public {
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")));
        assertEq(block.chainid, 8453);
        IERC20Metadata token = IERC20Metadata(ASSET);
        assertEq(token.decimals(), 18);
        assertEq(token.symbol(), "SGLD");
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        SGLDStaking vault = new SGLDStaking(ASSET, OWNER, OWNER, OWNER);
        assertTrue(vault.paused());
        assertEq(vault.defaultAdmin(), OWNER);
        address user = makeAddr("fork-user");
        deal(ASSET, user, 101e18, true);
        deal(ASSET, OWNER, 2e18, true);
        vm.prank(user);
        token.approve(address(vault), 100e18);
        vm.prank(user);
        vm.expectRevert();
        vault.stake(100e18, 30);
        vm.prank(OWNER);
        vault.unpauseDeposits();
        uint256 start = block.timestamp;
        vm.prank(user);
        vault.stake(100e18, 30);
        assertEq(vault.balanceOf(user), 99.75e18);
        assertEq(token.balanceOf(TREASURY), treasuryBefore + 0.25e18);
        vm.warp(start + 30 days);
        vm.prank(OWNER);
        vault.pauseDeposits();
        vm.prank(user);
        vault.withdraw(0, new uint256[](0));
        assertEq(token.balanceOf(user), 100.25125e18);
        assertEq(vault.balanceOf(user), 0);
        vm.prank(OWNER);
        uint256 epoch = vault.createEpoch(block.timestamp);
        vault.processEpoch(epoch, 100);
        vm.startPrank(OWNER);
        token.approve(address(vault), 2e18);
        vault.fundEpoch(epoch, 2e18);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](1);
        ids[0] = epoch;
        vm.prank(user);
        vault.claim(0, ids);
        assertEq(token.balanceOf(user), 102.25125e18);
        assertEq(token.balanceOf(TREASURY), treasuryBefore + 0.74875e18);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertTrue(vault.paused());
    }
}
