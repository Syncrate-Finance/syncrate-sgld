// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldMessages as G, IGoldSettlementOracle} from "./GoldMessages.sol";
import {GoldFeedReader, IGoldAggregator} from "./GoldFeedReader.sol";

/// @notice Base gold pricing plus a USDG snapshot attested by the authenticated Robinhood peer.
/// @dev Public view quotes do not authenticate caller-supplied snapshots. Only the controller's
///      authenticated request path may use them to issue or retire backing. No constant peg.
contract GoldSettlementOracle is IGoldSettlementOracle {
    IGoldAggregator public immutable gold;
    uint256 public immutable goldMaxAge;
    uint256 private immutable goldScale;
    error InvalidFeed();

    constructor(address gold_, uint256 goldAge) {
        if (goldAge == 0 || goldAge > G.MAX_FEED_AGE) revert InvalidFeed();
        gold = IGoldAggregator(gold_);
        goldScale = GoldFeedReader.scale(gold);
        goldMaxAge = goldAge;
    }

    function mintOutput(uint256 amount, G.PriceSnapshot calldata price) external view returns (uint256) {
        if (!G.validPrice(price)) revert InvalidFeed();
        return
            Math.mulDiv(
                amount, price.priceUSD18 * 1e12, GoldFeedReader.snapshot(gold, goldScale, goldMaxAge).priceUSD18
            );
    }

    /// @return USDG units (6 decimals), before the redemption fee.
    function redeemOutput(uint256 amount, G.PriceSnapshot calldata price) external view returns (uint256) {
        if (!G.validPrice(price)) revert InvalidFeed();
        return
            Math.mulDiv(
                amount, GoldFeedReader.snapshot(gold, goldScale, goldMaxAge).priceUSD18, price.priceUSD18 * 1e12
            );
    }
}
