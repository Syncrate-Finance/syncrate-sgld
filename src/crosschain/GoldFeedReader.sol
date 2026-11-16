// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GoldMessages as G} from "./GoldMessages.sol";

interface IGoldAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

library GoldFeedReader {
    error InvalidFeed();

    function scale(IGoldAggregator feed) internal view returns (uint256) {
        if (address(feed).code.length == 0) revert InvalidFeed();
        uint8 decimals = feed.decimals();
        if (decimals > 18) revert InvalidFeed();
        return 10 ** (18 - decimals);
    }

    function snapshot(IGoldAggregator feed, uint256 scale_, uint256 maxAge)
        internal
        view
        returns (G.PriceSnapshot memory p)
    {
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = feed.latestRoundData();
        if (
            round == 0 || answer <= 0 || updated == 0 || updated > block.timestamp || answered < round
                || block.timestamp - updated > maxAge
        ) revert InvalidFeed();
        p = G.PriceSnapshot(uint256(answer) * scale_, round, updated, block.timestamp);
        if (!G.validPrice(p)) revert InvalidFeed();
    }
}
