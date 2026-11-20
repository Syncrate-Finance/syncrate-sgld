// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RobinhoodGoldEngine as RobinhoodGold} from "../../src/crosschain/RobinhoodGoldEngine.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Actual deployed USDG/Chainlink/endpoint, all writes in a disposable Robinhood fork.
contract RobinhoodEngineForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant ENDPOINT = address(bytes20(hex"6f475642a6e85809b1c36fa62763669b1b48dd5b"));

    function testRealUSDGProxyDepositRefundAndTreasurySweep() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        assertEq(block.chainid, 4663);
        RobinhoodGold.InitConfig memory config = RobinhoodGold.InitConfig(
            ENDPOINT, address(this), address(this), address(this), 30416, 30184, USDG, FEED, makeAddr("fork-treasury")
        );
        RobinhoodGold remote = RobinhoodGold(
            address(new ERC1967Proxy(address(new RobinhoodGold()), abi.encodeCall(RobinhoodGold.initialize, (config))))
        );
        address canonicalPeer = makeAddr("fork-canonical-peer");
        remote.setPeer(30184, bytes32(uint256(uint160(canonicalPeer))));
        remote.setPaused(false);
        G.PriceSnapshot memory price = remote.currentUSDGPrice();
        assertGt(price.priceUSD18, 0);
        assertGt(price.roundId, 0);
        assertLe(block.timestamp - price.updatedAt, 1 days);
        assertEq(price.observedAt, block.timestamp);
        address user = makeAddr("fork-usdg-user");
        // Test-only synthetic USDG balance. No token mint is broadcast or issuer role changed.
        deal(USDG, user, 4000e6);
        vm.startPrank(user);
        IERC20(USDG).approve(address(remote), 4000e6);
        (bytes32 id,) = remote.requestMint(4000e6, 0, block.timestamp + 10 minutes, user);
        vm.stopPrank();
        vm.expectRevert();
        remote.sweepToTreasury(USDG);
        assertEq(remote.pendingUSDG(), 4000e6);
        assertEq(IERC20(USDG).balanceOf(address(remote)), 4000e6);
        G.Request memory r = remote.getRequest(id);
        assertEq(r.usdgPrice.priceUSD18, price.priceUSD18);
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(user);
        remote.requestCancellation(id);
        // Authenticated delivery is impersonated locally: this does NOT test real DVN finality.
        bytes memory response = G.encode(G.Kind.Result, abi.encode(G.Result(id, keccak256(abi.encode(r)), false, 0)));
        vm.prank(ENDPOINT);
        remote.lzReceive(
            Origin(30184, bytes32(uint256(uint160(canonicalPeer))), 1), bytes32(uint256(1)), response, address(this), ""
        );
        vm.prank(user);
        remote.claimRefund(id, user);
        assertEq(IERC20(USDG).balanceOf(user), 4000e6);
        assertEq(remote.totalReservedUSDG(), 0);
        assertEq(remote.totalSupply(), 0);
        // Second request accepts locally impersonated canonical backing, then sweeps real USDG.
        vm.startPrank(user);
        IERC20(USDG).approve(address(remote), 4000e6);
        (bytes32 accepted,) = remote.requestMint(4000e6, 0, block.timestamp + 10 minutes, user);
        vm.stopPrank();
        G.Request memory acceptedRequest = remote.getRequest(accepted);
        bytes memory acceptedResponse =
            G.encode(G.Kind.Result, abi.encode(G.Result(accepted, keccak256(abi.encode(acceptedRequest)), true, 1e18)));
        vm.prank(ENDPOINT);
        remote.lzReceive(
            Origin(30184, bytes32(uint256(uint160(canonicalPeer))), 2),
            bytes32(uint256(2)),
            acceptedResponse,
            address(this),
            ""
        );
        remote.sweepToTreasury(USDG);
        assertEq(IERC20(USDG).balanceOf(remote.TREASURY()), 1600e6);
        assertEq(IERC20(USDG).balanceOf(address(remote)), 2400e6);
        assertEq(remote.totalSupply(), 1e18);
    }
}
