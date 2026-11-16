// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library GoldMessages {
    uint8 internal constant VERSION = 1;
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

    struct Request {
        bytes32 id;
        Kind kind;
        address owner;
        address recipient;
        uint256 amount;
        uint256 minOutput;
        uint256 deadline;
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
}

interface IGoldSettlementOracle {
    function mintOutput(uint256 usdgAmount) external view returns (uint256);
    function redeemOutput(uint256 sgldAmount) external view returns (uint256);
}
