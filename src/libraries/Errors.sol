// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Central catalog of custom errors shared across the protocol, so the same
/// failure condition always reverts with the same error regardless of which contract raises it.
library Errors {
    // ---- Admin handover ----
    error NotPendingAdmin(address caller, address pendingAdmin);
    error NoPendingAdminTransfer();

    // ---- Vault ----
    error Vault__RedeemFailed();
    error Vault__DepositsPaused();
    error Vault__RedemptionsPaused();

    // ---- RebaseToken ----
    error RebaseToken__InterestRateCanOnlyDecrease(uint256 currentInterestRate, uint256 newInterestRate);

    // ---- RebaseTokenPool / bridge ----
    error Pool__BridgeOutPaused();
    error Pool__BridgeInPaused();
    error Pool__UnsupportedVersion(uint16 version);
    error Pool__PayloadHashMismatch(bytes32 expected, bytes32 actual);
    error Pool__MessageAlreadyExecuted(bytes32 messageId);
    error Pool__InterestRateOverflow(uint256 rate);

    // ---- CircuitBreaker ----
    error CircuitBreaker__StillTripped(uint256 cooldownEndsAt);
    error CircuitBreaker__NotTripped();
}
