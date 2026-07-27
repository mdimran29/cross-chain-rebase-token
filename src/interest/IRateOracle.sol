// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface `InterestRateController` uses to pull an external yield benchmark.
/// Implementations are responsible for staleness/deviation checks; the controller additionally
/// enforces its own max-step-per-epoch clamp on whatever rate this returns (roadmap §5.8).
interface IRateOracle {
    /// @notice Returns the latest accepted benchmark rate, scaled the same way as
    /// `RebaseToken`'s per-second interest rate (1e18 precision, e.g. `5e10` ~ current default).
    /// @return rate The benchmark rate to feed into the controller's policy mapping.
    /// @return valid False if the latest round is stale or deviates beyond the oracle's own
    /// bound and the caller should hold the last-known-good rate instead of reverting — a bad
    /// print must never brick rate updates, only pause them.
    function latestRate() external view returns (uint256 rate, bool valid);

    /// @notice Advances the oracle's own deviation baseline to `rate`. Called by
    /// `InterestRateController` exactly once per round it actually accepts and applies — never
    /// for a rejected (stale/deviant) round — so the baseline only ever reflects rates that were
    /// really used. Implementations that don't track a baseline (e.g. a stateless test double)
    /// may leave this a no-op.
    function acceptRate(uint256 rate) external;
}
