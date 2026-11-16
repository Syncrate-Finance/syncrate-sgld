// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {console2} from "forge-std/console2.sol";
import {GoldDeploymentProfile} from "./GoldDeploymentProfile.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";

/// @notice Creates an implementation ONLY. Does not upgrade the live proxy or change any role.
contract DeployCanonicalCap is GoldDeploymentProfile {
    function run() external returns (SGLDTokenCapped implementation) {
        _baseChecks();
        require(SGLDTokenCapped(ASSET).totalSupply() <= 193e18, "Existing supply above legacy cap");
        require(_implementation(ASSET) == LEGACY_IMPLEMENTATION, "Base implementation changed; review first");
        vm.startBroadcast(DEPLOYER);
        implementation = new SGLDTokenCapped();
        vm.stopBroadcast();
        console2.log("Candidate implementation", address(implementation));
        console2.log("Runtime hash (verify actual deployed code before using)");
        console2.logBytes32(address(implementation).codehash);
        console2.log("Separate atomic proxy upgrade calldata, NOT executed by this script");
        console2.logBytes(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(implementation),
                abi.encodeCall(SGLDTokenCapped.initializeGlobalSupplyCap, ())
            )
        );
    }
}
