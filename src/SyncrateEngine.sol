// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface ISGLDToken {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

/// @title Syncrate Mint & Redeem Engine
/// @notice Handles collateral deposits, oracle data, asynchronous FIFO redemptions,
///         and cross-chain capacity reservations.
contract SyncrateEngine is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ISGLDToken public sgldToken;
    AggregatorV3Interface public goldPriceFeed;

    uint256 public reserveCap;
    
    // Fee configuration
    uint256 public redeemFeeBps; 
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    address public constant FEE_RECIPIENT = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;
    address public constant TREASURY = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;

    uint256 public oracleStalenessThreshold;

    // FIFO Queue
    struct RedemptionRequest {
        address account;
        address stablecoin;
        uint256 amountOwed;
    }

    RedemptionRequest[] public redemptionQueue;
    uint256 public nextQueueIndex;

    mapping(address => bool) public isAllowedCollateral;

    // Cross-chain reservation
    mapping(bytes32 => uint256) public reservedCapacity; // requestId => sgldAmount
    uint256 public totalReserved;

    // Events
    event CollateralStatusUpdated(address indexed token, bool allowed);
    event GoldPriceFeedUpdated(address indexed newPriceFeed);
    event SGLDMinted(address indexed user, address indexed collateralToken, uint256 sgldAmount, uint256 collateralSpent);
    event SGLDRedeemedImmediate(address indexed user, address indexed stablecoin, uint256 sgldBurned, uint256 stablecoinPaid, uint256 fee);
    event SGLDRedemptionQueued(uint256 indexed queueIndex, address indexed user, address indexed stablecoin, uint256 sgldBurned, uint256 stablecoinOwed);
    event QueueProcessed(uint256 indexed startIndex, uint256 indexed endIndex, uint256 totalPaidOut);
    event CapacityReserved(bytes32 indexed requestId, uint256 sgldAmount);
    event ReservationConfirmed(bytes32 indexed requestId, uint256 sgldAmount);
    event ReservationCancelled(bytes32 indexed requestId, uint256 sgldAmount);
    event SweptToTreasury(address indexed token, uint256 amount);

    // Custom Errors
    error SyncrateEngine__ExceedsReserveCap();
    error SyncrateEngine__InvalidOraclePrice();
    error SyncrateEngine__StaleOraclePrice();
    error SyncrateEngine__ZeroAmount();
    error SyncrateEngine__TokenNotAllowed();
    error SyncrateEngine__ExceedsMaxFee();
    error SyncrateEngine__QueueEmpty();
    error SyncrateEngine__AlreadyReserved();
    error SyncrateEngine__NoReservation();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin,
        address reserveManager,
        address _sgldToken,
        address _goldPriceFeed,
        uint256 _oracleStalenessThreshold
    ) initializer public {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(RESERVE_MANAGER_ROLE, reserveManager);
        _grantRole(UPGRADER_ROLE, defaultAdmin);

        sgldToken = ISGLDToken(_sgldToken);
        goldPriceFeed = AggregatorV3Interface(_goldPriceFeed);
        oracleStalenessThreshold = _oracleStalenessThreshold;
        
        redeemFeeBps = 25; 
    }

    // =========================================================================
    // GUARDRAILS & ADMINISTRATION
    // =========================================================================

    function updateReserveCap(uint256 newReserveCap) external onlyRole(RESERVE_MANAGER_ROLE) {
        reserveCap = newReserveCap;
    }

    function setCollateralToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isAllowedCollateral[token] = allowed;
        emit CollateralStatusUpdated(token, allowed);
    }

    function setGoldPriceFeed(address newGoldPriceFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        goldPriceFeed = AggregatorV3Interface(newGoldPriceFeed);
        emit GoldPriceFeedUpdated(newGoldPriceFeed);
    }

    function setRedeemFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert SyncrateEngine__ExceedsMaxFee();
        redeemFeeBps = newFeeBps;
    }

    function setOracleStalenessThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracleStalenessThreshold = newThreshold;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @notice Sweep exactly 40% of a stablecoin balance to the treasury.
    function sweepToTreasury(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert SyncrateEngine__ZeroAmount();

        uint256 amountToSweep = (balance * 40) / 100;
        if (amountToSweep == 0) revert SyncrateEngine__ZeroAmount();

        IERC20(token).safeTransfer(TREASURY, amountToSweep);
        emit SweptToTreasury(token, amountToSweep);
    }

    // =========================================================================
    // CROSS-CHAIN RESERVATION
    // =========================================================================

    function reserveCapacity(bytes32 requestId, uint256 sgldAmount) 
        external 
        onlyRole(RESERVE_MANAGER_ROLE) 
    {
        if (sgldAmount == 0) revert SyncrateEngine__ZeroAmount();
        if (reservedCapacity[requestId] != 0) revert SyncrateEngine__AlreadyReserved();

        if (sgldToken.totalSupply() + totalReserved + sgldAmount > reserveCap) {
            revert SyncrateEngine__ExceedsReserveCap();
        }

        reservedCapacity[requestId] = sgldAmount;
        totalReserved += sgldAmount;

        emit CapacityReserved(requestId, sgldAmount);
    }

    function confirmReservedMint(bytes32 requestId) 
        external 
        onlyRole(RESERVE_MANAGER_ROLE) 
    {
        uint256 amount = reservedCapacity[requestId];
        if (amount == 0) revert SyncrateEngine__NoReservation();

        delete reservedCapacity[requestId];
        totalReserved -= amount;

        emit ReservationConfirmed(requestId, amount);
    }

    function cancelReservation(bytes32 requestId) 
        external 
        onlyRole(RESERVE_MANAGER_ROLE) 
    {
        uint256 amount = reservedCapacity[requestId];
        if (amount == 0) revert SyncrateEngine__NoReservation();

        delete reservedCapacity[requestId];
        totalReserved -= amount;

        emit ReservationCancelled(requestId, amount);
    }

    // =========================================================================
    // MINT FLOW (0% Fee)
    // =========================================================================

    function mint(uint256 stablecoinAmount, address tokenAddress) external whenNotPaused {
        if (stablecoinAmount == 0) revert SyncrateEngine__ZeroAmount();
        if (!isAllowedCollateral[tokenAddress]) revert SyncrateEngine__TokenNotAllowed();

        (, int256 price, , uint256 updatedAt, ) = goldPriceFeed.latestRoundData();
        if (price <= 0) revert SyncrateEngine__InvalidOraclePrice();
        if (block.timestamp - updatedAt > oracleStalenessThreshold) revert SyncrateEngine__StaleOraclePrice();

        uint256 sgldAmountToMint = (stablecoinAmount * 1e20) / uint256(price);
        
        if (sgldAmountToMint == 0) revert SyncrateEngine__ZeroAmount();
        
        if (sgldToken.totalSupply() + totalReserved + sgldAmountToMint > reserveCap) {
            revert SyncrateEngine__ExceedsReserveCap();
        }

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), stablecoinAmount);
        sgldToken.mint(msg.sender, sgldAmountToMint);

        emit SGLDMinted(msg.sender, tokenAddress, sgldAmountToMint, stablecoinAmount);
    }

    // =========================================================================
    // REDEEM FLOW
    // =========================================================================

    function redeem(uint256 sgldAmount, address stablecoinAddress) external whenNotPaused {
        if (sgldAmount == 0) revert SyncrateEngine__ZeroAmount();
        if (!isAllowedCollateral[stablecoinAddress]) revert SyncrateEngine__TokenNotAllowed();

        uint256 usdValue = getCollateralValueInUsd(sgldAmount);
        uint256 fee = (usdValue * redeemFeeBps) / BPS_DENOMINATOR;
        uint256 netOwed = usdValue - fee;

        sgldToken.burnFrom(msg.sender, sgldAmount);

        uint256 available = IERC20(stablecoinAddress).balanceOf(address(this));

        if (available >= netOwed + fee) {
            if (fee > 0) {
                IERC20(stablecoinAddress).safeTransfer(FEE_RECIPIENT, fee);
            }
            IERC20(stablecoinAddress).safeTransfer(msg.sender, netOwed);
            emit SGLDRedeemedImmediate(msg.sender, stablecoinAddress, sgldAmount, netOwed, fee);
        } else {
            if (fee > 0) {
                redemptionQueue.push(RedemptionRequest({
                    account: FEE_RECIPIENT,
                    stablecoin: stablecoinAddress,
                    amountOwed: fee
                }));
            }
            
            redemptionQueue.push(RedemptionRequest({
                account: msg.sender,
                stablecoin: stablecoinAddress,
                amountOwed: netOwed
            }));
            
            emit SGLDRedemptionQueued(redemptionQueue.length - 1, msg.sender, stablecoinAddress, sgldAmount, netOwed);
        }
    }

    function processQueue(uint256 maxIterations) external whenNotPaused {
        uint256 totalQueueLength = redemptionQueue.length;
        if (nextQueueIndex >= totalQueueLength) revert SyncrateEngine__QueueEmpty();

        uint256 iterations = 0;
        uint256 totalPaidThisTx = 0;
        uint256 startIndex = nextQueueIndex;

        while (nextQueueIndex < totalQueueLength && iterations < maxIterations) {
            RedemptionRequest memory request = redemptionQueue[nextQueueIndex];
            uint256 currentBuffer = IERC20(request.stablecoin).balanceOf(address(this));

            if (currentBuffer < request.amountOwed) {
                break;
            }

            nextQueueIndex++;
            iterations++;
            totalPaidThisTx += request.amountOwed;

            IERC20(request.stablecoin).safeTransfer(request.account, request.amountOwed);
        }

        if (iterations > 0) {
            emit QueueProcessed(startIndex, nextQueueIndex - 1, totalPaidThisTx);
        }
    }

    // =========================================================================
    // PRICE ORACLE & UTILITIES
    // =========================================================================

    function getCollateralValueInUsd(uint256 sgldAmount) public view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = goldPriceFeed.latestRoundData();
        
        if (price <= 0) revert SyncrateEngine__InvalidOraclePrice();
        if (block.timestamp - updatedAt > oracleStalenessThreshold) revert SyncrateEngine__StaleOraclePrice();

        return (sgldAmount * uint256(price)) / 1e20;
    }

    function getQueueLength() external view returns (uint256) {
        return redemptionQueue.length;
    }

    function _authorizeUpgrade(address newImplementation) internal onlyRole(UPGRADER_ROLE) override {}
}