// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Errors} from "../libraries/Errors.sol";
import {Roles} from "../libraries/Roles.sol";

interface IBreakerPausable {
    function pauseBridgeOut() external;
    function pauseBridgeIn() external;
}

/// @notice Aggregate, protocol-level anomaly halt — independent of the per-lane CCIP rate
/// limiter already enforced by `TokenPool`. CCIP limits throughput per lane; this watches net
/// velocity across all lanes and auto-pauses the pool the same way a human Guardian would.
/// @dev The breaker only ever *pauses* — it holds `Roles.BREAKER_ROLE` on the pool, which grants
/// strictly the same authority as `PAUSER_ROLE`, never mint/burn/fee/rate power. This mirrors the
/// "subtractive only" design of the Guardian council (roadmap §3.2, §7.3).
contract CircuitBreaker is AccessControl {
    /// @notice Length of the rolling window used to bucket inflow/outflow.
    uint256 public immutable windowDuration;
    /// @notice Net value (in token units) that may move through the pool within `windowDuration`
    /// before the breaker trips.
    uint256 public immutable velocityThreshold;
    /// @notice Minimum time after a trip before governance may reset the breaker, so a trip can't
    /// be immediately undone while the anomaly that caused it is still unfolding.
    uint256 public immutable resetCooldown;

    address public immutable pool;

    // Single time bucket rolled forward as time passes, rather than one counter per historical
    // window slot — bounded storage regardless of how long the protocol runs.
    uint256 private s_bucketStart;
    uint256 private s_inflow;
    uint256 private s_outflow;

    bool public tripped;
    uint256 public trippedAt;

    event FlowRecorded(uint256 inflow, uint256 outflow, uint256 windowInflow, uint256 windowOutflow);
    event BreakerTripped(uint256 windowInflow, uint256 windowOutflow, uint256 threshold);
    event BreakerReset(address indexed by);

    error NotPool(address caller);

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool(msg.sender);
        _;
    }

    constructor(address _pool, uint256 _windowDuration, uint256 _velocityThreshold, uint256 _resetCooldown) {
        pool = _pool;
        windowDuration = _windowDuration;
        velocityThreshold = _velocityThreshold;
        resetCooldown = _resetCooldown;
        s_bucketStart = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Records inbound/outbound flow and trips the pool's pause if net velocity in the
    /// current rolling window exceeds `velocityThreshold`. Called by the pool on every
    /// `lockOrBurn` (outflow) / `releaseOrMint` (inflow).
    /// @dev Rolls the bucket forward (resetting counters) once `windowDuration` has elapsed,
    /// rather than storing one entry per historical window — keeps storage bounded.
    function checkAndRecord(uint256 inflow, uint256 outflow) external onlyPool {
        if (block.timestamp >= s_bucketStart + windowDuration) {
            s_bucketStart = block.timestamp;
            s_inflow = 0;
            s_outflow = 0;
        }
        s_inflow += inflow;
        s_outflow += outflow;

        emit FlowRecorded(inflow, outflow, s_inflow, s_outflow);

        if (!tripped) {
            uint256 netVelocity = s_inflow > s_outflow ? s_inflow - s_outflow : s_outflow - s_inflow;
            if (netVelocity > velocityThreshold) {
                _trip();
            }
        }
    }

    /// @notice Lets the Emergency Council force a trip without waiting on velocity monitoring —
    /// "breaker-trip rights" per the Phase 3 governance split (roadmap §7.3): the Council can
    /// only ever pause faster, never move funds or change parameters, so this is granted the same
    /// `PAUSER_ROLE` the Council already holds directly on the protected contracts.
    function tripManually() external onlyRole(Roles.PAUSER_ROLE) {
        if (tripped) revert Errors.CircuitBreaker__AlreadyTripped();
        _trip();
    }

    function _trip() internal {
        tripped = true;
        trippedAt = block.timestamp;
        emit BreakerTripped(s_inflow, s_outflow, velocityThreshold);
        IBreakerPausable(pool).pauseBridgeOut();
        IBreakerPausable(pool).pauseBridgeIn();
    }

    /// @notice Clears a trip. Governance-only and cooldown-gated so the breaker can't be spammed
    /// on/off during an ongoing incident — the pool itself still needs a separate unpause.
    function reset() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!tripped) revert Errors.CircuitBreaker__NotTripped();
        if (block.timestamp < trippedAt + resetCooldown) {
            revert Errors.CircuitBreaker__StillTripped(trippedAt + resetCooldown);
        }
        tripped = false;
        s_bucketStart = block.timestamp;
        s_inflow = 0;
        s_outflow = 0;
        emit BreakerReset(msg.sender);
    }

    function currentWindow() external view returns (uint256 bucketStart, uint256 inflow, uint256 outflow) {
        return (s_bucketStart, s_inflow, s_outflow);
    }
}
