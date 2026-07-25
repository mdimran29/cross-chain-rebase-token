// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../libraries/Errors.sol";

interface IVaultForQueue {
    function freeLiquidity() external view returns (uint256);
    function disburse(address to, uint256 amount) external;
    function restoreFromQueue(address user, uint256 amount, uint256 userRate) external;
}

/// @notice Pull-based withdrawal queue for redemptions the Vault can't serve instantly out of
/// free liquidity. Vault always custodies the ETH; this contract only tracks request state and
/// asks Vault to move funds — so a griefing/DoS attempt against the queue can never block the
/// Vault's other flows, and paying out is always a per-user pull, never a batch/loop (roadmap
/// §3.11: pull-over-push, no unbounded iteration over payouts).
contract WithdrawalQueue {
    enum Status {
        None,
        Requested,
        Claimable,
        Paid,
        Cancelled
    }

    struct WithdrawalRequest {
        address user;
        uint256 amount;
        uint256 userRateSnapshot;
        uint256 requestTime;
        Status status;
    }

    IVaultForQueue public immutable i_vault;

    uint256 private s_nextRequestId = 1;
    mapping(uint256 => WithdrawalRequest) private s_requests;

    /// @notice Sum of amounts across Claimable requests only — ETH the Vault has *guaranteed* to
    /// a specific claimant, so `Vault.freeLiquidity()` must exclude it from what a new
    /// redemption or promotion can draw against. Merely-Requested (not yet promoted) amounts are
    /// deliberately excluded: including them here would make `markClaimable` require double the
    /// ETH actually needed (once to satisfy the free-liquidity check, again because the request
    /// itself was already counted against that same balance).
    uint256 public totalPendingClaims;

    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 amount);
    event WithdrawalMadeClaimable(uint256 indexed requestId);
    event WithdrawalClaimed(uint256 indexed requestId, address indexed user, uint256 amount);
    event WithdrawalCancelled(uint256 indexed requestId, address indexed user, uint256 amount);

    modifier onlyVault() {
        if (msg.sender != address(i_vault)) revert Errors.Queue__NotVault(msg.sender);
        _;
    }

    constructor(address _vault) {
        i_vault = IVaultForQueue(_vault);
    }

    /// @notice Enqueues a redemption the Vault couldn't serve instantly. `userRateSnapshot` lets
    /// `cancel` restore the user's exact prior entitlement rather than whatever the global rate
    /// has drifted to while queued.
    function requestRedeem(address user, uint256 amount, uint256 userRateSnapshot)
        external
        onlyVault
        returns (uint256 requestId)
    {
        requestId = s_nextRequestId++;
        s_requests[requestId] = WithdrawalRequest({
            user: user,
            amount: amount,
            userRateSnapshot: userRateSnapshot,
            requestTime: block.timestamp,
            status: Status.Requested
        });
        emit WithdrawalRequested(requestId, user, amount);
    }

    /// @notice Flips a request to Claimable once the Vault has enough free liquidity to cover
    /// it, reserving that liquidity against `totalPendingClaims`. Permissionless: it only changes
    /// bookkeeping state and never moves funds, so anyone (the user, a keeper, or Vault itself)
    /// can trigger it as soon as liquidity recovers.
    function markClaimable(uint256 requestId) external {
        WithdrawalRequest storage req = s_requests[requestId];
        if (req.status != Status.Requested) revert Errors.Queue__InvalidStatus();
        uint256 free = i_vault.freeLiquidity();
        if (free < req.amount) revert Errors.Queue__InsufficientLiquidity(req.amount, free);
        req.status = Status.Claimable;
        totalPendingClaims += req.amount;
        emit WithdrawalMadeClaimable(requestId);
    }

    /// @notice Pays out a Claimable request. Only the original requester can claim — pull-based,
    /// never pushed by a keeper or batch job.
    function claim(uint256 requestId) external {
        WithdrawalRequest storage req = s_requests[requestId];
        if (msg.sender != req.user) revert Errors.Queue__NotRequestOwner(msg.sender, req.user);
        if (req.status != Status.Claimable) revert Errors.Queue__InvalidStatus();
        req.status = Status.Paid;
        totalPendingClaims -= req.amount;
        emit WithdrawalClaimed(requestId, req.user, req.amount);
        i_vault.disburse(req.user, req.amount);
    }

    /// @notice Cancels a still-pending request and restores the user's RBT at their original
    /// rate, as if the redemption never happened.
    function cancel(uint256 requestId) external {
        WithdrawalRequest storage req = s_requests[requestId];
        if (msg.sender != req.user) revert Errors.Queue__NotRequestOwner(msg.sender, req.user);
        if (req.status != Status.Requested && req.status != Status.Claimable) revert Errors.Queue__InvalidStatus();
        // Only a Claimable request had reserved liquidity against totalPendingClaims; a
        // Requested one never did (see markClaimable's NatSpec).
        if (req.status == Status.Claimable) {
            totalPendingClaims -= req.amount;
        }
        req.status = Status.Cancelled;
        emit WithdrawalCancelled(requestId, req.user, req.amount);
        i_vault.restoreFromQueue(req.user, req.amount, req.userRateSnapshot);
    }

    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return s_requests[requestId];
    }
}
