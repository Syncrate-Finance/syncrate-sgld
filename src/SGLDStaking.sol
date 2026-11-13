// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Fixed-term SGLD staking with non-transferable sySGLD principal receipts
/// @notice Rewards must be funded with existing, backed SGLD. No SGLD minting rights are needed.
/// @dev Not ERC-4626: every receipt represents one unit of principal; yield is claimed separately.
contract SGLDStaking is ERC20, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant MINIMUM_STAKE = 1e18;
    uint256 public constant DEPOSIT_FEE_BPS = 25;
    uint256 public constant REDEMPTION_FEE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    address public constant FEE_RECIPIENT = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;
    uint256 public constant MAX_PRINCIPAL = type(uint192).max;
    uint256 public constant MAX_EPOCH_DURATION = 90 days;
    uint256 public constant MAX_PROCESS_BATCH = 100;
    uint256 public constant MAX_CLAIM_BATCH = 32;

    IERC20 public immutable sgld;
    uint256 public immutable programStart;
    uint256 public totalPrincipal;
    uint256 public rewardReserve;
    uint256 public lastEpochEnd;

    struct Position {
        address owner;
        uint256 principal;
        uint256 openedAt;
        uint256 maturesAt;
        bool withdrawn;
    }

    struct Epoch {
        uint256 start;
        uint256 end;
        uint256 positionCount;
        uint256 cursor;
        uint256 totalWeight;
        uint256 funded;
        uint256 claimed;
        bool finalized;
    }

    Position[] public positions;
    Epoch[] public epochs;
    mapping(uint256 positionId => mapping(uint256 epochId => uint256 amount)) public claimedRewards;

    error InvalidAsset();
    error InvalidTerm();
    error BelowMinimum();
    error PrincipalLimit();
    error NonTransferable();
    error PositionLocked();
    error NotPositionOwner();
    error AlreadyWithdrawn();
    error InvalidEpoch();
    error EpochNotFinalized();
    error EpochAlreadyFinalized();
    error NoEligibleWeight();
    error InvalidBatch();
    error ZeroAmount();
    error UnsupportedTransfer();
    error Insolvent();

    event Staked(address indexed owner, uint256 indexed positionId, uint256 amount, uint256 maturesAt);
    event Withdrawn(address indexed owner, uint256 indexed positionId, uint256 principal, uint256 yieldPaid);
    event Restaked(address indexed owner, uint256 indexed oldPositionId, uint256 indexed newPositionId);
    event EpochCreated(uint256 indexed epochId, uint256 start, uint256 end, uint256 positionCount);
    event EpochProgress(uint256 indexed epochId, uint256 cursor, uint256 totalWeight, bool finalized);
    event YieldFunded(uint256 indexed epochId, address indexed funder, uint256 amount, uint256 cumulativeFunding);
    event YieldClaimed(address indexed owner, uint256 indexed positionId, uint256 indexed epochId, uint256 amount);
    event DepositFeePaid(address indexed owner, uint256 indexed positionId, uint256 grossAmount, uint256 fee);
    event RedemptionFeePaid(address indexed owner, uint256 indexed positionId, uint256 principal, uint256 fee);

    constructor(address asset, address admin, address funder, address pauser)
        ERC20("Syncrate Yield Gold", "sySGLD")
        AccessControlDefaultAdminRules(2 days, admin)
    {
        if (asset.code.length == 0 || IERC20Metadata(asset).decimals() != 18) {
            revert InvalidAsset();
        }
        if (funder == address(0) || pauser == address(0)) revert InvalidAsset();
        sgld = IERC20(asset);
        programStart = block.timestamp;
        lastEpochEnd = block.timestamp;
        _grantRole(FUNDER_ROLE, funder);
        _grantRole(PAUSER_ROLE, pauser);
    }

    function stake(uint256 amount, uint256 termDays) external nonReentrant whenNotPaused returns (uint256 id) {
        if (amount < MINIMUM_STAKE) revert BelowMinimum();
        _assertSolvent();
        (uint256 principal, uint256 fee) = previewDeposit(amount);
        id = _open(msg.sender, principal, termDays);
        _receiveExact(msg.sender, amount);
        if (fee != 0) _sendExact(FEE_RECIPIENT, fee);
        _assertSolvent();
        emit DepositFeePaid(msg.sender, id, amount, fee);
    }

    /// @notice Close a complete matured position and optionally collect up to 32 finalized epochs.
    /// @dev An empty epoch list always permits principal exit independently of reward settlement.
    function withdraw(uint256 positionId, uint256[] calldata epochIds) external nonReentrant {
        _assertSolvent();
        Position storage p = _ownedMaturePosition(positionId);
        if (p.withdrawn) revert AlreadyWithdrawn();
        p.withdrawn = true;
        totalPrincipal -= p.principal;
        _burn(msg.sender, p.principal);
        uint256 yieldPaid = _collect(positionId, epochIds);
        (uint256 principalPaid, uint256 fee) = previewRedemption(p.principal);
        if (fee != 0) _sendExact(FEE_RECIPIENT, fee);
        _sendExact(msg.sender, principalPaid + yieldPaid);
        _assertSolvent();
        emit RedemptionFeePaid(msg.sender, positionId, p.principal, fee);
        emit Withdrawn(msg.sender, positionId, p.principal, yieldPaid);
    }

    /// @notice Start a fresh 30/90-day term with a complete matured principal, without a token round trip.
    /// @dev Historical positions and their late-interest rights remain intact. Rewards do not auto-compound.
    function restake(uint256 positionId, uint256 termDays)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 newPositionId)
    {
        _assertSolvent();
        Position storage p = _ownedMaturePosition(positionId);
        if (p.withdrawn) revert AlreadyWithdrawn();
        p.withdrawn = true;
        totalPrincipal -= p.principal;
        _burn(msg.sender, p.principal);
        newPositionId = _open(msg.sender, p.principal, termDays);
        emit Restaked(msg.sender, positionId, newPositionId);
    }

    /// @notice Claim funded interest after maturity, including after principal exit or restaking.
    function claim(uint256 positionId, uint256[] calldata epochIds) external nonReentrant returns (uint256 amount) {
        _assertSolvent();
        _ownedMaturePosition(positionId);
        amount = _collect(positionId, epochIds);
        if (amount != 0) _sendExact(msg.sender, amount);
        _assertSolvent();
    }

    /// @notice Create a contiguous, already elapsed earning period. Periods may be funded much later.
    /// @dev Snapshot includes every possible eligible position; later positions cannot earn in the past.
    function createEpoch(uint256 end) external onlyRole(FUNDER_ROLE) returns (uint256 id) {
        if (end <= lastEpochEnd || end > block.timestamp || end - lastEpochEnd > MAX_EPOCH_DURATION) {
            revert InvalidEpoch();
        }
        id = epochs.length;
        epochs.push(Epoch(lastEpochEnd, end, positions.length, 0, 0, 0, 0, positions.length == 0));
        emit EpochCreated(id, lastEpochEnd, end, positions.length);
        lastEpochEnd = end;
    }

    /// @notice Anyone may advance deterministic historical weighting in bounded batches.
    /// @dev No trusted offchain allocation, holder snapshot or caller-provided weights are used.
    function processEpoch(uint256 epochId, uint256 maxPositions) external {
        if (maxPositions == 0 || maxPositions > MAX_PROCESS_BATCH) revert InvalidBatch();
        Epoch storage e = epochs[epochId];
        if (e.finalized) revert EpochAlreadyFinalized();
        uint256 stop = Math.min(e.cursor + maxPositions, e.positionCount);
        for (uint256 i = e.cursor; i < stop; ++i) {
            e.totalWeight += _weight(positions[i], e.start, e.end);
        }
        e.cursor = stop;
        e.finalized = stop == e.positionCount;
        emit EpochProgress(epochId, stop, e.totalWeight, e.finalized);
    }

    /// @notice Fund a finalized earning period using an exact transfer of existing SGLD.
    /// @dev Repeated funding is additive; previous claimants can collect only their incremental entitlement.
    function fundEpoch(uint256 epochId, uint256 amount) external onlyRole(FUNDER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _assertSolvent();
        Epoch storage e = epochs[epochId];
        if (!e.finalized) revert EpochNotFinalized();
        if (e.totalWeight == 0) revert NoEligibleWeight();
        e.funded += amount;
        rewardReserve += amount;
        _receiveExact(msg.sender, amount);
        _assertSolvent();
        emit YieldFunded(epochId, msg.sender, amount, e.funded);
    }

    function claimable(uint256 positionId, uint256 epochId) public view returns (uint256) {
        Position storage p = positions[positionId];
        Epoch storage e = epochs[epochId];
        if (block.timestamp < p.maturesAt || !e.finalized || e.totalWeight == 0) return 0;
        return Math.mulDiv(e.funded, _weight(p, e.start, e.end), e.totalWeight) - claimedRewards[positionId][epochId];
    }

    function positionWeight(uint256 positionId, uint256 epochId) external view returns (uint256) {
        Epoch storage e = epochs[epochId];
        return _weight(positions[positionId], e.start, e.end);
    }

    /// @notice Quote net principal/receipts and the fee on a gross SGLD deposit. Minimum checked by stake().
    function previewDeposit(uint256 grossAmount) public pure returns (uint256 principal, uint256 fee) {
        fee = Math.mulDiv(grossAmount, DEPOSIT_FEE_BPS, BPS_DENOMINATOR);
        principal = grossAmount - fee;
    }

    /// @notice Quote net principal payout and redemption fee. Yield is not included or charged.
    function previewRedemption(uint256 principal) public pure returns (uint256 principalPaid, uint256 fee) {
        fee = Math.mulDiv(principal, REDEMPTION_FEE_BPS, BPS_DENOMINATOR);
        principalPaid = principal - fee;
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }

    function pauseDeposits() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpauseDeposits() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _open(address owner, uint256 amount, uint256 termDays) private returns (uint256 id) {
        if (amount == 0) revert BelowMinimum();
        if (termDays != 30 && termDays != 90) revert InvalidTerm();
        if (amount > MAX_PRINCIPAL - totalPrincipal) revert PrincipalLimit();
        totalPrincipal += amount;
        id = positions.length;
        uint256 maturity = block.timestamp + termDays * 1 days;
        positions.push(Position(owner, amount, block.timestamp, maturity, false));
        _mint(owner, amount);
        emit Staked(owner, id, amount, maturity);
    }

    function _ownedMaturePosition(uint256 id) private view returns (Position storage p) {
        p = positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (block.timestamp < p.maturesAt) revert PositionLocked();
    }

    function _collect(uint256 positionId, uint256[] calldata ids) private returns (uint256 total) {
        if (ids.length > MAX_CLAIM_BATCH) revert InvalidBatch();
        for (uint256 i; i < ids.length; ++i) {
            uint256 epochId = ids[i];
            Epoch storage e = epochs[epochId];
            if (!e.finalized) revert EpochNotFinalized();
            uint256 amount = claimable(positionId, epochId);
            if (amount == 0) continue;
            claimedRewards[positionId][epochId] += amount;
            e.claimed += amount;
            rewardReserve -= amount;
            total += amount;
            emit YieldClaimed(msg.sender, positionId, epochId, amount);
        }
    }

    function _weight(Position storage p, uint256 start, uint256 end) private view returns (uint256) {
        uint256 left = Math.max(p.openedAt, start);
        uint256 right = Math.min(p.maturesAt, end);
        return right > left ? p.principal * (right - left) : 0;
    }

    function _receiveExact(address from, uint256 amount) private {
        uint256 beforeBalance = sgld.balanceOf(address(this));
        sgld.safeTransferFrom(from, address(this), amount);
        if (sgld.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedTransfer();
    }

    function _assertSolvent() private view {
        if (sgld.balanceOf(address(this)) < totalPrincipal + rewardReserve) revert Insolvent();
    }

    function _sendExact(address to, uint256 amount) private {
        uint256 beforeBalance = sgld.balanceOf(address(this));
        uint256 beforeRecipient = sgld.balanceOf(to);
        sgld.safeTransfer(to, amount);
        if (sgld.balanceOf(address(this)) != beforeBalance - amount || sgld.balanceOf(to) != beforeRecipient + amount) {
            revert UnsupportedTransfer();
        }
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, amount);
    }
}

