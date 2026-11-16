// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SGLDToken} from "../src/SGLDToken.sol";
import {SGLDTokenCapped} from "../src/SGLDTokenCapped.sol";
import {SGLDTokenAdjustableCap} from "../src/SGLDTokenAdjustableCap.sol";

contract SGLDTokenAdjustableCapTest is Test {
    SGLDTokenCapped fixedToken;
    SGLDTokenAdjustableCap token;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        fixedToken = SGLDTokenCapped(
            address(
                new ERC1967Proxy(address(new SGLDTokenCapped()), abi.encodeCall(SGLDToken.initialize, (address(this))))
            )
        );
        fixedToken.updateTokenTicker();
        fixedToken.initializeGlobalSupplyCap();
        fixedToken.grantRole(fixedToken.MINTER_ROLE(), address(this));
        fixedToken.grantRole(fixedToken.MINTER_ROLE(), bob);
        fixedToken.mint(alice, 193e18);
        vm.prank(alice);
        fixedToken.approve(bob, 7e18);
    }

    function migrate() internal {
        fixedToken.upgradeToAndCall(
            address(new SGLDTokenAdjustableCap()),
            abi.encodeCall(SGLDTokenAdjustableCap.initializeAdjustableSupplyCap, ())
        );
        token = SGLDTokenAdjustableCap(address(fixedToken));
    }

    function testMigrationPreservesStateAndPause() public {
        fixedToken.pause();
        migrate();
        assertEq(token.totalSupply(), 193e18);
        assertEq(token.balanceOf(alice), 193e18);
        assertEq(token.allowance(alice, bob), 7e18);
        assertEq(token.symbol(), "SGLD");
        assertEq(token.name(), "Syncrate Gold");
        assertEq(token.decimals(), 18);
        assertTrue(token.paused());
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(token.hasRole(token.MINTER_ROLE(), bob));
        assertTrue(token.globalSupplyCapInitialized());
        assertEq(token.MAX_CANONICAL_SUPPLY(), 193e18);
    }

    function testIncreaseDoesNotMintAndEveryMinterSharesLimit() public {
        migrate();
        vm.expectRevert();
        token.mint(alice, 1);
        vm.expectEmit();
        emit SGLDTokenAdjustableCap.GlobalSupplyCapIncreased(193e18, 250e18);
        token.increaseGlobalSupplyCap(250e18);
        assertEq(token.totalSupply(), 193e18);
        vm.prank(bob);
        token.mint(bob, 57e18);
        vm.expectRevert();
        token.mint(alice, 1);
        vm.prank(bob);
        token.burn(1e18);
        token.mint(alice, 1e18);
        assertEq(token.totalSupply(), 250e18);
    }

    function testAuthorizationAndMonotonicity() public {
        migrate();
        vm.prank(alice);
        vm.expectRevert();
        token.increaseGlobalSupplyCap(250e18);
        vm.prank(bob);
        vm.expectRevert();
        token.increaseGlobalSupplyCap(250e18);
        vm.expectRevert();
        token.increaseGlobalSupplyCap(193e18);
        vm.expectRevert();
        token.increaseGlobalSupplyCap(0);
        vm.expectRevert();
        token.initializeAdjustableSupplyCap();
    }

    function testMissingInitializerFailsClosedForMintButPreservesTransfers() public {
        fixedToken.upgradeToAndCall(address(new SGLDTokenAdjustableCap()), "");
        token = SGLDTokenAdjustableCap(address(fixedToken));
        assertFalse(token.globalSupplyCapInitialized());
        vm.expectRevert();
        token.mint(alice, 1);
        vm.expectRevert();
        token.increaseGlobalSupplyCap(250e18);
        vm.prank(alice);
        token.transfer(bob, 1e18);
        token.initializeAdjustableSupplyCap();
        assertEq(token.MAX_CANONICAL_SUPPLY(), 193e18);
    }

    function testImplementationCannotInitialize() public {
        SGLDTokenAdjustableCap implementation = new SGLDTokenAdjustableCap();
        vm.expectRevert();
        implementation.initialize(address(this));
        vm.expectRevert();
        implementation.initializeAdjustableSupplyCap();
    }

    function testMaximumCapHasSafeBoundary() public {
        migrate();
        token.increaseGlobalSupplyCap(type(uint256).max);
        token.mint(alice, type(uint256).max - 193e18);
        assertEq(token.totalSupply(), type(uint256).max);
        vm.expectRevert();
        token.mint(alice, 1);
    }

    function testUnauthorizedMigrationRejected() public {
        fixedToken.upgradeToAndCall(address(new SGLDTokenAdjustableCap()), "");
        token = SGLDTokenAdjustableCap(address(fixedToken));
        vm.prank(alice);
        vm.expectRevert();
        token.initializeAdjustableSupplyCap();
        token.initializeAdjustableSupplyCap();
    }

    function testFuzzNewBoundary(uint256 newCap, uint256 amount) public {
        migrate();
        newCap = bound(newCap, 193e18 + 1, type(uint128).max);
        token.increaseGlobalSupplyCap(newCap);
        if (amount > newCap - 193e18) vm.expectRevert();
        token.mint(alice, amount);
        assertLe(token.totalSupply(), newCap);
    }
}

contract SGLDTokenAdjustableCapLiveForkTest is Test {
    function testMigrateActualDeployedVersionFiveOnDisposableFork() public {
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), 58_219_974);
        address proxy = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;
        address admin = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
        address engine = 0x37c0078D297243A22ac247cd93f1cafed9Dbe461;
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(proxy, slot)))), 0x7A930a4B191A6e88281681380426C821C5d0B19E);
        SGLDTokenAdjustableCap token = SGLDTokenAdjustableCap(proxy);
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(admin);
        uint256 allowance = token.allowance(admin, engine);
        bool paused = token.paused();
        SGLDTokenAdjustableCap implementation = new SGLDTokenAdjustableCap();
        vm.prank(admin);
        token.upgradeToAndCall(
            address(implementation), abi.encodeCall(SGLDTokenAdjustableCap.initializeAdjustableSupplyCap, ())
        );
        assertTrue(token.globalSupplyCapInitialized());
        assertEq(token.MAX_CANONICAL_SUPPLY(), 193e18);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(admin), balance);
        assertEq(token.allowance(admin, engine), allowance);
        assertEq(token.paused(), paused);
        assertTrue(token.hasRole(bytes32(0), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), engine));
        vm.prank(admin);
        token.increaseGlobalSupplyCap(250e18);
        assertEq(token.MAX_CANONICAL_SUPPLY(), 250e18);
        assertEq(token.totalSupply(), supply);
    }
}
