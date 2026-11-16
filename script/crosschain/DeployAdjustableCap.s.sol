// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {console2} from "forge-std/console2.sol";
import {GoldDeploymentProfile} from "./GoldDeploymentProfile.sol";
import {SGLDTokenAdjustableCap} from "../../src/SGLDTokenAdjustableCap.sol";

/// @notice Creates the correction implementation only; never upgrades the proxy or increases inventory.
contract DeployAdjustableCap is GoldDeploymentProfile {
    function run() external returns (SGLDTokenAdjustableCap implementation) {
        _baseChecks();
        require(
            _implementation(ASSET) == 0x7A930a4B191A6e88281681380426C821C5d0B19E, "Fixed cap implementation changed"
        );
        require(
            0x7A930a4B191A6e88281681380426C821C5d0B19E.codehash
                == 0x8668fc8322a3b1765e71e2cc29685f9cfd83c2a7d56ca8f022069e6f6938b8ef,
            "Fixed cap runtime changed"
        );
        require(SGLDTokenAdjustableCap(ASSET).MAX_CANONICAL_SUPPLY() == 193e18, "Current inventory changed");
        require(SGLDTokenAdjustableCap(ASSET).globalSupplyCapInitialized(), "Fixed cap not initialized");
        require(SGLDTokenAdjustableCap(ASSET).totalSupply() <= 193e18, "Supply exceeds current inventory");
        vm.startBroadcast(DEPLOYER);
        implementation = new SGLDTokenAdjustableCap();
        vm.stopBroadcast();
        console2.log("Adjustable cap implementation only", address(implementation));
        console2.logBytes32(address(implementation).codehash);
    }
}
