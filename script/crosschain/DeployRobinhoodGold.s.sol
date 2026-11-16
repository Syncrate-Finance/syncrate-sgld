// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GoldDeploymentProfile} from "./GoldDeploymentProfile.sol";
import {RobinhoodGold} from "../../src/crosschain/RobinhoodGold.sol";

/// @notice Creates the paused remote token/engine. Does not bind peers, unpause or move funds.
contract DeployRobinhoodGold is GoldDeploymentProfile {
    function run() external returns (RobinhoodGold gateway) {
        require(block.chainid == 4663, "Robinhood mainnet required");
        require(USDG.code.length != 0, "USDG missing");
        require(
            _implementation(USDG) == USDG_IMPLEMENTATION && USDG_IMPLEMENTATION.codehash == USDG_RUNTIME_HASH,
            "USDG implementation changed; review first"
        );
        require(
            IERC20Metadata(USDG).decimals() == 6
                && keccak256(bytes(IERC20Metadata(USDG).symbol())) == keccak256("USDG"),
            "USDG identity changed"
        );
        require(TREASURY.code.length != 0, "Selected treasury is not deployed");
        _feedIdentity(USDG_FEED, "USDG / USD");
        vm.startBroadcast(DEPLOYER);
        gateway = new RobinhoodGold(ROBINHOOD_ENDPOINT, ADMIN, 30416, 30184, USDG, USDG_FEED, TREASURY);
        vm.stopBroadcast();
        require(gateway.owner() == ADMIN && gateway.paused(), "Owner/pause mismatch");
        require(
            gateway.FEE_RECIPIENT() == TREASURY && address(gateway.usdgPriceFeed()) == USDG_FEED,
            "Treasury/feed mismatch"
        );
        require(gateway.peers(30184) == bytes32(0) && gateway.totalSupply() == 0, "Unexpected active state");
        require(gateway.totalReservedUSDG() == 0, "Unexpected liability");
        console2.log("Robinhood token/engine (paused, no peer)", address(gateway));
        console2.log("Admin and LayerZero delegate", ADMIN);
        console2.log("Owner-managed treasury", TREASURY);
    }
}
