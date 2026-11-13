// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SGLDStaking} from "../src/SGLDStaking.sol";

interface IDeploymentEngine {
    function sgldToken() external view returns (address);
    function FEE_RECIPIENT() external view returns (address);
}

/// @notice One paused Base mainnet deployment. Dry-run unless the operator explicitly supplies --broadcast.
/// @dev No private key or keystore password is read by this script; use Foundry --account locally.
contract DeploySGLDStaking is Script {
    address public constant ASSET = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;
    address public constant ENGINE = 0x37c0078D297243A22ac247cd93f1cafed9Dbe461;
    address public constant OWNER = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
    address public constant TREASURY = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;

    function run() external returns (SGLDStaking deployed) {
        require(block.chainid == 8453, "Deployment must use Base mainnet RPC");
        require(ASSET.code.length != 0 && ENGINE.code.length != 0, "Missing Base contracts");
        require(IERC20Metadata(ASSET).decimals() == 18, "Unexpected SGLD decimals");
        require(keccak256(bytes(IERC20Metadata(ASSET).symbol())) == keccak256("SGLD"), "Unexpected token");
        require(IDeploymentEngine(ENGINE).sgldToken() == ASSET, "Engine asset mismatch");
        require(IDeploymentEngine(ENGINE).FEE_RECIPIENT() == TREASURY, "Treasury mismatch");
        console2.log("Chain", block.chainid);
        console2.log("SGLD", ASSET);
        console2.log("Deployer / admin / funder / pauser", OWNER);
        console2.log("Fee recipient", TREASURY);
        vm.startBroadcast(OWNER);
        deployed = new SGLDStaking(ASSET, OWNER, OWNER, OWNER);
        vm.stopBroadcast();
        require(deployed.paused(), "Deployment must start paused");
        require(deployed.defaultAdmin() == OWNER, "Admin mismatch");
        require(deployed.hasRole(deployed.FUNDER_ROLE(), OWNER), "Funder mismatch");
        require(deployed.hasRole(deployed.PAUSER_ROLE(), OWNER), "Pauser mismatch");
        require(address(deployed.sgld()) == ASSET && deployed.FEE_RECIPIENT() == TREASURY, "Asset/fee mismatch");
        require(deployed.DEPOSIT_FEE_BPS() == 25 && deployed.REDEMPTION_FEE_BPS() == 50, "Fee mismatch");
        require(
            deployed.totalSupply() == 0 && deployed.totalPrincipal() == 0 && deployed.rewardReserve() == 0,
            "Nonempty vault"
        );
        console2.log("Staking vault and sySGLD token", address(deployed));
        console2.log("Deposits remain PAUSED. No unpause or funding transaction is included.");
    }
}
