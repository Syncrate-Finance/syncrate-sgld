// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    ILayerZeroEndpointV2,
    Origin,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GoldMessages as G} from "./GoldMessages.sol";

/// @notice Proxy-initialized authenticated mailbox. Layout must be preserved by future upgrades.
abstract contract GoldMailboxUpgradeable is AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    ILayerZeroEndpointV2 public endpoint;
    uint32 public localEid;
    uint32 public remoteEid;
    uint256 public nonce;
    mapping(uint32 => bytes32) public peers;
    mapping(bytes32 => bytes) public outbox;
    mapping(bytes32 => bool) public received;
    address public messagingDelegate;
    uint256[40] private __gap;
    error InvalidConfiguration();
    error InvalidMessage();
    error InvalidTransfer();
    error MissingMessage();
    event PeerSet(uint32 eid, bytes32 peer);
    event MessageQueued(bytes32 indexed messageId, bytes payload);
    event MessageDispatched(bytes32 indexed messageId, bytes32 indexed guid);
    event MessageReceived(bytes32 indexed messageId, bytes32 indexed guid);

    function __GoldMailbox_init(address endpoint_, address admin, uint32 local_, uint32 remote_)
        internal
        onlyInitializing
    {
        // Pinned OZ 5.5 guard uses a dedicated storage namespace; proxy zero state is not ENTERED.
        __AccessControl_init();
        __Pausable_init();
        if (admin == address(0) || endpoint_.code.length == 0 || local_ == 0 || remote_ == 0 || local_ == remote_) {
            revert InvalidConfiguration();
        }
        endpoint = ILayerZeroEndpointV2(endpoint_);
        if (endpoint.eid() != local_) revert InvalidConfiguration();
        localEid = local_;
        remoteEid = remote_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        endpoint.setDelegate(admin);
        messagingDelegate = admin;
        _pause();
    }

    function setDelegate(address delegate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delegate == address(0) || !hasRole(DEFAULT_ADMIN_ROLE, delegate)) revert InvalidConfiguration();
        endpoint.setDelegate(delegate);
        messagingDelegate = delegate;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool changed) {
        changed = super._revokeRole(role, account);
        if (changed && role == DEFAULT_ADMIN_ROLE && account == messagingDelegate) {
            // Clear the removed administrator's independent Endpoint permission as well.
            messagingDelegate = address(this);
            endpoint.setDelegate(address(this));
        }
    }

    function setPeer(uint32 eid_, bytes32 peer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (eid_ != remoteEid || peer == bytes32(0) || uint256(peer) > type(uint160).max || peers[eid_] != bytes32(0)) {
            revert InvalidConfiguration();
        }
        peers[eid_] = peer;
        emit PeerSet(eid_, peer);
    }

    function setPaused(bool value) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (value) {
            _pause();
        } else {
            _peer();
            _unpause();
        }
    }

    function pause() external {
        setPaused(true);
    }

    function unpause() external {
        setPaused(false);
    }

    function _peer() internal view returns (bytes32 peer) {
        peer = peers[remoteEid];
        if (peer == bytes32(0)) revert InvalidConfiguration();
    }

    function oAppVersion() external pure returns (uint64, uint64) {
        return (1, 2);
    }

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return origin.srcEid == remoteEid && origin.sender != bytes32(0) && origin.sender == peers[remoteEid];
    }

    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }

    function isComposeMsgSender(Origin calldata, bytes calldata, address sender) external view returns (bool) {
        return sender == address(this);
    }

    function quoteDispatch(bytes32 id, bytes calldata options) external view returns (MessagingFee memory) {
        bytes memory message = outbox[id];
        if (message.length == 0) revert MissingMessage();
        return endpoint.quote(MessagingParams(remoteEid, _peer(), message, options, false), address(this));
    }

    function dispatch(bytes32 id, bytes calldata options) external payable nonReentrant returns (bytes32) {
        bytes memory message = outbox[id];
        if (message.length == 0) revert MissingMessage();
        MessagingReceipt memory receipt =
            endpoint.send{value: msg.value}(MessagingParams(remoteEid, _peer(), message, options, false), msg.sender);
        emit MessageDispatched(id, receipt.guid);
        return receipt.guid;
    }

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode(localEid, address(this), ++nonce));
    }

    function _queue(G.Kind kind, bytes memory body) internal returns (bytes32 id) {
        bytes memory message = G.encode(kind, body);
        id = keccak256(message);
        if (outbox[id].length == 0) {
            outbox[id] = message;
            emit MessageQueued(id, message);
        }
    }

    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata payload, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(endpoint) || origin.srcEid != remoteEid || origin.sender != _peer() || msg.value != 0)
        {
            revert InvalidMessage();
        }
        bytes32 id = keccak256(payload);
        if (received[id]) return;
        (uint8 version, G.Kind kind, bytes memory body) = abi.decode(payload, (uint8, G.Kind, bytes));
        if (version != G.VERSION) revert InvalidMessage();
        received[id] = true;
        _handle(kind, body);
        emit MessageReceived(id, guid);
    }
    function _handle(G.Kind kind, bytes memory body) internal virtual;

    function _takeExact(IERC20 token, address from, uint256 amount) internal {
        if (from == address(this) || amount == 0) revert InvalidTransfer();
        uint256 before_ = token.balanceOf(address(this));
        uint256 senderBefore = token.balanceOf(from);
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != before_ + amount || token.balanceOf(from) + amount != senderBefore) {
            revert InvalidTransfer();
        }
    }

    function _payExact(IERC20 token, address to, uint256 amount) internal {
        if (to == address(0) || to == address(this)) revert InvalidTransfer();
        uint256 before_ = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) + amount != before_ || token.balanceOf(to) != recipientBefore + amount) {
            revert InvalidTransfer();
        }
    }
}
