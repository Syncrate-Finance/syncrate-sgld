// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldMessages as G, IGoldSettlementOracle} from "./GoldMessages.sol";
import {GoldFeedReader, IGoldAggregator} from "./GoldFeedReader.sol";

/// @notice Canonical Base gold oracle administration. Remote USDG pricing remains on Robinhood.
contract GoldSettlementOracleManaged is AccessControl, IGoldSettlementOracle {
    IGoldAggregator public gold;
    uint256 private goldScale;
    uint256 public oracleStalenessThreshold;
    event GoldPriceFeedUpdated(address indexed newPriceFeed);
    event OracleStalenessThresholdUpdated(uint256 threshold);
    error InvalidConfiguration();

    constructor(address admin, address feed, uint256 maxAge) {
        if (admin == address(0)) revert InvalidConfiguration();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setFeed(feed);
        _setAge(maxAge);
    }

    function setGoldPriceFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeed(feed);
    }

    function setOracleStalenessThreshold(uint256 age) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAge(age);
    }

    function _setAge(uint256 age) private {
        if (age == 0 || age > G.MAX_FEED_AGE) revert InvalidConfiguration();
        oracleStalenessThreshold = age;
        emit OracleStalenessThresholdUpdated(age);
    }

    function _setFeed(address feed) private {
        if (feed.code.length == 0) revert InvalidConfiguration();
        (bool ok, bytes memory value) = feed.staticcall(abi.encodeWithSignature("description()"));
        if (!ok || keccak256(bytes(abi.decode(value, (string)))) != keccak256("XAU / USD")) {
            revert InvalidConfiguration();
        }
        gold = IGoldAggregator(feed);
        goldScale = GoldFeedReader.scale(gold);
        emit GoldPriceFeedUpdated(feed);
    }

    function getCollateralValueInUsd(uint256 sgldAmount) public view returns (uint256) {
        return
            Math.mulDiv(sgldAmount, GoldFeedReader.snapshot(gold, goldScale, oracleStalenessThreshold).priceUSD18, 1e18);
    }

    function mintOutput(uint256 amount, G.PriceSnapshot calldata price) external view returns (uint256) {
        if (!G.validPrice(price)) revert InvalidConfiguration();
        return Math.mulDiv(
            amount,
            price.priceUSD18 * 1e12,
            GoldFeedReader.snapshot(gold, goldScale, oracleStalenessThreshold).priceUSD18
        );
    }

    function redeemOutput(uint256 amount, G.PriceSnapshot calldata price) external view returns (uint256) {
        if (!G.validPrice(price)) revert InvalidConfiguration();
        return Math.mulDiv(
            amount,
            GoldFeedReader.snapshot(gold, goldScale, oracleStalenessThreshold).priceUSD18,
            price.priceUSD18 * 1e12
        );
    }
}
