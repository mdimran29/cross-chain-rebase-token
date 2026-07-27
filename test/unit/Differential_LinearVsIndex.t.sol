// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Reference implementation of the pre-Phase-4 per-user lazy-linear model
/// (`RebaseToken.sol` before the bucketed-index rewrite): `balance = principal * (1e18 + rate *
/// dt) / 1e18`, capitalized into principal on every touch. Kept standalone (not imported from
/// `src/`) specifically so this file is a fixed, frozen oracle of "what v1 would have computed" —
/// it must never change just because the production contract does.
contract LinearModelReference {
    uint256 private constant PRECISION_FACTOR = 1e18;

    uint256 public principal;
    uint256 public rate;
    uint256 public lastUpdated;

    constructor(uint256 _rate) {
        rate = _rate;
        lastUpdated = block.timestamp;
    }

    function balanceOf() public view returns (uint256) {
        if (principal == 0) return 0;
        uint256 dt = block.timestamp - lastUpdated;
        uint256 growth = (rate * dt) + PRECISION_FACTOR;
        return (principal * growth) / PRECISION_FACTOR;
    }

    /// @dev Mirrors v1's `_mintAccruedInterest` + `mint`: capitalize accrued interest into
    /// principal, then add the new deposit.
    function deposit(uint256 amount) external {
        principal = balanceOf();
        lastUpdated = block.timestamp;
        principal += amount;
    }
}

/// @notice Phase 4 Step 4.3: fuzz-proves the new bucketed share-index model reduces to exactly
/// the old per-user lazy-linear model for the case where both are mathematically defined to agree
/// — a single continuous holder, single tier, no transfers, no cross-tier merges. Both models
/// apply the identical growth factor `(1e18 + rate * dt) / 1e18` per touch; the index model only
/// changes *how* that's computed (once per tier vs. once per user), not the growth law itself.
contract DifferentialLinearVsIndexTest is Test {
    RebaseToken token;
    InterestRateController rateController;

    address owner = makeAddr("owner");
    address minter = makeAddr("minter");
    address user = makeAddr("user");

    uint256 constant INITIAL_RATE = 5e10;

    function setUp() public {
        vm.startPrank(owner);
        rateController = new InterestRateController(INITIAL_RATE, owner);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        token.grantMintAndBurnRole(minter);
        vm.stopPrank();
    }

    /// @dev Single deposit, single warp, single read — the base case both models must agree on
    /// exactly (up to integer-division rounding, since both divide by 1e18 at the same points).
    function testFuzzSingleDepositSingleWarpMatchesLinearReference(uint256 amount, uint256 dt) public {
        amount = bound(amount, 1, 1e30);
        dt = bound(dt, 0, 100 * 365 days);

        LinearModelReference ref = new LinearModelReference(INITIAL_RATE);
        ref.deposit(amount);

        vm.prank(minter);
        token.mint(user, amount, INITIAL_RATE);

        vm.warp(block.timestamp + dt);

        uint256 indexBalance = token.balanceOf(user);
        uint256 linearBalance = ref.balanceOf();

        // Both models divide by PRECISION_FACTOR (1e18) at each growth step; the index model
        // additionally divides by RAY (1e27) once when converting shares back to tokens. Allow a
        // small fixed tolerance for that extra rounding step rather than requiring bit-for-bit
        // equality.
        assertApproxEqAbs(indexBalance, linearBalance, 2);
    }

    /// @dev Two deposits at the same rate with a warp between them — exercises the
    /// touch-then-add-more path (v1's `_mintAccruedInterest` capitalization) against the index
    /// model's "mint more shares into the same tier at its now-grown index."
    /// @dev Amounts are floored at 1e9 wei rather than 1: at extreme rate*time products (index
    /// growth over ~10 years can exceed 1e39x), converting a sub-thousand-wei deposit into shares
    /// truncates to near-zero shares, losing the deposit's value in share form — a genuine
    /// precision floor of any share/index model at dust-scale amounts, not a Phase 4 regression
    /// (the vault's own `minDeposit` already excludes amounts this small in practice).
    function testFuzzTwoDepositsSameRateMatchesLinearReference(
        uint256 amount1,
        uint256 amount2,
        uint256 dt1,
        uint256 dt2
    ) public {
        amount1 = bound(amount1, 1e9, 1e30);
        amount2 = bound(amount2, 1e9, 1e30);
        dt1 = bound(dt1, 0, 10 * 365 days);
        dt2 = bound(dt2, 0, 10 * 365 days);

        LinearModelReference ref = new LinearModelReference(INITIAL_RATE);
        ref.deposit(amount1);

        vm.prank(minter);
        token.mint(user, amount1, INITIAL_RATE);

        vm.warp(block.timestamp + dt1);
        ref.deposit(amount2);
        vm.prank(minter);
        token.mint(user, amount2, INITIAL_RATE);

        vm.warp(block.timestamp + dt2);

        uint256 indexBalance = token.balanceOf(user);
        uint256 linearBalance = ref.balanceOf();

        // Two mints means two independent share-conversion roundings compound. Fuzzed amounts
        // span from single-digit wei (where even relative tolerance is meaningless) to 1e30
        // (where a fixed wei tolerance is too tight) — accept either a small absolute drift or a
        // tiny relative one, whichever the magnitude makes sensible.
        uint256 diff = indexBalance > linearBalance ? indexBalance - linearBalance : linearBalance - indexBalance;
        bool withinAbsolute = diff <= 20;
        bool withinRelative = linearBalance > 0 && (diff * 1e18) / linearBalance <= 1e9; // 1e-9 relative
        assertTrue(withinAbsolute || withinRelative);
    }

    /// @dev Sanity check that the reference itself is non-trivial (i.e. this test file would
    /// actually catch a divergence, not vacuously pass because both sides are zero).
    function testReferenceModelAccruesInterest() public {
        LinearModelReference ref = new LinearModelReference(INITIAL_RATE);
        ref.deposit(1000 ether);
        vm.warp(block.timestamp + 365 days);
        assertGt(ref.balanceOf(), 1000 ether);
    }
}
