// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";
import {SGLDStaking} from "../../src/SGLDStaking.sol";

interface IBaseEngineCapTest {
    function mint(uint256 amount, address collateral) external;
}

/// @notice All writes are in Foundry's in-memory fork. No broadcast or private key.
contract SGLDTokenCapBaseForkTest is Test {
    address constant ASSET = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;
    address constant ADMIN = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
    address constant ENGINE = 0x37c0078D297243A22ac247cd93f1cafed9Dbe461;
    address constant VAULT = 0xA6df4a9d12A5E60E82DD773010775C4DCae26744;
    address constant TREASURY = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 constant INITIALIZER_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testPinnedBaseProxyUpgradeEngineAndExistingStaking() public {
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), 58_110_779);
        assertEq(block.chainid, 8453);
        assertEq(vm.load(ASSET, INITIALIZER_SLOT), bytes32(uint256(4)));
        assertEq(
            address(uint160(uint256(vm.load(ASSET, IMPLEMENTATION_SLOT)))), 0x21D4dAf073A381631356513072dFD3A6372CCbE8
        );
        SGLDTokenCapped token = SGLDTokenCapped(ASSET);
        uint256 supply = token.totalSupply();
        assertEq(supply, 457522343430630543);
        address[4] memory holders = [ADMIN, ENGINE, VAULT, TREASURY];
        uint256[4] memory balances;
        for (uint256 i; i < holders.length; ++i) {
            balances[i] = token.balanceOf(holders[i]);
        }
        uint256 allowanceBefore = token.allowance(ADMIN, ENGINE);
        bool pausedBefore = token.paused();
        SGLDTokenCapped implementation = new SGLDTokenCapped();
        vm.prank(ADMIN);
        token.upgradeToAndCall(address(implementation), abi.encodeCall(SGLDTokenCapped.initializeGlobalSupplyCap, ()));
        assertEq(vm.load(ASSET, INITIALIZER_SLOT), bytes32(uint256(5)));
        assertEq(token.totalSupply(), supply);
        assertEq(token.name(), "Syncrate Gold");
        assertEq(token.symbol(), "SGLD");
        assertEq(token.decimals(), 18);
        assertEq(token.paused(), pausedBefore);
        assertEq(token.allowance(ADMIN, ENGINE), allowanceBefore);
        for (uint256 i; i < holders.length; ++i) {
            assertEq(token.balanceOf(holders[i]), balances[i]);
        }
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(token.hasRole(token.MINTER_ROLE(), ENGINE));

        // Existing engine's real collateral/oracle flow still works after the token upgrade.
        address alice = makeAddr("cap-fork-user");
        deal(USDC, alice, 1e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(ENGINE, 1e6);
        IBaseEngineCapTest(ENGINE).mint(1e6, USDC);
        vm.stopPrank();
        assertGt(token.balanceOf(alice), 0);

        // Existing deployed staking code keeps working; unpause only inside this local fork.
        vm.prank(ENGINE);
        token.mint(alice, 2e18);
        if (SGLDStaking(VAULT).paused()) {
            vm.prank(ADMIN);
            SGLDStaking(VAULT).unpauseDeposits();
        }
        uint256 beforeStake = token.totalSupply();
        vm.startPrank(alice);
        token.approve(VAULT, 2e18);
        uint256 positionId = SGLDStaking(VAULT).stake(2e18, 30);
        vm.stopPrank();
        assertEq(SGLDStaking(VAULT).balanceOf(alice), 1.995e18);
        assertEq(token.totalSupply(), beforeStake);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        SGLDStaking(VAULT).withdraw(positionId, new uint256[](0));
        assertEq(token.totalSupply(), beforeStake);

        uint256 remainingCapacity = 193e18 - token.totalSupply();
        vm.prank(ENGINE);
        token.mint(alice, remainingCapacity);
        vm.prank(ENGINE);
        vm.expectRevert();
        token.mint(alice, 1);
        assertEq(token.totalSupply(), 193e18);
    }
}
