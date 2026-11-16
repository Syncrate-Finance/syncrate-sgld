// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SGLDToken} from "./SGLDToken.sol";

/// @notice Canonical inventory cap. Treasury/admin must verify new bullion before increasing it.
/// @dev Replaces the deployed version-5 fixed cap. Existing inherited storage layout is unchanged.
contract SGLDTokenAdjustableCap is SGLDToken {
    /// @custom:storage-location erc7201:syncrate.storage.InventoryCap
    struct InventoryCapStorage {
        uint256 limit;
    }

    // keccak256(abi.encode(uint256(keccak256("syncrate.storage.InventoryCap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INVENTORY_CAP_SLOT = bytes32(
        uint256(keccak256(abi.encode(uint256(keccak256("syncrate.storage.InventoryCap")) - 1))) & ~uint256(0xff)
    );

    error SupplyCapNotInitialized();
    error InvalidCapIncrease();
    error CanonicalSupplyCapExceeded(uint256 supply, uint256 requested, uint256 cap);
    event GlobalSupplyCapInitialized(uint256 cap);
    event GlobalSupplyCapIncreased(uint256 previousCap, uint256 newCap);

    function _inventory() private pure returns (InventoryCapStorage storage state) {
        bytes32 slot = INVENTORY_CAP_SLOT;
        assembly { state.slot := slot }
    }

    /// @notice Atomically migrate the deployed fixed-193 cap to adjustable inventory accounting.
    function initializeAdjustableSupplyCap() external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(6) {
        uint256 supply = totalSupply();
        if (supply > 193e18) revert CanonicalSupplyCapExceeded(supply, 0, 193e18);
        _inventory().limit = 193e18;
        emit GlobalSupplyCapInitialized(193e18);
    }

    /// @notice Retains the existing integration selector, but returns the current configured cap.
    function MAX_CANONICAL_SUPPLY() public view returns (uint256) {
        return _inventory().limit;
    }

    function globalSupplyCapInitialized() public view returns (bool) {
        return _getInitializedVersion() >= 6 && _inventory().limit != 0;
    }

    /// @notice Increase only after verifying additional backing; does not mint any tokens.
    function increaseGlobalSupplyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!globalSupplyCapInitialized()) revert SupplyCapNotInitialized();
        uint256 previous = _inventory().limit;
        if (newCap <= previous) revert InvalidCapIncrease();
        _inventory().limit = newCap;
        emit GlobalSupplyCapIncreased(previous, newCap);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            if (!globalSupplyCapInitialized()) revert SupplyCapNotInitialized();
            uint256 cap = MAX_CANONICAL_SUPPLY();
            uint256 supply = totalSupply();
            if (supply > cap || value > cap - supply) revert CanonicalSupplyCapExceeded(supply, value, cap);
        }
        super._update(from, to, value);
    }
}
