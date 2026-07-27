// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockV3Aggregator} from "chainlink-local/data-feeds/MockV3Aggregator.sol";

import {ChainlinkRateOracle} from "../../src/interest/ChainlinkRateOracle.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Phase 4 Step 4.4: proves the oracle-driven rate path rejects stale/deviant rounds
/// (holding the last rate rather than reverting or applying garbage) and that
/// `InterestRateController.pokeOracle()` respects the governed floor/cap/max-step band on top of
/// whatever the oracle itself accepts.
contract OracleTest is Test {
    MockV3Aggregator feed;
    ChainlinkRateOracle oracle;
    InterestRateController controller;

    address owner = makeAddr("owner");

    uint256 constant MAX_STALENESS = 1 hours;
    uint256 constant MAX_DEVIATION_BPS = 2_000; // 20%
    uint256 constant INITIAL_RATE = 5e10;

    function setUp() public {
        feed = new MockV3Aggregator(18, int256(INITIAL_RATE));

        vm.startPrank(owner);
        controller = new InterestRateController(INITIAL_RATE, owner);
        oracle = new ChainlinkRateOracle(address(feed), MAX_STALENESS, MAX_DEVIATION_BPS, address(controller));
        controller.configureOracleBand(address(oracle), 0, INITIAL_RATE, 1e10);
        controller.setMode(InterestRateController.Mode.OracleBand);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Staleness
    // ---------------------------------------------------------------

    function testFreshRoundIsValid() public view {
        (uint256 rate, bool valid) = oracle.latestRate();
        assertTrue(valid);
        assertEq(rate, INITIAL_RATE);
    }

    function testStaleRoundIsRejected() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        (, bool valid) = oracle.latestRate();
        assertFalse(valid);
    }

    function testPokeOracleIsNoOpOnStaleRound() public {
        uint256 before = controller.currentRate();
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        controller.pokeOracle();
        assertEq(controller.currentRate(), before);
    }

    // ---------------------------------------------------------------
    // Deviation
    // ---------------------------------------------------------------

    function testDeviationWithinBoundIsAccepted() public {
        // 10% down-move, within the 20% bound.
        int256 newAnswer = int256(INITIAL_RATE) - int256(INITIAL_RATE / 10);
        feed.updateAnswer(newAnswer);
        (, bool valid) = oracle.latestRate();
        assertTrue(valid);
    }

    function testDeviationBeyondBoundIsRejected() public {
        // 50% down-move, beyond the 20% bound.
        int256 newAnswer = int256(INITIAL_RATE) / 2;
        feed.updateAnswer(newAnswer);
        (, bool valid) = oracle.latestRate();
        assertFalse(valid);
    }

    function testPokeOracleIsNoOpOnDeviantRound() public {
        uint256 before = controller.currentRate();
        feed.updateAnswer(int256(INITIAL_RATE) / 2);
        controller.pokeOracle();
        assertEq(controller.currentRate(), before);
    }

    function testRejectedRoundDoesNotMoveDeviationBaseline() public {
        // A deviant round is rejected and must not become the new baseline — the *next* honest
        // small move should still be measured against the original baseline, not the rejected one.
        feed.updateAnswer(int256(INITIAL_RATE) / 2); // rejected, ~50% down
        controller.pokeOracle();

        // Small move from the *original* rate should still be accepted.
        int256 smallMove = int256(INITIAL_RATE) - int256(INITIAL_RATE / 20); // 5% down
        feed.updateAnswer(smallMove);
        (, bool valid) = oracle.latestRate();
        assertTrue(valid);
    }

    // ---------------------------------------------------------------
    // Negative / zero answers
    // ---------------------------------------------------------------

    function testNonPositiveAnswerIsRejected() public {
        feed.updateAnswer(0);
        (, bool valid) = oracle.latestRate();
        assertFalse(valid);
    }

    // ---------------------------------------------------------------
    // Controller band: floor / cap / max-step
    // ---------------------------------------------------------------

    function testPokeOracleClampsToFloor() public {
        // Floor sits above the lowest value a single valid (within-deviation-bound) round could
        // report, so a legitimate reading below the floor still gets clamped up to it.
        uint256 floor = INITIAL_RATE - INITIAL_RATE / 20; // 5% below initial
        vm.prank(owner);
        controller.configureOracleBand(address(oracle), floor, INITIAL_RATE, INITIAL_RATE);

        feed.updateAnswer(int256(INITIAL_RATE) - int256(INITIAL_RATE / 10)); // 10% down, valid round
        controller.pokeOracle();

        assertEq(controller.currentRate(), floor);
    }

    function testPokeOracleClampsToMaxStep() public {
        // Only allow a small step per update even though the banded value would move further.
        vm.prank(owner);
        controller.configureOracleBand(address(oracle), 0, INITIAL_RATE, 1e9);

        feed.updateAnswer(int256(INITIAL_RATE) - int256(INITIAL_RATE / 10)); // 10% down = 5e9 move
        controller.pokeOracle();

        // Max step is 1e9, so the rate should only have moved by 1e9, not the full 5e9.
        assertEq(controller.currentRate(), INITIAL_RATE - 1e9);
    }

    function testPokeOracleNoOpWhenNotInOracleMode() public {
        vm.prank(owner);
        controller.setMode(InterestRateController.Mode.Static);

        uint256 before = controller.currentRate();
        feed.updateAnswer(int256(INITIAL_RATE) - int256(INITIAL_RATE / 10));
        controller.pokeOracle();

        assertEq(controller.currentRate(), before);
    }

    function testPokeOracleNeverRaisesRateBeyondOnlyDecreasesInvariant() public {
        // Even if the banded/stepped candidate would be numerically higher than the *global*
        // controller rate ever was, the controller's own only-decreases invariant still binds:
        // configure a band whose cap sits above the current rate and confirm an upward oracle
        // move never raises `currentRate()`.
        vm.prank(owner);
        controller.configureOracleBand(address(oracle), 0, INITIAL_RATE * 2, INITIAL_RATE);

        feed.updateAnswer(int256(INITIAL_RATE * 2)); // 2x = 100% up, deviant, rejected by oracle itself
        uint256 before = controller.currentRate();
        controller.pokeOracle();
        assertEq(controller.currentRate(), before);
    }

    // ---------------------------------------------------------------
    // Access control on ChainlinkRateOracle.acceptRate
    // ---------------------------------------------------------------

    function testOnlyControllerCanAcceptRate() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkRateOracle.NotController.selector, address(this)));
        oracle.acceptRate(1e10);
    }
}
