// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library GoldMessages {
    uint8 internal constant VERSION = 2;
    uint256 internal constant MAX_FEED_AGE = 1 days;
    uint256 internal constant MAX_REQUEST_AGE = 15 minutes;
    enum Kind {
        Mint,
        Redeem,
        Cancel,
        Result,
        Credit,
        Return
    }
    enum State {
        None,
        Pending,
        Accepted,
        Rejected,
        Refunded
    }

    struct PriceSnapshot {
        uint256 priceUSD18;
        uint80 roundId;
        uint256 updatedAt;
        uint256 observedAt;
    }

    struct Request {
        bytes32 id;
        Kind kind;
        address owner;
        address recipient;
        uint256 amount;
        uint256 minOutput;
        uint256 deadline;
        PriceSnapshot usdgPrice;
    }

    struct Result {
        bytes32 id;
        bytes32 requestHash;
        bool accepted;
        uint256 output;
    }

    struct Transfer {
        bytes32 id;
        address recipient;
        uint256 amount;
    }

    function encode(Kind kind, bytes memory body) internal pure returns (bytes memory) {
        return abi.encode(VERSION, kind, body);
    }

    function validPrice(PriceSnapshot memory p) internal view returns (bool) {
        return p.priceUSD18 > 0 && p.priceUSD18 <= type(uint128).max && p.roundId != 0 && p.updatedAt > 0
            && p.updatedAt <= p.observedAt && p.observedAt <= block.timestamp
            && block.timestamp - p.updatedAt <= MAX_FEED_AGE && block.timestamp - p.observedAt <= MAX_REQUEST_AGE;
    }
}

interface IGoldSettlementOracle {
    function mintOutput(uint256 usdgAmount, GoldMessages.PriceSnapshot calldata price) external view returns (uint256);
    function redeemOutput(uint256 sgldAmount, GoldMessages.PriceSnapshot calldata price) external view returns (uint256);
}
