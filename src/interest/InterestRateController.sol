// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {IRateOracle} from "./IRateOracle.sol";

/// @notice Externalizes rate policy out of `RebaseToken` (roadmap §5.8): the token stays a
/// simple accrual engine and asks this contract for "the rate a new depositor/tier gets right
/// now"; how that number is produced — a governance-set constant, a scheduled decay, or an
/// oracle-bounded band — lives entirely here and can evolve without touching the token.
/// @dev The "rate can only decrease" invariant that used to live in `RebaseToken.setInterestRate`
/// moves here unchanged — `currentRate()` is still monotonically non-increasing regardless of
/// which policy mode produced the candidate value, so the token's downstream tier logic keeps the
/// same safety property it always had.
contract InterestRateController is AccessControl {
    enum Mode {
        /// @notice Governance calls `setRate` directly; the only mode that existed pre-Phase-4.
        Static,
        /// @notice Rate steps down automatically by `decayStepPerPeriod` every `decayPeriod`,
        /// with no per-step governance action required — "predictable emissions" per §5.8.
        ScheduledDecay,
        /// @notice `currentRate()` is refreshed from `oracle.latestRate()`, clamped into
        /// [oracleFloor, oracleCap] and by `oracleMaxStepPerUpdate` per call to `pokeOracle()`.
        OracleBand
    }

    Mode public mode;

    uint256 private s_currentRate;

    // ---- ScheduledDecay policy ----
    uint256 public decayStepPerPeriod;
    uint256 public decayPeriod;
    uint256 public lastDecayAt;

    // ---- OracleBand policy ----
    IRateOracle public oracle;
    uint256 public oracleFloor;
    uint256 public oracleCap;
    uint256 public oracleMaxStepPerUpdate;

    event RateSet(uint256 previousRate, uint256 newRate, Mode mode);
    event ModeChanged(Mode previousMode, Mode newMode);
    event ScheduledDecayConfigured(uint256 stepPerPeriod, uint256 period);
    event OraclePolicyConfigured(address oracle, uint256 floor, uint256 cap, uint256 maxStepPerUpdate);
    event OraclePokeRejected(uint256 rawRate, bool oracleValid);

    constructor(uint256 initialRate, address admin) {
        s_currentRate = initialRate;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RATE_ADMIN_ROLE, admin);
        emit RateSet(0, initialRate, Mode.Static);
    }

    /// @notice The rate new deposits / bridge-ins / tier lookups should use right now.
    function currentRate() external view returns (uint256) {
        return s_currentRate;
    }

    /// @notice Directly sets the rate. Valid in any mode (an emergency/manual override is always
    /// available even under ScheduledDecay or OracleBand). Strictly decreasing — unlike the
    /// mechanical decay/oracle paths, an explicit governance call that doesn't actually move the
    /// rate is almost certainly a mistake, so (unlike `_applyRate`'s `>` used internally) this
    /// also rejects an unchanged rate, matching the pre-Phase-4 `setInterestRate` contract.
    function setRate(uint256 newRate) external onlyRole(Roles.RATE_ADMIN_ROLE) {
        if (newRate >= s_currentRate) {
            revert Errors.RebaseToken__InterestRateCanOnlyDecrease(s_currentRate, newRate);
        }
        _applyRate(newRate);
    }

    /// @notice Switches policy mode. Does not itself change the rate — the next
    /// `advanceScheduledDecay()` / `pokeOracle()` call will.
    function setMode(Mode newMode) external onlyRole(Roles.RATE_ADMIN_ROLE) {
        Mode previous = mode;
        mode = newMode;
        if (newMode == Mode.ScheduledDecay) {
            lastDecayAt = block.timestamp;
        }
        emit ModeChanged(previous, newMode);
    }

    /// @notice Configures the scheduled-decay policy: the rate falls by `stepPerPeriod` every
    /// `period` seconds once `advanceScheduledDecay()` is called after enough time has passed.
    function configureScheduledDecay(uint256 stepPerPeriod, uint256 period) external onlyRole(Roles.RATE_ADMIN_ROLE) {
        decayStepPerPeriod = stepPerPeriod;
        decayPeriod = period;
        emit ScheduledDecayConfigured(stepPerPeriod, period);
    }

    /// @notice Permissionless: applies as many elapsed decay periods as have accrued since the
    /// last call. Safe to be permissionless because the *mechanical* step is fully determined by
    /// governance-set `decayStepPerPeriod`/`decayPeriod` — calling it early or often cannot move
    /// the rate beyond what governance already authorized (§5.8: "mechanical update can be
    /// permissionless-but-bounded").
    function advanceScheduledDecay() external {
        if (mode != Mode.ScheduledDecay) return;
        if (decayPeriod == 0) return;
        uint256 elapsedPeriods = (block.timestamp - lastDecayAt) / decayPeriod;
        if (elapsedPeriods == 0) return;
        lastDecayAt += elapsedPeriods * decayPeriod;

        uint256 totalStep = elapsedPeriods * decayStepPerPeriod;
        uint256 candidate = totalStep >= s_currentRate ? 0 : s_currentRate - totalStep;
        _applyRate(candidate);
    }

    /// @notice Configures the oracle-band policy: `pokeOracle()` will map the feed's rate into
    /// [floor, cap], clamped to move by at most `maxStepPerUpdate` from the current rate.
    function configureOracleBand(address _oracle, uint256 floor, uint256 cap, uint256 maxStepPerUpdate)
        external
        onlyRole(Roles.RATE_ADMIN_ROLE)
    {
        if (floor > cap) revert Errors.RateController__InvalidBand(floor, cap);
        oracle = IRateOracle(_oracle);
        oracleFloor = floor;
        oracleCap = cap;
        oracleMaxStepPerUpdate = maxStepPerUpdate;
        emit OraclePolicyConfigured(_oracle, floor, cap, maxStepPerUpdate);
    }

    /// @notice Permissionless: pulls the oracle, and if the round is valid, maps it into the
    /// governed band with a max-step clamp and applies it (subject to the global only-decreases
    /// invariant). A stale or deviant round is a no-op — the last rate holds, never reverts.
    /// @dev Permissionless for the same "mechanical vs. policy" reason as `advanceScheduledDecay`:
    /// every bound (floor/cap/max-step) was already fixed by governance in `configureOracleBand`.
    function pokeOracle() external {
        if (mode != Mode.OracleBand) return;
        if (address(oracle) == address(0)) return;

        (uint256 rawRate, bool valid) = oracle.latestRate();
        if (!valid) {
            emit OraclePokeRejected(rawRate, valid);
            return;
        }

        uint256 banded = rawRate < oracleFloor ? oracleFloor : (rawRate > oracleCap ? oracleCap : rawRate);

        uint256 current = s_currentRate;
        uint256 clamped;
        if (banded >= current) {
            uint256 upStep = banded - current;
            clamped = upStep > oracleMaxStepPerUpdate ? current + oracleMaxStepPerUpdate : banded;
        } else {
            uint256 downStep = current - banded;
            clamped = downStep > oracleMaxStepPerUpdate ? current - oracleMaxStepPerUpdate : banded;
        }

        // Record this round as the new deviation baseline only once it has actually been
        // accepted and applied — a rejected/no-op round must not move the oracle's own baseline.
        oracle.acceptRate(rawRate);
        _applyRate(clamped);
    }

    function _applyRate(uint256 newRate) private {
        uint256 previous = s_currentRate;
        if (newRate > previous) {
            revert Errors.RebaseToken__InterestRateCanOnlyDecrease(previous, newRate);
        }
        s_currentRate = newRate;
        emit RateSet(previous, newRate, mode);
    }
}
