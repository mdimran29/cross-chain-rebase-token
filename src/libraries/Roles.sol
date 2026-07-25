// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Central catalog of AccessControl role identifiers shared across the protocol.
/// @dev Every contract should import role constants from here instead of redeclaring them,
/// so the same role name always hashes to the same identifier everywhere it's checked.
library Roles {
    // Existing role — hash preserved from the original RebaseToken deployment.
    bytes32 internal constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 internal constant RATE_ADMIN_ROLE = keccak256("RATE_ADMIN_ROLE");
    bytes32 internal constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 internal constant LANE_ADMIN_ROLE = keccak256("LANE_ADMIN_ROLE");
    bytes32 internal constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // Held by the CircuitBreaker contract, so its automated trip call carries no more
    // authority than "pause" — never mint/burn/rate/fund power.
    bytes32 internal constant BREAKER_ROLE = keccak256("BREAKER_ROLE");
}
