// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {DeployCanonicalCap} from "../../script/crosschain/DeployCanonicalCap.s.sol";
import {DeployBaseGoldController} from "../../script/crosschain/DeployBaseGoldController.s.sol";
import {DeployRobinhoodGold} from "../../script/crosschain/DeployRobinhoodGold.s.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {GoldSettlementOracle} from "../../src/crosschain/GoldSettlementOracle.sol";
import {RobinhoodGold} from "../../src/crosschain/RobinhoodGold.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {IGoldReceiver} from "../crosschain/GoldFixture.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

interface IEndpointDelegateCheck {
    function delegates(address) external view returns (address);
}

interface IFeedAggregatorAddress {
    function aggregator() external view returns (address);
}

/// @notice Complete script rehearsals in disposable forks. Script broadcast cheatcodes remain local test execution.
contract GoldDeploymentRehearsalTest is Test {
    address constant ADMIN = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
    address constant ASSET = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;

    function testWrongNetworkStopsAllDeploymentStages() public {
        vm.chainId(1);
        DeployCanonicalCap capScript = new DeployCanonicalCap();
        DeployBaseGoldController baseScript = new DeployBaseGoldController();
        DeployRobinhoodGold remoteScript = new DeployRobinhoodGold();
        vm.expectRevert();
        capScript.run();
        vm.expectRevert();
        baseScript.run();
        vm.expectRevert();
        remoteScript.run();
    }

    function testBaseScriptsPreserveProxyAndDeployPausedThenRehearseColdHandler() public {
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), 58_180_396);
        vm.deal(ADMIN, 1 ether); // local synthetic gas funds only
        SGLDTokenCapped token = SGLDTokenCapped(ASSET);
        uint256 supplyBefore = token.totalSupply();
        address implementationBefore = address(
            uint160(uint256(vm.load(ASSET, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
        );
        SGLDTokenCapped implementation = new DeployCanonicalCap().run();
        assertEq(
            address(
                uint160(uint256(vm.load(ASSET, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
            ),
            implementationBefore
        );
        // Separate owner-authorized upgrade is impersonated in this fork ONLY, never by the deployment scripts.
        vm.prank(ADMIN);
        token.upgradeToAndCall(address(implementation), abi.encodeCall(SGLDTokenCapped.initializeGlobalSupplyCap, ()));
        vm.setEnv("SGLD_CAPPED_IMPLEMENTATION", vm.toString(address(implementation)));
        vm.setEnv("SGLD_CAPPED_RUNTIME_HASH", vm.toString(address(implementation).codehash));
        (GoldSettlementOracle oracle, BaseGoldController controller) = new DeployBaseGoldController().run();
        assertEq(token.totalSupply(), supplyBefore);
        assertTrue(controller.paused());
        assertEq(controller.owner(), ADMIN);
        assertEq(controller.exposureCapacity(), 0);
        assertEq(controller.peers(30416), bytes32(0));
        assertFalse(token.hasRole(token.MINTER_ROLE(), address(controller)));
        assertEq(IEndpointDelegateCheck(address(controller.endpoint())).delegates(address(controller)), ADMIN);
        rehearseMint(controller, oracle, token, implementation);
    }

    function rehearseMint(
        BaseGoldController controller,
        GoldSettlementOracle oracle,
        SGLDTokenCapped token,
        SGLDTokenCapped implementation
    ) private {
        address peer = makeAddr("synthetic-remote-peer");
        vm.startPrank(ADMIN);
        token.grantRole(token.MINTER_ROLE(), address(controller));
        controller.setPeer(30416, bytes32(uint256(uint160(peer))));
        controller.configureExposureLimits(2e18, 10e18, 5e18);
        controller.setPaused(false);
        vm.stopPrank();
        address user = makeAddr("synthetic-remote-user");
        // Synthetic authenticated snapshot tests the Base gas path, not cross-chain DVN delivery.
        G.Request memory request = G.Request(
            bytes32(uint256(1)),
            G.Kind.Mint,
            user,
            user,
            4000e6,
            0,
            block.timestamp + 10 minutes,
            G.PriceSnapshot(1e18, 1, block.timestamp, block.timestamp)
        );
        bytes memory payload = G.encode(G.Kind.Mint, abi.encode(request));
        address endpoint = address(controller.endpoint());
        address feed = address(oracle.gold());
        address aggregator = IFeedAggregatorAddress(feed).aggregator();
        vm.cool(address(controller));
        vm.cool(address(oracle));
        vm.cool(ASSET);
        vm.cool(address(implementation));
        vm.cool(feed);
        vm.cool(aggregator);
        vm.prank(endpoint);
        uint256 before_ = gasleft();
        IGoldReceiver(address(controller)).lzReceive{gas: 1000000}(
            Origin(30416, bytes32(uint256(uint160(peer))), 1), keccak256(payload), payload, address(this), ""
        );
        uint256 used = before_ - gasleft();
        emit log_named_uint("Real Base token/feed cold mint handler", used);
        assertLt(used, 900000);
        assertEq(uint8(controller.states(request.id)), uint8(G.State.Accepted));
        assertGt(controller.backingLiability(), 0);
        assertLe(token.totalSupply(), 193e18);
    }

    function testRobinhoodScriptDeploysPausedWithSelectedAdminAndTreasury() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        vm.deal(ADMIN, 1 ether);
        RobinhoodGold gateway = new DeployRobinhoodGold().run();
        assertTrue(gateway.paused());
        assertEq(gateway.owner(), ADMIN);
        assertEq(gateway.FEE_RECIPIENT(), 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69);
        assertEq(gateway.peers(30184), bytes32(0));
        assertEq(gateway.totalSupply(), 0);
        assertEq(gateway.totalReservedUSDG(), 0);
        assertEq(IEndpointDelegateCheck(address(gateway.endpoint())).delegates(address(gateway)), ADMIN);
        assertGt(gateway.currentUSDGPrice().priceUSD18, 0);
    }
}
