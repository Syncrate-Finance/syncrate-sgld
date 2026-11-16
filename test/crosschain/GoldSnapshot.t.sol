// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldFixture} from "./GoldFixture.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";

contract GoldSnapshotTest is GoldFixture {
    function testCapturedDepegPriceDeterminesCanonicalOutput() public {
        usdgFeed.set(0.5e8, block.timestamp, 2, 2);
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0.5e18);
        G.Request memory r = remote.getRequest(id);
        assertEq(r.usdgPrice.priceUSD18, 0.5e18);
        assertEq(r.usdgPrice.roundId, 2);
        assertEq(r.usdgPrice.observedAt, block.timestamp);
        // Subsequent source updates cannot rewrite the already authenticated request snapshot.
        usdgFeed.set(1e8, block.timestamp, 3, 3);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 0.5e18);
        assertBacking();
    }

    function testRequestCannotChooseMoreThanFifteenMinutes() public {
        vm.prank(alice);
        vm.expectRevert();
        remote.requestMint(4000e6, 0, block.timestamp + 15 minutes + 1, alice);
        assertEq(remote.pendingUSDG(), 0);
        vm.prank(alice);
        remote.requestMint(4000e6, 0, block.timestamp + 15 minutes, alice);
        assertEq(remote.pendingUSDG(), 4000e6);
    }

    function testStaleSourceFeedRevertsDepositAndBurnAtomically() public {
        bridge(1e18);
        usdgFeed.set(1e8, block.timestamp - 1 days - 1, 1, 1);
        uint256 usdBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        remote.requestMint(4000e6, 0, block.timestamp + 10 minutes, alice);
        assertEq(usdg.balanceOf(alice), usdBefore);
        assertEq(remote.pendingUSDG(), 0);
        vm.prank(alice);
        vm.expectRevert();
        remote.requestRedemption(1e18, 0, block.timestamp + 10 minutes, alice);
        assertEq(remote.balanceOf(alice), 1e18);
    }

    function testSnapshotExpiringDuringTransitRejectsMintAndRefunds() public {
        usdgFeed.set(1e8, block.timestamp - 1 days + 30, 2, 2);
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        vm.warp(block.timestamp + 31);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.refundableUSDG(), 4000e6);
        assertEq(remote.totalSupply(), 0);
        assertEq(canonical.totalSupply(), 10e18);
    }

    function testExpiredSnapshotOnRedemptionRestoresTokens() public {
        bridge(1e18);
        usdgFeed.set(1e8, block.timestamp - 1 days + 30, 2, 2);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 0);
        vm.warp(block.timestamp + 31);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
        assertEq(remote.balanceOf(alice), 1e18);
        assertEq(base.backingLiability(), 1e18);
        assertEq(remote.queuedUSDG(), 0);
        assertBacking();
    }

    function testMalformedAuthenticatedSnapshotRejectsInsteadOfMinting() public {
        (bytes32 id,) = mintRequest(4000e6, 0);
        G.Request memory r = remote.getRequest(id);
        r.usdgPrice.observedAt = block.timestamp + 1;
        // Test-only endpoint injects an authenticated but bad peer payload; Base still checks bounds.
        baseEndpoint.inject(address(base), ROBIN, address(remote), G.encode(G.Kind.Mint, abi.encode(r)));
        assertEq(uint8(base.states(id)), uint8(G.State.Rejected));
        assertEq(base.backingLiability(), 0);
    }

    function testBaseAlsoRejectsOversizedLifetimeFromAuthenticatedPeer() public {
        (bytes32 id,) = mintRequest(4000e6, 0);
        G.Request memory r = remote.getRequest(id);
        r.deadline = r.usdgPrice.observedAt + 15 minutes + 1;
        baseEndpoint.inject(address(base), ROBIN, address(remote), G.encode(G.Kind.Mint, abi.encode(r)));
        assertEq(uint8(base.states(id)), uint8(G.State.Rejected));
        assertEq(canonical.totalSupply(), 10e18);
    }

    function testSnapshotAgeAndValueValidation() public {
        G.PriceSnapshot memory p = remote.currentUSDGPrice();
        p.observedAt = block.timestamp - 15 minutes - 1;
        p.updatedAt = p.observedAt;
        vm.expectRevert();
        oracle.mintOutput(4000e6, p);
        p = remote.currentUSDGPrice();
        p.priceUSD18 = 0;
        vm.expectRevert();
        oracle.redeemOutput(1e18, p);
        p.priceUSD18 = type(uint128).max + uint256(1);
        vm.expectRevert();
        oracle.redeemOutput(1e18, p);
        p.priceUSD18 = 1e18;
        p.roundId = 0;
        vm.expectRevert();
        oracle.mintOutput(4000e6, p);
    }

    function testBadSourceRoundsNeverCreateAnIntent() public {
        usdgFeed.set(-1, block.timestamp, 1, 1);
        vm.expectRevert();
        remote.currentUSDGPrice();
        usdgFeed.set(1e8, block.timestamp + 1, 1, 1);
        vm.expectRevert();
        remote.currentUSDGPrice();
        usdgFeed.set(1e8, block.timestamp, 2, 1);
        vm.expectRevert();
        remote.currentUSDGPrice();
        assertEq(remote.nonce(), 0);
    }

    function testOldProtocolMessageCannotCreateCredit() public {
        bytes memory payload =
            abi.encode(uint8(1), G.Kind.Credit, abi.encode(G.Transfer(bytes32(uint256(1)), alice, 1e18)));
        vm.expectRevert();
        remoteEndpoint.inject(address(remote), BASE, address(base), payload);
        assertEq(remote.totalSupply(), 0);
    }
}
