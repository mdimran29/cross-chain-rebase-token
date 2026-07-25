// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice L10: mint() must never let a bridge-in (or any mint) raise a user's rate above the
/// current global rate, nor raise it above the rate they already hold.
contract RateReconciliationTest is Test {
    RebaseToken token;
    address owner = makeAddr("owner");
    address minter = makeAddr("minter");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);
        token = new RebaseToken();
        token.grantMintAndBurnRole(minter);
        token.grantRole(Roles.RATE_ADMIN_ROLE, owner);
        vm.stopPrank();
    }

    function testZeroBalanceMintClampsToCurrentGlobalRateWhenBridgedRateIsHigher() public {
        uint256 currentGlobalRate = token.getInterestRate(); // 5e10
        uint256 staleHigherRate = currentGlobalRate * 2;

        vm.prank(minter);
        token.mint(user, 100, staleHigherRate);

        assertEq(token.getUserInterestRate(user), currentGlobalRate);
    }

    function testZeroBalanceMintAdoptsBridgedRateWhenBelowGlobalRate() public {
        uint256 currentGlobalRate = token.getInterestRate();
        uint256 lowerRate = currentGlobalRate / 2;

        vm.prank(minter);
        token.mint(user, 100, lowerRate);

        assertEq(token.getUserInterestRate(user), lowerRate);
    }

    function testNonZeroBalanceMintNeverRaisesExistingRate() public {
        // User already holds a lower rate from an earlier mint/deposit.
        vm.prank(minter);
        token.mint(user, 100, 1e10);
        assertEq(token.getUserInterestRate(user), 1e10);

        // A later bridge-in carries a higher (even if still <= current global) rate — must not
        // raise the user's locked-in rate.
        vm.prank(minter);
        token.mint(user, 50, 3e10);

        assertEq(token.getUserInterestRate(user), 1e10);
    }

    function testNonZeroBalanceMintCanLowerExistingRate() public {
        vm.prank(minter);
        token.mint(user, 100, 4e10);
        assertEq(token.getUserInterestRate(user), 4e10);

        vm.prank(minter);
        token.mint(user, 50, 1e10);

        assertEq(token.getUserInterestRate(user), 1e10);
    }

    function testGlobalRateDecreaseThenStaleBridgeInCannotResurrectHigherRate() public {
        // Simulates the L10 exploit: user bridges out at the original (high) global rate, the
        // global rate then decreases, and the user bridges back in carrying the stale payload.
        uint256 originalGlobalRate = token.getInterestRate(); // 5e10
        vm.prank(minter);
        token.mint(user, 100, originalGlobalRate);
        assertEq(token.getUserInterestRate(user), 5e10);

        vm.prank(owner);
        token.setInterestRate(2e10);

        // Full round-trip: burn to zero (simulating bridge-out), then mint back in with the
        // stale 5e10 rate the old payload carried.
        vm.prank(minter);
        token.burn(user, 100);
        vm.prank(minter);
        token.mint(user, 100, 5e10);

        assertEq(token.getUserInterestRate(user), 2e10);
    }

    function testFuzzMintedRateNeverExceedsCurrentGlobalRate(uint256 bridgedRate) public {
        bridgedRate = bound(bridgedRate, 0, type(uint128).max);
        uint256 currentGlobalRate = token.getInterestRate();

        vm.prank(minter);
        token.mint(user, 1, bridgedRate);

        assertLe(token.getUserInterestRate(user), currentGlobalRate);
    }
}
