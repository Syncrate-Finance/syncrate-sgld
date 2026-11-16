// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SGLDToken} from "../src/SGLDToken.sol";
import {SGLDTokenCapped} from "../src/SGLDTokenCapped.sol";
import {SGLDStaking} from "../src/SGLDStaking.sol";

contract SGLDTokenCappedTest is Test {
    SGLDToken legacy;
    SGLDTokenCapped implementation;
    SGLDTokenCapped token;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        legacy = SGLDToken(
            address(new ERC1967Proxy(address(new SGLDToken()), abi.encodeCall(SGLDToken.initialize, (address(this)))))
        );
        legacy.updateTokenTicker();
        legacy.grantRole(legacy.MINTER_ROLE(), address(this));
        legacy.grantRole(legacy.MINTER_ROLE(), bob);
        legacy.mint(alice, 10e18);
        vm.prank(alice);
        legacy.approve(bob, 3e18);
        implementation = new SGLDTokenCapped();
    }

    function upgrade() internal {
        legacy.upgradeToAndCall(address(implementation), abi.encodeCall(SGLDTokenCapped.initializeGlobalSupplyCap, ()));
        token = SGLDTokenCapped(address(legacy));
    }

    function testUpgradePreservesStateAndPause() public {
        legacy.pause();
        upgrade();
        assertEq(token.name(), "Syncrate Gold");
        assertEq(token.symbol(), "SGLD");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.allowance(alice, bob), 3e18);
        assertEq(token.totalSupply(), 10e18);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(token.hasRole(token.MINTER_ROLE(), bob));
        assertTrue(token.paused());
        vm.expectRevert();
        token.mint(alice, 1);
        token.unpause();
        vm.prank(bob);
        token.transferFrom(alice, bob, 3e18);
        assertEq(token.balanceOf(bob), 3e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    function testEveryMinterSharesCapAndBurnReleasesHeadroom() public {
        upgrade();
        token.mint(alice, 183e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SGLDTokenCapped.CanonicalSupplyCapExceeded.selector, 193e18, 1, 193e18));
        token.mint(bob, 1);
        vm.prank(alice);
        token.burn(1e18);
        vm.prank(bob);
        token.mint(bob, 1e18);
        assertEq(token.totalSupply(), 193e18);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        vm.expectRevert();
        token.mint(alice, 1);
    }

    function testMissingInitializationFailsClosedForMintOnly() public {
        legacy.upgradeToAndCall(address(implementation), "");
        token = SGLDTokenCapped(address(legacy));
        assertFalse(token.globalSupplyCapInitialized());
        vm.expectRevert(SGLDTokenCapped.SupplyCapNotInitialized.selector);
        token.mint(alice, 1);
        vm.startPrank(alice);
        token.transfer(bob, 1e18);
        token.burn(1e18);
        vm.stopPrank();
        token.initializeGlobalSupplyCap();
        token.mint(alice, 1);
    }

    function testInitializationAndUpgradeAuthorization() public {
        vm.prank(alice);
        vm.expectRevert();
        legacy.upgradeToAndCall(address(implementation), "");
        legacy.upgradeToAndCall(address(implementation), "");
        token = SGLDTokenCapped(address(legacy));
        vm.prank(alice);
        vm.expectRevert();
        token.initializeGlobalSupplyCap();
        token.initializeGlobalSupplyCap();
        vm.expectRevert();
        token.initializeGlobalSupplyCap();
        vm.expectRevert();
        token.updateTokenTicker();
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1);
        vm.expectRevert();
        implementation.initialize(address(this));
        vm.expectRevert();
        implementation.initializeGlobalSupplyCap();
    }

    function testOverCapLegacyUpgradeRevertsAtomically() public {
        legacy.mint(alice, 184e18);
        vm.expectRevert();
        legacy.upgradeToAndCall(address(implementation), abi.encodeCall(SGLDTokenCapped.initializeGlobalSupplyCap, ()));
        // Legacy mint remains callable: the failed initialization rolled the implementation back.
        legacy.mint(alice, 1);
        assertEq(legacy.totalSupply(), 194e18 + 1);
    }

    function testStakingPreservesCanonicalSupply() public {
        upgrade();
        SGLDStaking vault = new SGLDStaking(address(token), address(this), address(this), address(this));
        vault.unpauseDeposits();
        vm.startPrank(alice);
        token.approve(address(vault), 2e18);
        vault.stake(2e18, 30);
        vm.stopPrank();
        assertEq(token.totalSupply(), 10e18);
        assertEq(vault.balanceOf(alice), 1.995e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.withdraw(0, new uint256[](0));
        assertEq(token.totalSupply(), 10e18);
        assertEq(vault.totalSupply(), 0);
    }

    function testFuzzCapBoundary(uint256 requested) public {
        upgrade();
        requested = bound(requested, 0, type(uint256).max);
        if (requested > 183e18) vm.expectRevert();
        token.mint(alice, requested);
        assertLe(token.totalSupply(), 193e18);
    }
}

contract CapHandler is Test {
    SGLDTokenCapped public token;
    uint256 public minted;
    uint256 public burned;

    constructor(SGLDTokenCapped asset) {
        token = asset;
    }

    function mint(uint256 amount) external {
        amount = bound(amount, 0, 194e18);
        try token.mint(address(this), amount) {
            minted += amount;
        } catch {}
    }

    function burn(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.burn(amount);
        burned += amount;
    }
}

contract SGLDTokenCapInvariant is StdInvariant, Test {
    SGLDTokenCapped token;
    CapHandler handler;

    function setUp() public {
        token = SGLDTokenCapped(
            address(
                new ERC1967Proxy(address(new SGLDTokenCapped()), abi.encodeCall(SGLDToken.initialize, (address(this))))
            )
        );
        token.initializeGlobalSupplyCap();
        handler = new CapHandler(token);
        token.grantRole(token.MINTER_ROLE(), address(handler));
        targetContract(address(handler));
    }

    function invariantSupplyRemainsWithinBackingAndConservesMintBurn() public view {
        assertLe(token.totalSupply(), 193e18);
        assertEq(token.totalSupply(), handler.minted() - handler.burned());
    }
}
