// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Phase 4 Step 4.3 migration requirement: "write a migration path that preserves
/// existing balances with no discontinuity (snapshot old balances -> seed shares at current
/// index)." This protocol has no live v1 deployment to migrate off of — Phase 4 replaces the
/// accrual internals in place — so this test proves the *mechanism* the roadmap describes would
/// be discontinuity-free: snapshot a set of pre-migration balances, mint each user's snapshot
/// amount at their snapshot rate into a fresh index-model token (exactly what a real migration
/// script would do per-user), and assert every migrated balance exactly equals its snapshot at
/// the instant of migration, then continues accruing correctly afterward with no jump or reset.
contract MigrationTest is Test {
    RebaseToken token;
    InterestRateController rateController;

    address owner = makeAddr("owner");
    address minter = makeAddr("minter");

    uint256 constant INITIAL_RATE = 5e10;

    /// @dev Stand-in for a snapshot pulled from a pre-Phase-4 deployment: each user's balance and
    /// locked-in rate at the migration cutover block.
    struct LegacySnapshot {
        address user;
        uint256 balance;
        uint256 rate;
    }

    function setUp() public {
        vm.startPrank(owner);
        rateController = new InterestRateController(INITIAL_RATE, owner);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        token.grantMintAndBurnRole(minter);
        token.grantRole(Roles.RATE_ADMIN_ROLE, owner);
        vm.stopPrank();
    }

    /// @dev Seeds `snapshot.balance` shares for `snapshot.user` at the tier matching
    /// `snapshot.rate`, exactly as `RebaseToken.mint` already does for any inbound value — a real
    /// migration script calls the same entrypoint per legacy holder, which is the point: no bespoke
    /// migration-only code path is needed, and thus no extra surface for a discontinuity bug.
    function _migrateUser(LegacySnapshot memory snapshot) internal {
        vm.prank(minter);
        token.mint(snapshot.user, snapshot.balance, snapshot.rate);
    }

    function testFuzzMigratedBalanceExactlyMatchesSnapshotAtCutover(uint256 balance) public {
        balance = bound(balance, 1, 1e30);
        address alice = makeAddr("alice");

        LegacySnapshot memory snap = LegacySnapshot({user: alice, balance: balance, rate: INITIAL_RATE});
        _migrateUser(snap);

        // Zero discontinuity: the instant after migration, the balance is exactly the snapshot —
        // no rounding loss, no rebase jump, since this is the very first mint into an untouched
        // tier (index == RAY, so shares == tokens 1:1).
        assertEq(token.balanceOf(alice), snap.balance);
    }

    function testMultipleUsersMigrateWithoutCrossContamination() public {
        LegacySnapshot[3] memory snaps = [
            LegacySnapshot({user: makeAddr("alice"), balance: 1000 ether, rate: INITIAL_RATE}),
            LegacySnapshot({user: makeAddr("bob"), balance: 500 ether, rate: INITIAL_RATE}),
            LegacySnapshot({user: makeAddr("carol"), balance: 2500 ether, rate: INITIAL_RATE})
        ];

        for (uint256 i = 0; i < snaps.length; i++) {
            _migrateUser(snaps[i]);
        }

        for (uint256 i = 0; i < snaps.length; i++) {
            assertEq(token.balanceOf(snaps[i].user), snaps[i].balance);
        }
    }

    /// @dev Legacy holders locked in at different rates (some pre-dating a governance rate cut)
    /// must land in tiers matching their own snapshot rate, not be forced onto whatever the
    /// current global rate happens to be — preserving the per-user-rate property across the
    /// cutover. Migration itself must run at (or before) the cutover global rate, exactly like a
    /// bridge-in: a snapshot rate higher than the *current* rate at migration time is clamped by
    /// the same L10 rule that governs any other mint, which is correct — the migration path
    /// reuses `mint()` verbatim rather than a privileged bypass, so it inherits that invariant too.
    function testMigratedUsersPreserveDistinctLegacyRates() public {
        address earlyHolder = makeAddr("earlyHolder"); // locked in at the original, higher rate
        address lateHolder = makeAddr("lateHolder"); // locked in at a lower rate

        // Migrate both while the global rate is still at its original (highest) value, mirroring
        // a real cutover that snapshots and replays before any further governance rate changes.
        _migrateUser(LegacySnapshot({user: earlyHolder, balance: 1000 ether, rate: INITIAL_RATE}));
        vm.prank(owner);
        token.setInterestRate(3e10);
        _migrateUser(LegacySnapshot({user: lateHolder, balance: 1000 ether, rate: 3e10}));

        assertEq(token.getUserInterestRate(earlyHolder), INITIAL_RATE);
        assertEq(token.getUserInterestRate(lateHolder), 3e10);

        // Both start at the same balance (no discontinuity)...
        assertEq(token.balanceOf(earlyHolder), 1000 ether);
        assertEq(token.balanceOf(lateHolder), 1000 ether);

        // ...but accrue at their own distinct rates afterward, proving the migration didn't
        // collapse everyone onto a single shared rate.
        vm.warp(block.timestamp + 365 days);
        assertGt(token.balanceOf(earlyHolder), token.balanceOf(lateHolder));
    }

    /// @dev The moment immediately before and after migration must show no jump: reading a
    /// "pre-migration" balance from the snapshot and the "post-migration" balance from the fresh
    /// contract at the same logical instant must agree exactly.
    function testNoDiscontinuityAcrossCutoverInstant() public {
        uint256 preMigrationBalance = 42_424_242 ether;
        address user = makeAddr("user");

        uint256 postMigrationBalance = token.balanceOf(user); // 0, not yet migrated
        assertEq(postMigrationBalance, 0);

        _migrateUser(LegacySnapshot({user: user, balance: preMigrationBalance, rate: INITIAL_RATE}));

        postMigrationBalance = token.balanceOf(user);
        assertEq(postMigrationBalance, preMigrationBalance);
    }

    /// @dev After migration, continued accrual must behave identically to a user who had always
    /// been on the index model — no residual "legacy" behavior or stale timestamp artifacts.
    function testPostMigrationAccrualBehavesNormally() public {
        address user = makeAddr("user");
        _migrateUser(LegacySnapshot({user: user, balance: 1000 ether, rate: INITIAL_RATE}));

        uint256 balanceAtMigration = token.balanceOf(user);
        vm.warp(block.timestamp + 30 days);
        uint256 balanceAfterAccrual = token.balanceOf(user);

        assertGt(balanceAfterAccrual, balanceAtMigration);

        // A subsequent transfer works exactly like any non-migrated account's would.
        address recipient = makeAddr("recipient");
        vm.prank(user);
        token.transfer(recipient, balanceAfterAccrual / 2);
        assertApproxEqAbs(token.balanceOf(recipient), balanceAfterAccrual / 2, 1);
    }
}
