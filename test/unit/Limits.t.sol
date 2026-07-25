// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract LimitsTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;

    address owner = makeAddr("owner");
    address feeAdmin = makeAddr("feeAdmin");
    address user = makeAddr("user");
    address userTwo = makeAddr("userTwo");

    function setUp() public {
        vm.startPrank(owner);
        token = new RebaseToken();
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        token.grantMintAndBurnRole(address(vault));
        vault.grantRole(Roles.FEE_ADMIN_ROLE, feeAdmin);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // minDeposit
    // ---------------------------------------------------------------

    function testMinDepositBoundary() public {
        vm.prank(feeAdmin);
        vault.setMinDeposit(1 ether);

        vm.deal(user, 1 ether - 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__DepositBelowMinimum.selector, 1 ether - 1, 1 ether));
        vault.deposit{value: 1 ether - 1}();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vault.deposit{value: 1 ether}();
        assertEq(token.balanceOf(user), 1 ether);
    }

    // ---------------------------------------------------------------
    // maxDepositPerTx
    // ---------------------------------------------------------------

    function testMaxDepositPerTxBoundary() public {
        vm.prank(feeAdmin);
        vault.setMaxDepositPerTx(5 ether);

        vm.deal(user, 5 ether + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__DepositExceedsPerTxCap.selector, 5 ether + 1, 5 ether));
        vault.deposit{value: 5 ether + 1}();

        vm.prank(user);
        vault.deposit{value: 5 ether}();
        assertEq(token.balanceOf(user), 5 ether);
    }

    // ---------------------------------------------------------------
    // maxDepositPerAddress (cumulative)
    // ---------------------------------------------------------------

    function testMaxDepositPerAddressBoundaryIsCumulative() public {
        vm.prank(feeAdmin);
        vault.setMaxDepositPerAddress(3 ether);

        vm.deal(user, 5 ether);
        vm.startPrank(user);
        vault.deposit{value: 2 ether}();

        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__DepositExceedsAddressCap.selector, 3 ether + 1, 3 ether));
        vault.deposit{value: 1 ether + 1}();

        vault.deposit{value: 1 ether}();
        vm.stopPrank();
        assertEq(vault.depositedByAddress(user), 3 ether);
    }

    // ---------------------------------------------------------------
    // globalTvlCap
    // ---------------------------------------------------------------

    function testGlobalTvlCapBoundary() public {
        vm.prank(feeAdmin);
        vault.setGlobalTvlCap(10 ether);

        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        vm.deal(userTwo, 1);
        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(Errors.Vault__DepositExceedsTvlCap.selector, 10 ether + 1, 10 ether));
        vault.deposit{value: 1}();
    }

    // ---------------------------------------------------------------
    // dailyNetFlowLimit
    // ---------------------------------------------------------------

    function testDailyNetFlowLimitThrottlesOutflow() public {
        vm.deal(address(vault), 100 ether);
        vm.deal(user, 100 ether);
        vm.prank(user);
        vault.deposit{value: 50 ether}();

        vm.prank(feeAdmin);
        vault.setDailyNetFlowLimit(10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Vault__DailyNetFlowLimitExceeded.selector, 10 ether + 1, 10 ether)
        );
        vault.redeem(10 ether + 1);

        vm.prank(user);
        vault.redeem(10 ether);
    }

    function testDailyNetFlowLimitResetsAfterWindow() public {
        vm.deal(address(vault), 100 ether);
        vm.deal(user, 100 ether);
        vm.prank(user);
        vault.deposit{value: 50 ether}();

        vm.prank(feeAdmin);
        vault.setDailyNetFlowLimit(10 ether);

        vm.prank(user);
        vault.redeem(10 ether);

        vm.prank(user);
        vm.expectRevert();
        vault.redeem(1 ether);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(user);
        vault.redeem(10 ether);
    }

    function testDailyNetFlowLimitDisabledByDefault() public {
        vm.deal(address(vault), 1000 ether);
        vm.deal(user, 1000 ether);
        vm.prank(user);
        vault.deposit{value: 1000 ether}();

        vm.prank(user);
        vault.redeem(1000 ether);
    }

    function testNonFeeAdminCannotSetLimits() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setMaxDepositPerTx(1 ether);
    }
}
