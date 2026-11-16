// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SGLDToken} from "../../src/SGLDToken.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";
import {GoldMailbox} from "../../src/crosschain/GoldMailbox.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";
import {GoldSettlementOracle} from "../../src/crosschain/GoldSettlementOracle.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";
import {RobinhoodGold} from "../../src/crosschain/RobinhoodGold.sol";

interface IGoldReceiver {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

/// @dev Test-only transport. Deliberately permits duplicate/reordered packets; not a DVN simulator.
contract GoldEndpointMock {
    uint32 public immutable eid;
    uint64 public nonce;
    bool public sendFails;

    struct Packet {
        address sender;
        address receiver;
        uint64 nonce;
        bytes payload;
    }
    Packet[] internal packets;

    constructor(uint32 eid_) {
        eid = eid_;
    }
    function setDelegate(address) external {}

    function setSendFails(bool value) external {
        sendFails = value;
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(1, 0);
    }

    function send(MessagingParams calldata p, address) external payable returns (MessagingReceipt memory) {
        require(!sendFails && msg.value == 1 && !p.payInLzToken, "transport send");
        uint64 n = ++nonce;
        packets.push(Packet(msg.sender, address(uint160(uint256(p.receiver))), n, p.message));
        return MessagingReceipt(keccak256(abi.encode(eid, n)), n, MessagingFee(1, 0));
    }

    function count() external view returns (uint256) {
        return packets.length;
    }

    function packet(uint256 i) external view returns (Packet memory) {
        return packets[i];
    }

    function deliverPacket(GoldEndpointMock source, uint256 i) external {
        Packet memory p = source.packet(i);
        IGoldReceiver(p.receiver)
            .lzReceive(
                Origin(source.eid(), bytes32(uint256(uint160(p.sender))), p.nonce),
                keccak256(abi.encode(source.eid(), p.nonce)),
                p.payload,
                address(this),
                ""
            );
    }

    function inject(address to, uint32 source, address peer, bytes memory payload) external payable {
        IGoldReceiver(to).lzReceive{value: msg.value}(
            Origin(source, bytes32(uint256(uint160(peer))), 999), bytes32(uint256(999)), payload, address(this), ""
        );
    }
}

contract GoldUSDGMock is ERC20 {
    bool public taxed;
    address public frozen;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;
    constructor() ERC20("Test USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function setFrozen(address value) external {
        frozen = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != frozen || frozen == address(0), "frozen");
        if (callback != address(0) && from != address(0)) {
            (callbackSucceeded,) = callback.call(callbackData);
        }
        if (taxed && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, address(0), 1);
            --amount;
        }
        super._update(from, to, amount);
    }
}

contract GoldFeedMock {
    uint8 public immutable decimals;
    uint80 public round = 1;
    int256 public answer;
    uint256 public updated;
    uint80 public answered = 1;

    constructor(uint8 decimals_, int256 value) {
        decimals = decimals_;
        answer = value;
        updated = block.timestamp;
    }

    function set(int256 value, uint256 time, uint80 round_, uint80 answered_) external {
        answer = value;
        updated = time;
        round = round_;
        answered = answered_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updated, updated, answered);
    }
}

abstract contract GoldFixture is Test {
    GoldEndpointMock baseEndpoint;
    GoldEndpointMock remoteEndpoint;
    SGLDTokenCapped canonical;
    BaseGoldController base;
    RobinhoodGold remote;
    GoldUSDGMock usdg;
    GoldFeedMock goldFeed;
    GoldFeedMock usdgFeed;
    GoldSettlementOracle oracle;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    uint32 constant BASE = 30184;
    uint32 constant ROBIN = 30416;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 100 ether);
        canonical = SGLDTokenCapped(
            address(
                new ERC1967Proxy(address(new SGLDTokenCapped()), abi.encodeCall(SGLDToken.initialize, (address(this))))
            )
        );
        canonical.initializeGlobalSupplyCap();
        canonical.grantRole(canonical.MINTER_ROLE(), address(this));
        canonical.mint(alice, 10e18);
        goldFeed = new GoldFeedMock(8, 4000e8);
        usdgFeed = new GoldFeedMock(8, 1e8);
        oracle = new GoldSettlementOracle(address(goldFeed), address(usdgFeed), 1 days, 1 days);
        baseEndpoint = new GoldEndpointMock(BASE);
        remoteEndpoint = new GoldEndpointMock(ROBIN);
        usdg = new GoldUSDGMock();
        base = new BaseGoldController(
            address(baseEndpoint), address(this), BASE, ROBIN, address(canonical), address(oracle)
        );
        remote = new RobinhoodGold(address(remoteEndpoint), address(this), ROBIN, BASE, address(usdg));
        canonical.grantRole(canonical.MINTER_ROLE(), address(base));
        base.setPeer(ROBIN, bytes32(uint256(uint160(address(remote)))));
        remote.setPeer(BASE, bytes32(uint256(uint160(address(base)))));
        assertTrue(base.paused());
        assertTrue(remote.paused());
        base.setPaused(false);
        remote.setPaused(false);
        usdg.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdg.approve(address(remote), type(uint256).max);
        canonical.approve(address(base), type(uint256).max);
        vm.stopPrank();
    }

    function relay(GoldMailbox from, bytes32 messageId) internal {
        from.dispatch{value: 1}(messageId, "");
        if (address(from) == address(base)) remoteEndpoint.deliverPacket(baseEndpoint, baseEndpoint.count() - 1);
        else baseEndpoint.deliverPacket(remoteEndpoint, remoteEndpoint.count() - 1);
    }

    function bridge(uint256 amount) internal {
        vm.prank(alice);
        (, bytes32 messageId) = base.bridgeToRobinhood(amount, alice);
        relay(base, messageId);
    }

    function mintRequest(uint256 amount, uint256 minOut) internal returns (bytes32 id, bytes32 messageId) {
        vm.prank(alice);
        return remote.requestMint(amount, minOut, block.timestamp + 1 hours, alice);
    }

    function settleMint(uint256 amount) internal returns (bytes32 id) {
        bytes32 messageId;
        (id, messageId) = mintRequest(amount, 0);
        relay(remote, messageId);
        relay(base, base.responseMessages(id));
    }

    function redeemRequest(uint256 amount, uint256 minOut) internal returns (bytes32 id, bytes32 messageId) {
        vm.prank(alice);
        return remote.requestRedemption(amount, minOut, block.timestamp + 1 hours, alice);
    }

    function assertBacking() internal view {
        assertLe(remote.totalSupply(), base.backingLiability());
        assertLe(base.backingLiability(), canonical.totalSupply());
        assertGe(canonical.balanceOf(address(base)), base.backingLiability());
        assertLe(canonical.totalSupply(), 193e18);
    }
}
