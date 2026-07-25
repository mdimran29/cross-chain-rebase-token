// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Custodies protocol revenue separately from the reserve that backs yield, per Phase 2
/// (Vault Solvency & Fees). Three independent buckets so "money collected from users" (fees),
/// "money committed to backing yield" (reward reserve), and "money committed to covering losses"
/// (insurance reserve) can never be silently commingled or double-counted by Vault's backing math.
contract Treasury is AccessControl {
    enum Bucket {
        Fee,
        Reward,
        Insurance
    }

    uint256 public feeBalance;
    uint256 public rewardReserveBalance;
    uint256 public insuranceReserveBalance;

    event FeeReceived(address indexed from, uint256 amount);
    event ReserveFunded(Bucket indexed bucket, address indexed from, uint256 amount);
    event ReserveWithdrawn(Bucket indexed bucket, address indexed to, uint256 amount);
    event StrategyLoss(uint256 amount);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Plain ETH transfers (e.g. Vault routing a deposit/withdrawal fee) land in the fee
    /// bucket, distinct from the reserve buckets that back yield until governance explicitly
    /// moves funds via `fundReserve`.
    receive() external payable {
        feeBalance += msg.value;
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice Moves ETH into the reward or insurance reserve. Callable by anyone (governance,
    /// a revenue-sharing strategy, or a benefactor) — funding backing is never something to gate.
    function fundReserve(Bucket bucket) external payable {
        if (bucket == Bucket.Reward) {
            rewardReserveBalance += msg.value;
        } else if (bucket == Bucket.Insurance) {
            insuranceReserveBalance += msg.value;
        } else {
            revert Errors.Treasury__FeeBucketNotFundable();
        }
        emit ReserveFunded(bucket, msg.sender, msg.value);
    }

    /// @notice Withdraws from a named bucket. Timelock-gated in production (currently
    /// `TREASURER_ROLE`, matching this repo's Phase 0/1 admin model).
    function withdrawReserve(Bucket bucket, address payable to, uint256 amount)
        external
        onlyRole(Roles.TREASURER_ROLE)
    {
        if (bucket == Bucket.Fee) {
            if (amount > feeBalance) {
                revert Errors.Treasury__InsufficientReserve(amount, feeBalance);
            }
            feeBalance -= amount;
        } else if (bucket == Bucket.Reward) {
            if (amount > rewardReserveBalance) {
                revert Errors.Treasury__InsufficientReserve(amount, rewardReserveBalance);
            }
            rewardReserveBalance -= amount;
        } else {
            if (amount > insuranceReserveBalance) {
                revert Errors.Treasury__InsufficientReserve(amount, insuranceReserveBalance);
            }
            insuranceReserveBalance -= amount;
        }
        (bool success,) = to.call{value: amount}("");
        if (!success) revert Errors.Treasury__TransferFailed();
        emit ReserveWithdrawn(bucket, to, amount);
    }

    /// @notice Records a realized loss absorbed by the insurance reserve (bookkeeping only — any
    /// ETH transfer to make a counterparty whole is a separate `withdrawReserve` call).
    function absorbLoss(uint256 amount) external onlyRole(Roles.TREASURER_ROLE) {
        if (amount > insuranceReserveBalance) {
            revert Errors.Treasury__InsufficientReserve(amount, insuranceReserveBalance);
        }
        insuranceReserveBalance -= amount;
        emit StrategyLoss(amount);
    }

    /// @notice ETH actually committed to backing yield — i.e. excludes uncommitted fee revenue,
    /// which only counts toward Vault's solvency once explicitly moved into a reserve bucket.
    function reserveBalance() external view returns (uint256) {
        return rewardReserveBalance + insuranceReserveBalance;
    }
}
