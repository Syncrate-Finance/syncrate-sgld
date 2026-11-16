// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {console2} from "forge-std/console2.sol";
import {GoldDeploymentProfile} from "./GoldDeploymentProfile.sol";
import {SGLDTokenCapped} from "../../src/SGLDTokenCapped.sol";
import {GoldSettlementOracle} from "../../src/crosschain/GoldSettlementOracle.sol";
import {BaseGoldController} from "../../src/crosschain/BaseGoldController.sol";

/// @notice Creates oracle/controller only after the separately reviewed atomic cap upgrade.
/// @dev No minter grant, peer binding, limits, unpause or financial operation is included.
contract DeployBaseGoldController is GoldDeploymentProfile {
    function run() external returns (GoldSettlementOracle oracle, BaseGoldController controller) {
        return runWithVerifiedImplementation(
            vm.envAddress("SGLD_CAPPED_IMPLEMENTATION"), vm.envBytes32("SGLD_CAPPED_RUNTIME_HASH")
        );
    }

    /// @notice Explicit inputs avoid process-environment races in concurrent fork rehearsals.
    function runWithVerifiedImplementation(address expected, bytes32 expectedHash)
        public
        returns (GoldSettlementOracle oracle, BaseGoldController controller)
    {
        _baseChecks();
        require(expected != address(0) && expectedHash != bytes32(0), "Verified cap inputs required");
        require(
            _implementation(ASSET) == expected && expected.codehash == expectedHash, "Cap implementation/hash mismatch"
        );
        require(
            SGLDTokenCapped(ASSET).MAX_CANONICAL_SUPPLY() > 0 && SGLDTokenCapped(ASSET).globalSupplyCapInitialized(),
            "Cap not initialized"
        );
        require(
            SGLDTokenCapped(ASSET).totalSupply() <= SGLDTokenCapped(ASSET).MAX_CANONICAL_SUPPLY(),
            "Supply above current cap"
        );
        _feedIdentity(GOLD_FEED, "XAU / USD");
        vm.startBroadcast(DEPLOYER);
        oracle = new GoldSettlementOracle(GOLD_FEED, 1 days);
        controller = new BaseGoldController(BASE_ENDPOINT, ADMIN, 30184, 30416, ASSET, address(oracle));
        vm.stopBroadcast();
        require(controller.owner() == ADMIN && controller.paused(), "Owner/pause mismatch");
        require(controller.peers(30416) == bytes32(0), "Unexpected peer");
        require(controller.exposureCapacity() == 0 && controller.backingLiability() == 0, "Unexpected exposure");
        require(
            !SGLDTokenCapped(ASSET).hasRole(SGLDTokenCapped(ASSET).MINTER_ROLE(), address(controller)),
            "Unexpected minter grant"
        );
        console2.log("Base oracle", address(oracle));
        console2.log("Base controller (paused, no minter/peer/limits)", address(controller));
    }
}
