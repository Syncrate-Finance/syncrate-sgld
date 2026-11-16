// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SGLDToken} from "./SGLDToken.sol";

/// @notice Development upgrade for the existing Base canonical proxy. Not a remote token.
/// @dev Adds no storage. Existing namespaced OZ state and inheritance order are unchanged.
///      Version 5 follows the legacy ticker reinitializer (version 4).
contract SGLDTokenCapped is SGLDToken {
    uint256 public constant MAX_CANONICAL_SUPPLY = 193e18;

    error SupplyCapNotInitialized();
    error CanonicalSupplyCapExceeded(uint256 supply, uint256 requested, uint256 cap);

    event GlobalSupplyCapInitialized(uint256 cap);

    /// @notice Intended for an admin-authorized, atomic upgradeToAndCall.
    /// @dev Refuses an already over-cap ledger; never alters holder balances to fit the cap.
    function initializeGlobalSupplyCap() external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(5) {
        uint256 supply = totalSupply();
        if (supply > MAX_CANONICAL_SUPPLY) {
            revert CanonicalSupplyCapExceeded(supply, 0, MAX_CANONICAL_SUPPLY);
        }
        emit GlobalSupplyCapInitialized(MAX_CANONICAL_SUPPLY);
    }

    function globalSupplyCapInitialized() public view returns (bool) {
        return _getInitializedVersion() >= 5;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            if (!globalSupplyCapInitialized()) revert SupplyCapNotInitialized();
            uint256 supply = totalSupply();
            if (supply > MAX_CANONICAL_SUPPLY || value > MAX_CANONICAL_SUPPLY - supply) {
                revert CanonicalSupplyCapExceeded(supply, value, MAX_CANONICAL_SUPPLY);
            }
        }
        super._update(from, to, value);
    }
}
