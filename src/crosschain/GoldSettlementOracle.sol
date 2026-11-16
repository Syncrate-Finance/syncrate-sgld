// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGoldSettlementOracle} from "./GoldMessages.sol";

interface IGoldAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Development policy using TWO verified Base feeds: XAU/USD and USDG/USD.
/// @dev No assumed USDG peg, no guessed feed addresses, no offchain price setter.
contract GoldSettlementOracle is IGoldSettlementOracle {
    IGoldAggregator public immutable gold;
    IGoldAggregator public immutable usdg;
    uint256 public immutable goldMaxAge;
    uint256 public immutable usdgMaxAge;
    uint256 private immutable goldScale;
    uint256 private immutable usdgScale;
    error InvalidFeed();

    constructor(address gold_, address usdg_, uint256 goldAge, uint256 usdgAge) {
        if (gold_.code.length == 0 || usdg_.code.length == 0 || goldAge == 0 || usdgAge == 0) revert InvalidFeed();
        gold = IGoldAggregator(gold_);
        usdg = IGoldAggregator(usdg_);
        uint8 gd = gold.decimals();
        uint8 ud = usdg.decimals();
        if (gd > 18 || ud > 18) revert InvalidFeed();
        goldScale = 10 ** (18 - gd);
        usdgScale = 10 ** (18 - ud);
        goldMaxAge = goldAge;
        usdgMaxAge = usdgAge;
    }

    function mintOutput(uint256 amount) external view returns (uint256) {
        return Math.mulDiv(amount, _price(usdg, usdgScale, usdgMaxAge) * 1e12, _price(gold, goldScale, goldMaxAge));
    }

    /// @return USDG units (6 decimals), before the redemption fee.
    function redeemOutput(uint256 amount) external view returns (uint256) {
        return Math.mulDiv(amount, _price(gold, goldScale, goldMaxAge), _price(usdg, usdgScale, usdgMaxAge) * 1e12);
    }

    function _price(IGoldAggregator feed, uint256 scale, uint256 maxAge) private view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = feed.latestRoundData();
        if (
            round == 0 || answer <= 0 || updated == 0 || updated > block.timestamp || answered < round
                || block.timestamp - updated > maxAge
        ) {
            revert InvalidFeed();
        }
        return uint256(answer) * scale;
    }
}
