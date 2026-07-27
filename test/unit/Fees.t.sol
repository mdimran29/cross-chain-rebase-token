// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract FeesTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;

    address owner = makeAddr("owner");
    address feeAdmin = makeAddr("feeAdmin");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);
        InterestRateController rateController = new InterestRateController(5e10, owner);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        token.grantMintAndBurnRole(address(vault));
        vault.grantRole(Roles.FEE_ADMIN_ROLE, feeAdmin);
        vm.stopPrank();
        vm.deal(address(vault), 100 ether); // pre-existing liquidity so redemptions never queue
    }

    // ---------------------------------------------------------------
    // Caps
    // ---------------------------------------------------------------

    function testDepositFeeCappedAt2Percent() public {
        uint256 cap = vault.MAX_DEPOSIT_FEE_BPS();
        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__FeeExceedsCap.selector, 201, cap));
        vault.setDepositFeeBps(201);

        vm.prank(feeAdmin);
        vault.setDepositFeeBps(200);
        assertEq(vault.depositFeeBps(), 200);
    }

    function testWithdrawalFeeCappedAt2Percent() public {
        uint256 cap = vault.MAX_WITHDRAWAL_FEE_BPS();
        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__FeeExceedsCap.selector, 201, cap));
        vault.setWithdrawalFeeBps(201);
    }

    function testNonFeeAdminCannotSetFees() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setDepositFeeBps(100);
    }

    // ---------------------------------------------------------------
    // Fee math
    // ---------------------------------------------------------------

    function testDepositFeeRoutesToTreasuryAndMintsNetAmount() public {
        vm.prank(feeAdmin);
        vault.setDepositFeeBps(100); // 1%

        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        uint256 expectedFee = 0.1 ether;
        uint256 expectedNet = 9.9 ether;
        assertEq(token.balanceOf(user), expectedNet);
        assertEq(treasury.feeBalance(), expectedFee);
    }

    function testWithdrawalFeeRoutesToTreasuryAndPaysNetAmount() public {
        vm.prank(feeAdmin);
        vault.setWithdrawalFeeBps(50); // 0.5%

        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        vault.redeem(10 ether);

        uint256 expectedFee = 0.05 ether;
        assertEq(treasury.feeBalance(), expectedFee);
        assertEq(user.balance, balanceBefore + 10 ether - expectedFee);
    }

    function testZeroFeeMeansFullAmount() public {
        vm.deal(user, 5 ether);
        vm.prank(user);
        vault.deposit{value: 5 ether}();
        assertEq(token.balanceOf(user), 5 ether);
        assertEq(treasury.feeBalance(), 0);
    }

    /// @notice Principal is never taken as a fee beyond the configured bps — the fee is always a
    /// strict fraction of the transaction amount, never an additional deduction.
    function testFeeNeverExceedsConfiguredFraction(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 1e5, 1000 ether);
        feeBps = bound(feeBps, 0, vault.MAX_DEPOSIT_FEE_BPS());

        vm.prank(feeAdmin);
        vault.setDepositFeeBps(feeBps);

        vm.deal(user, amount);
        vm.prank(user);
        vault.deposit{value: amount}();

        uint256 expectedFee = (amount * feeBps) / vault.BPS_DENOMINATOR();
        assertEq(treasury.feeBalance(), expectedFee);
        assertEq(token.balanceOf(user), amount - expectedFee);
    }

    function testTreasuryWithdrawReserveGatedByTreasurerRole() public {
        vm.prank(feeAdmin);
        vault.setDepositFeeBps(100);
        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        address treasurer = makeAddr("treasurer");
        address recipient = makeAddr("recipient");

        vm.prank(user);
        vm.expectRevert();
        treasury.withdrawReserve(Treasury.Bucket.Fee, payable(recipient), 0.05 ether);

        vm.prank(owner);
        treasury.grantRole(Roles.TREASURER_ROLE, treasurer);

        vm.prank(treasurer);
        treasury.withdrawReserve(Treasury.Bucket.Fee, payable(recipient), 0.05 ether);
        assertEq(recipient.balance, 0.05 ether);
    }
}
