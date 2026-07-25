// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {WithdrawalQueue} from "../../src/vault/WithdrawalQueue.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract WithdrawalQueueTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;
    WithdrawalQueue queue;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.startPrank(owner);
        token = new RebaseToken();
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        queue = new WithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        token.grantMintAndBurnRole(address(vault));
        vm.stopPrank();
    }

    /// @notice Vault starts with no ETH beyond user deposits, so a redemption for more than the
    /// vault currently holds (e.g. because it was drained by an earlier full redemption path in
    /// the test, or simply exceeds instantaneous liquidity) must enqueue rather than revert.
    function _depositAndDrainLiquidity(uint256 depositAmount) internal {
        vm.deal(user, depositAmount);
        vm.prank(user);
        vault.deposit{value: depositAmount}();
        // Simulate the vault's ETH being tied up elsewhere (e.g. a strategy) by removing it —
        // there's no strategy in Phase 2, so we drop the vault's balance directly via vm.deal to
        // simulate a liquidity crunch without needing a real yield strategy.
        vm.deal(address(vault), 0);
    }

    function testRedeemQueuesWhenLiquidityInsufficient() public {
        _depositAndDrainLiquidity(10 ether);

        vm.prank(user);
        vault.redeem(10 ether);

        assertEq(token.balanceOf(user), 0); // RBT burned immediately
        // Not yet reserved against totalPendingClaims — that only happens once markClaimable
        // promotes the request, since it's when the Vault actually commits liquidity to it.
        assertEq(queue.totalPendingClaims(), 0);

        WithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertEq(uint8(req.status), uint8(WithdrawalQueue.Status.Requested));
        assertEq(req.user, user);
        assertEq(req.amount, 10 ether);
    }

    function testMarkClaimableRequiresLiquidity() public {
        _depositAndDrainLiquidity(10 ether);
        vm.prank(user);
        vault.redeem(10 ether);

        vm.expectRevert(abi.encodeWithSelector(Errors.Queue__InsufficientLiquidity.selector, 10 ether, 0));
        queue.markClaimable(1);

        vm.deal(address(vault), 10 ether);
        queue.markClaimable(1);

        WithdrawalQueue.WithdrawalRequest memory req = queue.getRequest(1);
        assertEq(uint8(req.status), uint8(WithdrawalQueue.Status.Claimable));
    }

    function testClaimPaysOutAndOnlyRequestOwnerCanClaim() public {
        _depositAndDrainLiquidity(10 ether);
        vm.prank(user);
        vault.redeem(10 ether);

        vm.deal(address(vault), 10 ether);
        queue.markClaimable(1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.Queue__NotRequestOwner.selector, stranger, user));
        queue.claim(1);

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        queue.claim(1);

        assertEq(user.balance, balanceBefore + 10 ether);
        assertEq(queue.totalPendingClaims(), 0);
        assertEq(uint8(queue.getRequest(1).status), uint8(WithdrawalQueue.Status.Paid));
    }

    function testCannotClaimTwice() public {
        _depositAndDrainLiquidity(10 ether);
        vm.prank(user);
        vault.redeem(10 ether);
        vm.deal(address(vault), 10 ether);
        queue.markClaimable(1);

        vm.prank(user);
        queue.claim(1);

        vm.prank(user);
        vm.expectRevert(Errors.Queue__InvalidStatus.selector);
        queue.claim(1);
    }

    function testCancelRestoresRbtAtOriginalRate() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();
        uint256 originalRate = token.getUserInterestRate(user);

        vm.deal(address(vault), 0);
        vm.prank(user);
        vault.redeem(10 ether);
        assertEq(token.balanceOf(user), 0);

        vm.prank(user);
        queue.cancel(1);

        assertEq(token.balanceOf(user), 10 ether);
        assertEq(token.getUserInterestRate(user), originalRate);
        assertEq(queue.totalPendingClaims(), 0);
        assertEq(uint8(queue.getRequest(1).status), uint8(WithdrawalQueue.Status.Cancelled));
    }

    function testCannotCancelAfterPaid() public {
        _depositAndDrainLiquidity(10 ether);
        vm.prank(user);
        vault.redeem(10 ether);
        vm.deal(address(vault), 10 ether);
        queue.markClaimable(1);
        vm.prank(user);
        queue.claim(1);

        vm.prank(user);
        vm.expectRevert(Errors.Queue__InvalidStatus.selector);
        queue.cancel(1);
    }

    function testOnlyStrangerCannotCancelSomeoneElsesRequest() public {
        _depositAndDrainLiquidity(10 ether);
        vm.prank(user);
        vault.redeem(10 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.Queue__NotRequestOwner.selector, stranger, user));
        queue.cancel(1);
    }

    /// @notice Vault's direct disburse/restoreFromQueue entrypoints are queue-only — nothing
    /// else, including the request's own user, can call them directly to bypass the FSM.
    function testVaultDisburseAndRestoreAreQueueOnly() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__NotQueue.selector, user));
        vault.disburse(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__NotQueue.selector, user));
        vault.restoreFromQueue(user, 1 ether, 5e10);
    }

    function testWithdrawalQueueCanOnlyBeSetOnce() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Vault__QueueAlreadySet.selector);
        vault.setWithdrawalQueue(makeAddr("newQueue"));
    }
}
