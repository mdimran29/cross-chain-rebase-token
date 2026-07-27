// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IRateOracle} from "./IRateOracle.sol";

/// @notice Adapts a Chainlink Data Feed (e.g. a staking-yield or benchmark-rate feed) into the
/// bounded `IRateOracle` shape `InterestRateController` consumes.
/// @dev Two independent fault lines, per roadmap §5.8: (1) staleness — the round is older than
/// `maxStaleness` since it was last updated; (2) deviation — the new reading moves more than
/// `maxDeviationBps` from the last accepted reading in one round. Either failure returns
/// `valid = false` rather than reverting, so a bad oracle print can never brick the controller —
/// it just holds the last-known-good rate until a sane round arrives.
contract ChainlinkRateOracle is IRateOracle {
    /// @notice The only account allowed to advance the deviation baseline — the controller that
    /// reads and acts on `latestRate()`. Prevents a third party from calling `acceptRate` with an
    /// arbitrary value to desynchronize the baseline from what was actually applied on-chain.
    address public immutable controller;

    AggregatorV3Interface public immutable feed;

    /// @notice Feed decimals, cached at construction (Chainlink feeds don't change this at runtime).
    uint8 public immutable feedDecimals;

    /// @notice Maximum age, in seconds, a round may have before it's treated as stale.
    uint256 public immutable maxStaleness;

    /// @notice Maximum allowed deviation of a new reading from the last accepted one, in basis
    /// points. Guards against a single bad round spiking the mapped rate.
    uint256 public immutable maxDeviationBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Last reading that passed both the staleness and deviation checks; the deviation
    /// bound is always measured against this, not against the raw previous round.
    uint256 private s_lastAcceptedRate;
    bool private s_hasAccepted;

    error NotController(address caller);

    /// @dev Seeds the deviation baseline from the feed's round at construction time — without
    /// this, `s_hasAccepted` would stay false until the controller's first `pokeOracle()`
    /// actually applies a round, letting an arbitrarily large first reading through unchecked
    /// (there'd be nothing yet to measure deviation against).
    constructor(address _feed, uint256 _maxStaleness, uint256 _maxDeviationBps, address _controller) {
        feed = AggregatorV3Interface(_feed);
        feedDecimals = AggregatorV3Interface(_feed).decimals();
        maxStaleness = _maxStaleness;
        maxDeviationBps = _maxDeviationBps;
        controller = _controller;

        (, int256 answer,,,) = AggregatorV3Interface(_feed).latestRoundData();
        if (answer > 0) {
            s_lastAcceptedRate = _scaleTo18(uint256(answer));
            s_hasAccepted = true;
        }
    }

    /// @inheritdoc IRateOracle
    /// @dev Rescales the feed's native decimals to 1e18 so the controller can compare it directly
    /// against `RebaseToken`'s per-second rate precision without knowing the feed's format.
    function latestRate() external view override returns (uint256 rate, bool valid) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        if (answer <= 0) {
            return (s_lastAcceptedRate, false);
        }
        if (block.timestamp > updatedAt + maxStaleness) {
            return (s_lastAcceptedRate, false);
        }

        uint256 scaled = _scaleTo18(uint256(answer));

        if (s_hasAccepted) {
            uint256 last = s_lastAcceptedRate;
            uint256 diff = scaled > last ? scaled - last : last - scaled;
            // last == 0 would make any nonzero reading an infinite deviation; treat that as
            // "no prior baseline to deviate from" and accept, same as the first-ever round.
            if (last != 0 && (diff * BPS_DENOMINATOR) / last > maxDeviationBps) {
                return (s_lastAcceptedRate, false);
            }
        }

        return (scaled, true);
    }

    /// @notice Records the rate returned by `latestRate()` as the new deviation baseline.
    /// @dev Split from `latestRate()` (a view) because accepting a round is a state change;
    /// `InterestRateController` calls this only after it has itself decided to apply the round.
    function acceptRate(uint256 rate) external override {
        if (msg.sender != controller) revert NotController(msg.sender);
        s_lastAcceptedRate = rate;
        s_hasAccepted = true;
    }

    function _scaleTo18(uint256 amount) private view returns (uint256) {
        if (feedDecimals == 18) return amount;
        if (feedDecimals < 18) return amount * (10 ** (18 - feedDecimals));
        return amount / (10 ** (feedDecimals - 18));
    }
}
