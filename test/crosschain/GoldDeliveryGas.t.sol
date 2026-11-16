// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldFixture, IGoldReceiver} from "./GoldFixture.sol";
import {GoldMailbox} from "../../src/crosschain/GoldMailbox.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Cold application-handler budget checks, not a real executor/DVN finality proof.
contract GoldDeliveryGasTest is GoldFixture {
    uint256 constant APPLICATION_BUDGET = 1_000_000;

    function boundedRelay(GoldMailbox from, bytes32 id, string memory label) internal {
        GoldMailbox to = address(from) == address(base) ? GoldMailbox(address(remote)) : GoldMailbox(address(base));
        bytes memory payload = from.outbox(id);
        address endpoint = address(to.endpoint());
        uint32 sourceEid = from.localEid();
        address implementation = address(
            uint160(
                uint256(vm.load(address(canonical), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
        vm.cool(address(base));
        vm.cool(address(remote));
        vm.cool(address(canonical));
        vm.cool(implementation);
        vm.cool(address(oracle));
        vm.cool(address(goldFeed));
        vm.cool(address(usdgFeed));
        vm.cool(address(usdg));
        vm.prank(endpoint);
        uint256 before_ = gasleft();
        IGoldReceiver(address(to)).lzReceive{gas: APPLICATION_BUDGET}(
            Origin(sourceEid, bytes32(uint256(uint160(address(from)))), 1), id, payload, address(this), ""
        );
        uint256 used = before_ - gasleft();
        emit log_named_uint(label, used);
        assertLt(used, 900000);
    }

    function testColdMintAndAcceptedResultGas() public {
        (bytes32 id, bytes32 messageId) = mintRequest(4000e6, 0);
        boundedRelay(remote, messageId, "Base accepted mint");
        boundedRelay(base, base.responseMessages(id), "Remote accepted mint result");
        boundedRelay(base, base.responseMessages(id), "Duplicate result");
        assertEq(remote.totalSupply(), 1e18);
    }

    function testColdRedemptionAndPayoutQueueGas() public {
        settleMint(4000e6);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 0);
        boundedRelay(remote, messageId, "Base accepted redemption");
        boundedRelay(base, base.responseMessages(id), "Remote redemption queue");
        assertEq(remote.queuedUSDG(), 4000e6);
    }

    function testColdCancellationAndRefundGas() public {
        (bytes32 id,) = mintRequest(4000e6, 0);
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        bytes32 messageId = remote.requestCancellation(id);
        boundedRelay(remote, messageId, "Base cancellation");
        boundedRelay(base, base.responseMessages(id), "Remote refundable deposit");
        assertEq(remote.refundableUSDG(), 4000e6);
    }

    function testColdBridgeCreditAndReturnGas() public {
        vm.prank(alice);
        (, bytes32 messageId) = base.bridgeToRobinhood(1e18, alice);
        boundedRelay(base, messageId, "Remote bridge credit");
        vm.prank(alice);
        (, messageId) = remote.bridgeToBase(1e18, bob);
        boundedRelay(remote, messageId, "Base bridge return");
        assertEq(canonical.balanceOf(bob), 1e18);
    }

    function testColdRejectedRedemptionRestorationGas() public {
        bridge(1e18);
        (bytes32 id, bytes32 messageId) = redeemRequest(1e18, 5000e6);
        boundedRelay(remote, messageId, "Base rejected redemption");
        boundedRelay(base, base.responseMessages(id), "Remote token restoration");
        assertEq(remote.balanceOf(alice), 1e18);
    }
}
