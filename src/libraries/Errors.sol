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
    error Vault__DepositBelowMinimum(uint256 amount, uint256 minimum);
    error Vault__DepositExceedsPerTxCap(uint256 amount, uint256 cap);
    error Vault__DepositExceedsAddressCap(uint256 newTotal, uint256 cap);
    error Vault__DepositExceedsTvlCap(uint256 newTvl, uint256 cap);
    error Vault__DailyNetFlowLimitExceeded(uint256 netOutflow, uint256 limit);
    error Vault__FeeExceedsCap(uint256 bps, uint256 cap);
    error Vault__FeeTransferFailed();
    error Vault__NotQueue(address caller);
    error Vault__QueueAlreadySet();
    error Vault__CannotRescueProtocolAsset();
    error Vault__DepositsBlockedDuringRecovery();

    // ---- Treasury ----
    error Treasury__InsufficientReserve(uint256 requested, uint256 available);
    error Treasury__TransferFailed();
    error Treasury__FeeBucketNotFundable();

    // ---- WithdrawalQueue ----
    error Queue__NotVault(address caller);
    error Queue__InvalidStatus();
    error Queue__InsufficientLiquidity(uint256 requested, uint256 available);
    error Queue__NotRequestOwner(address caller, address owner);

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
    error CircuitBreaker__AlreadyTripped();

    // ---- InterestRateController ----
    error RateController__InvalidBand(uint256 floor, uint256 cap);

    // ---- RebaseToken v2 (index model) ----
    error RebaseToken__TierCapExceeded(uint256 cap);
    error RebaseToken__RateOverflow(uint256 rate);
}
