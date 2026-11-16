// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {GoldMailbox} from "../../src/crosschain/GoldMailbox.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {
    ILayerZeroEndpointV2,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";

/// @dev Test-only outbox probe, never a production token/controller.
contract GoldRouteProbe is GoldMailbox {
    constructor(address endpoint_, uint32 local_, uint32 remote_) GoldMailbox(endpoint_, msg.sender, local_, remote_) {}

    function queueProbe() external returns (bytes32) {
        return _queue(G.Kind.Credit, abi.encode(G.Transfer(_newId(), msg.sender, 1e18)));
    }
    function _handle(G.Kind, bytes memory) internal override {}
}

/// @notice Real deployed endpoints/libraries/DVNs, but EVERY write/send stays in local fork memory.
/// @dev 3-required-DVN/20-confirmation profile is a development probe, not approved production finality.
contract GoldRouteConfigurationForkTest is Test {
    struct Uln {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct Executor {
        uint32 maxMessageSize;
        address executor;
    }

    function testBaseExplicitRouteConfigQuoteAndLocalSend() public {
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", string("https://mainnet.base.org")), 58_165_944);
        address[] memory dvns = new address[](3);
        dvns[0] = address(bytes20(hex"9e059a54699a285714207b43b055483e78faac25"));
        dvns[1] = address(bytes20(hex"cd37ca043f8479064e10635020c65ffc005d36f6"));
        dvns[2] = address(bytes20(hex"a7b5189bca84cd304d8553977c7c614329750d99"));
        _check(
            30184,
            30416,
            address(bytes20(hex"1a44076050125825900e736c501f859c50fe728c")),
            address(bytes20(hex"b5320b0b3a13cc860893e2bd79fcd7e13484dda2")),
            address(bytes20(hex"c70ab6f32772f59fbfc23889caf4ba3376c84baf")),
            address(bytes20(hex"2cca08ae69e0c44b18a57ab2a87644234daebae4")),
            address(bytes20(hex"6498b0632f3834d7647367334838111c8c889703")),
            dvns
        );
    }

    function testRobinhoodExplicitRouteConfigQuoteAndLocalSend() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        address[] memory dvns = new address[](3);
        dvns[0] = address(bytes20(hex"d01ae6905d48315f7be10c7330aecf8360ef5b12"));
        dvns[1] = address(bytes20(hex"0ffe02df012299a370d5dd69298a5826eacafdf8"));
        dvns[2] = address(bytes20(hex"1258a278519c7f4bd997a9c3bfd4aa802a028d89"));
        _check(
            30416,
            30184,
            address(bytes20(hex"6f475642a6e85809b1c36fa62763669b1b48dd5b")),
            address(bytes20(hex"c39161c743d0307eb9bcc9fef03eeb9dc4802de7")),
            address(bytes20(hex"e1844c5d63a9543023008d332bd3d2e6f1fe1043")),
            address(bytes20(hex"4208d6e27538189bb48e603d6123a94b8abe0a0b")),
            address(bytes20(hex"6788f52439aca6bff597d3eec2dc9a44b8fee842")),
            dvns
        );
    }

    function _check(
        uint32 local_,
        uint32 remote_,
        address endpoint_,
        address sendLib,
        address receiveLib,
        address executor_,
        address dead,
        address[] memory dvns
    ) private {
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(endpoint_);
        assertEq(endpoint.eid(), local_);
        assertTrue(endpoint.isRegisteredLibrary(sendLib));
        assertTrue(endpoint.isRegisteredLibrary(receiveLib));
        GoldRouteProbe probe = new GoldRouteProbe(endpoint_, local_, remote_);
        probe.setPeer(remote_, bytes32(uint256(uint160(makeAddr("fork-peer")))));
        {
            Uln memory initial = abi.decode(endpoint.getConfig(address(probe), sendLib, remote_, 2), (Uln));
            assertEq(initial.requiredDVNCount, 1);
            assertEq(initial.requiredDVNs[0], dead);
        }
        // Sort numerically as required by ULN; names/order from registry do not set priority.
        for (uint256 i; i < dvns.length; ++i) {
            for (uint256 j = i + 1; j < dvns.length; ++j) {
                if (dvns[j] < dvns[i]) (dvns[i], dvns[j]) = (dvns[j], dvns[i]);
            }
        }
        Uln memory explicit_ = Uln(20, 3, 0, 0, dvns, new address[](0));
        endpoint.setSendLibrary(address(probe), remote_, sendLib);
        endpoint.setReceiveLibrary(address(probe), remote_, receiveLib, 0);
        {
            SetConfigParam[] memory config = new SetConfigParam[](2);
            config[0] = SetConfigParam(remote_, 2, abi.encode(explicit_));
            config[1] = SetConfigParam(remote_, 1, abi.encode(Executor(10000, executor_)));
            endpoint.setConfig(address(probe), sendLib, config);
            SetConfigParam[] memory incoming = new SetConfigParam[](1);
            incoming[0] = config[0];
            endpoint.setConfig(address(probe), receiveLib, incoming);
        }
        assertFalse(endpoint.isDefaultSendLibrary(address(probe), remote_));
        {
            (address actualReceive, bool isDefault) = endpoint.getReceiveLibrary(address(probe), remote_);
            assertEq(actualReceive, receiveLib);
            assertFalse(isDefault);
        }
        assertEq(endpoint.getConfig(address(probe), sendLib, remote_, 2), abi.encode(explicit_));
        assertEq(endpoint.getConfig(address(probe), receiveLib, remote_, 2), abi.encode(explicit_));
        // Type-3 executor option encoding, using the vendored protocol encoder (zero receive value).
        bytes memory receiveOption = ExecutorOptions.encodeLzReceiveOption(1500000, 0);
        bytes memory options =
            abi.encodePacked(uint16(3), uint8(1), uint16(receiveOption.length + 1), uint8(1), receiveOption);
        bytes32 id = probe.queueProbe();
        MessagingFee memory fee = probe.quoteDispatch(id, options);
        assertGt(fee.nativeFee, 0);
        assertEq(fee.lzTokenFee, 0);
        vm.deal(address(this), fee.nativeFee);
        bytes32 guid = probe.dispatch{value: fee.nativeFee}(id, options);
        assertTrue(guid != bytes32(0));
    }
}
