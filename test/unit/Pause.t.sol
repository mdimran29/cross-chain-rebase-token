// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract PauseTest is Test {
    RebaseToken public rebaseToken;
    Vault public vault;

    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public user = makeAddr("user");
    uint256 public constant SEND_VALUE = 1e5;

    function setUp() public {
        vm.startPrank(owner);
        rebaseToken = new RebaseToken();
        vault = new Vault(IRebaseToken(address(rebaseToken)));
        rebaseToken.grantMintAndBurnRole(address(vault));
        rebaseToken.grantRole(Roles.PAUSER_ROLE, pauser);
        rebaseToken.grantRole(Roles.UNPAUSER_ROLE, unpauser);
        vault.grantRole(Roles.PAUSER_ROLE, pauser);
        vm.stopPrank();

        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vault.deposit{value: SEND_VALUE}();
    }

    // ---- RebaseToken pause ----

    function testPauserCanPauseToken() public {
        vm.prank(pauser);
        rebaseToken.pause();
        assertTrue(rebaseToken.paused());
    }

    function testNonPauserCannotPauseToken() public {
        vm.prank(user);
        vm.expectRevert();
        rebaseToken.pause();
    }

    function testMintRevertsWhenPaused() public {
        vm.prank(pauser);
        rebaseToken.pause();

        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vm.expectRevert();
        vault.deposit{value: SEND_VALUE}();
    }

    function testBurnRevertsWhenPaused() public {
        vm.prank(pauser);
        rebaseToken.pause();

        vm.prank(user);
        vm.expectRevert();
        vault.redeem(SEND_VALUE);
    }

    function testTransferRevertsWhenPaused() public {
        vm.prank(pauser);
        rebaseToken.pause();

        vm.prank(user);
        vm.expectRevert();
        rebaseToken.transfer(makeAddr("someoneElse"), 1);
    }

    function testTransferFromRevertsWhenPaused() public {
        vm.prank(user);
        rebaseToken.approve(address(this), SEND_VALUE);

        vm.prank(pauser);
        rebaseToken.pause();

        vm.expectRevert();
        rebaseToken.transferFrom(user, makeAddr("someoneElse"), 1);
    }

    function testReadsWorkWhilePaused() public {
        vm.prank(pauser);
        rebaseToken.pause();

        // Reads must never revert while paused.
        rebaseToken.balanceOf(user);
        rebaseToken.principalBalanceOf(user);
        rebaseToken.getInterestRate();
        rebaseToken.getUserInterestRate(user);
    }

    function testOnlyUnpauserCanUnpause() public {
        vm.prank(pauser);
        rebaseToken.pause();

        vm.prank(pauser);
        vm.expectRevert();
        rebaseToken.unpause();

        vm.prank(unpauser);
        rebaseToken.unpause();
        assertFalse(rebaseToken.paused());
    }

    function testFunctionsWorkAgainAfterUnpause() public {
        vm.prank(pauser);
        rebaseToken.pause();
        vm.prank(unpauser);
        rebaseToken.unpause();

        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vault.deposit{value: SEND_VALUE}();
    }

    // ---- Vault scoped pause ----

    function testDepositRevertsWhenDepositsPaused() public {
        vm.prank(pauser);
        vault.setDepositsPaused(true);

        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vm.expectRevert(Errors.Vault__DepositsPaused.selector);
        vault.deposit{value: SEND_VALUE}();
    }

    function testRedeemStillWorksWhenOnlyDepositsPaused() public {
        vm.prank(pauser);
        vault.setDepositsPaused(true);

        vm.prank(user);
        vault.redeem(SEND_VALUE);
        assertEq(rebaseToken.balanceOf(user), 0);
    }

    function testRedeemRevertsWhenRedemptionsPaused() public {
        vm.prank(pauser);
        vault.setRedemptionsPaused(true);

        vm.prank(user);
        vm.expectRevert(Errors.Vault__RedemptionsPaused.selector);
        vault.redeem(SEND_VALUE);
    }

    function testDepositStillWorksWhenOnlyRedemptionsPaused() public {
        vm.prank(pauser);
        vault.setRedemptionsPaused(true);

        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vault.deposit{value: SEND_VALUE}();
    }

    function testNonPauserCannotPauseVault() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setDepositsPaused(true);
    }
}
