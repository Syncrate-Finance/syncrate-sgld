// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SGLDToken} from "../../src/SGLDToken.sol";

interface IExistingGoldEngine {
    function sgldToken() external view returns (address);
    function totalReserved() external view returns (uint256);
}

interface IDeploymentFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

/// @notice Public, owner-selected deployment inputs. No key/password handling or signer configuration.
abstract contract GoldDeploymentProfile is Script {
    address public constant DEPLOYER = 0x9C8671eC3e032BbDb0A9B7577468763dc553DA40;
    address public constant ADMIN = DEPLOYER;
    address public constant TREASURY = 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69;
    address public constant ASSET = 0x10C5E0643bCc6C915Cad0335f70A96c1532766eb;
    address public constant ENGINE = 0x37c0078D297243A22ac247cd93f1cafed9Dbe461;
    address public constant GOLD_FEED = 0x5213eBB69743b85644dbB6E25cdF994aFBb8cF31;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address public constant BASE_ENDPOINT = address(bytes20(hex"1a44076050125825900e736c501f859c50fe728c"));
    address public constant ROBINHOOD_ENDPOINT = address(bytes20(hex"6f475642a6e85809b1c36fa62763669b1b48dd5b"));
    address public constant LEGACY_IMPLEMENTATION = 0x21D4dAf073A381631356513072dFD3A6372CCbE8;
    address public constant USDG_IMPLEMENTATION = address(bytes20(hex"68184c449e1a8f34fa18d289737129fd27b66f8f"));
    bytes32 public constant USDG_RUNTIME_HASH = 0x3a551ac5c744af57e68a1d1431ac403c0f516ffd7d224a75746aee11fc4f3baf;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _baseChecks() internal view {
        require(block.chainid == 8453, "Base mainnet required");
        require(ASSET.code.length != 0 && ENGINE.code.length != 0, "Missing Base asset/engine");
        require(IERC20Metadata(ASSET).decimals() == 18, "SGLD decimals mismatch");
        require(keccak256(bytes(IERC20Metadata(ASSET).symbol())) == keccak256("SGLD"), "SGLD identity mismatch");
        require(SGLDToken(ASSET).hasRole(bytes32(0), ADMIN), "Expected Base upgrade admin missing");
        require(IExistingGoldEngine(ENGINE).sgldToken() == ASSET, "Engine asset mismatch");
        require(IExistingGoldEngine(ENGINE).totalReserved() == 0, "Review legacy reservations first");
    }

    function _feedIdentity(address feed, string memory description) internal view {
        require(feed.code.length != 0, "Feed missing");
        require(IDeploymentFeed(feed).decimals() == 8, "Feed decimals changed");
        require(
            keccak256(bytes(IDeploymentFeed(feed).description())) == keccak256(bytes(description)),
            "Feed description mismatch"
        );
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
