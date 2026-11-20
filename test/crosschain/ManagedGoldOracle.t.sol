// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {GoldFeedMock} from "./GoldEngineFixture.sol";
import {GoldSettlementOracleManaged} from "../../src/crosschain/GoldSettlementOracleManaged.sol";
import {GoldMessages as G} from "../../src/crosschain/GoldMessages.sol";

contract NamedXauFeed {
    GoldFeedMock public immutable source;

    constructor(GoldFeedMock source_) {
        source = source_;
    }

    function description() external pure returns (string memory) {
        return "XAU / USD";
    }

    function decimals() external view returns (uint8) {
        return source.decimals();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return source.latestRoundData();
    }
}

contract ManagedGoldOracleTest is Test {
    GoldFeedMock feed;
    GoldSettlementOracleManaged oracle;

    function setUp() public {
        vm.warp(1800000000);
        feed = new GoldFeedMock(8, 4000e8);
        oracle = new GoldSettlementOracleManaged(address(this), address(new NamedXauFeed(feed)), 86400);
    }

    function testValidatedFeedAndStalenessAdministration() public {
        assertEq(oracle.getCollateralValueInUsd(1e18), 4000e18);
        vm.prank(address(123));
        vm.expectRevert();
        oracle.setGoldPriceFeed(address(feed));
        vm.expectRevert();
        oracle.setGoldPriceFeed(address(feed));
        vm.expectRevert();
        oracle.setOracleStalenessThreshold(0);
        oracle.setOracleStalenessThreshold(60);
        vm.warp(block.timestamp + 61);
        vm.expectRevert();
        oracle.getCollateralValueInUsd(1e18);
    }

    function testNewGoldFeedChangesQuotesButNotExistingSupply() public {
        GoldFeedMock next = new GoldFeedMock(18, 5000e18);
        oracle.setGoldPriceFeed(address(new NamedXauFeed(next)));
        G.PriceSnapshot memory p = G.PriceSnapshot(1e18, 1, block.timestamp, block.timestamp);
        assertEq(oracle.mintOutput(5000e6, p), 1e18);
        assertEq(oracle.redeemOutput(1e18, p), 5000e6);
        assertEq(oracle.getCollateralValueInUsd(2e18), 10000e18);
    }
}
