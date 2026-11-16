// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GoldMessages as G} from "./GoldMessages.sol";

/// @notice Development OApp: immutable single route, persistent permissionless fee-funded outbox.
/// @dev Starts paused. Peer can only be bound once; migration needs a separate reviewed design.
abstract contract GoldMailbox is OApp, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint32 public immutable localEid;
    uint32 public immutable remoteEid;
    uint256 public nonce;
    mapping(bytes32 => bytes) public outbox;
    mapping(bytes32 => bool) public received;

    error InvalidConfiguration();
    error InvalidMessage();
    error InvalidTransfer();
    error MissingMessage();
    event MessageQueued(bytes32 indexed messageId, bytes payload);
    event MessageDispatched(bytes32 indexed messageId, bytes32 indexed guid);
    event MessageReceived(bytes32 indexed messageId, bytes32 indexed guid);

    constructor(address endpoint_, address admin, uint32 local_, uint32 remote_) OApp(endpoint_, admin) Ownable(admin) {
        if (endpoint_.code.length == 0 || local_ == 0 || remote_ == 0 || local_ == remote_ || endpoint.eid() != local_)
        {
            revert InvalidConfiguration();
        }
        localEid = local_;
        remoteEid = remote_;
        _pause();
    }

    function setPeer(uint32 eid_, bytes32 peer) public override onlyOwner {
        if (eid_ != remoteEid || peer == bytes32(0) || uint256(peer) > type(uint160).max || peers[eid_] != bytes32(0)) {
            revert InvalidConfiguration();
        }
        _setPeer(eid_, peer);
    }

    function setPaused(bool value) external onlyOwner {
        if (value) {
            _pause();
        } else {
            _getPeerOrRevert(remoteEid);
            _unpause();
        }
    }

    function renounceOwnership() public view override onlyOwner {
        revert InvalidConfiguration();
    }

    function quoteDispatch(bytes32 messageId, bytes calldata options) external view returns (MessagingFee memory) {
        bytes memory message = outbox[messageId];
        if (message.length == 0) revert MissingMessage();
        return _quote(remoteEid, message, options, false);
    }

    /// @notice Anyone can pay to send/retry an already committed payload; no arbitrary payloads.
    /// @dev Delivery never requires a synchronous fee-funded response. Response is its own outbox entry.
    function dispatch(bytes32 messageId, bytes calldata options) external payable nonReentrant returns (bytes32) {
        bytes memory message = outbox[messageId];
        if (message.length == 0) revert MissingMessage();
        MessagingReceipt memory receipt = _lzSend(remoteEid, message, options, MessagingFee(msg.value, 0), msg.sender);
        emit MessageDispatched(messageId, receipt.guid);
        return receipt.guid;
    }

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode(localEid, address(this), ++nonce));
    }

    function _queue(G.Kind kind, bytes memory body) internal returns (bytes32 id) {
        bytes memory payload = G.encode(kind, body);
        id = keccak256(payload);
        if (outbox[id].length == 0) {
            outbox[id] = payload;
            emit MessageQueued(id, payload);
        }
    }

    function _lzReceive(Origin calldata origin, bytes32 guid, bytes calldata payload, address, bytes calldata)
        internal
        override
        nonReentrant
    {
        // Replies are separately fee-funded through dispatch; native value drops are unsupported.
        if (origin.srcEid != remoteEid || msg.value != 0) revert InvalidMessage();
        bytes32 id = keccak256(payload);
        if (received[id]) return;
        (uint8 version, G.Kind kind, bytes memory body) = abi.decode(payload, (uint8, G.Kind, bytes));
        if (version != G.VERSION) revert InvalidMessage();
        received[id] = true;
        _handle(kind, body);
        emit MessageReceived(id, guid);
    }

    function _handle(G.Kind kind, bytes memory body) internal virtual;

    function _takeExact(IERC20 asset, address from, uint256 amount) internal {
        if (from == address(this)) revert InvalidTransfer();
        uint256 before_ = asset.balanceOf(address(this));
        uint256 senderBefore = asset.balanceOf(from);
        asset.safeTransferFrom(from, address(this), amount);
        if (asset.balanceOf(address(this)) != before_ + amount || asset.balanceOf(from) + amount != senderBefore) {
            revert InvalidTransfer();
        }
    }

    function _payExact(IERC20 asset, address to, uint256 amount) internal {
        if (to == address(0) || to == address(this)) revert InvalidTransfer();
        uint256 before_ = asset.balanceOf(address(this));
        uint256 recipientBefore = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        if (asset.balanceOf(address(this)) + amount != before_ || asset.balanceOf(to) != recipientBefore + amount) {
            revert InvalidTransfer();
        }
    }
}
