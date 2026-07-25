// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 1000 ether);
    }
}

contract RecoveryModeTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);
        token = new RebaseToken();
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        token.grantMintAndBurnRole(address(vault));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Recovery mode: deposits blocked, independent of the normal pause switch
    // ---------------------------------------------------------------

    function testEnterRecoveryModeBlocksDepositsEvenWhenNotPaused() public {
        assertFalse(vault.depositsPaused());

        vm.prank(owner);
        vault.enterRecoveryMode();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(Errors.Vault__DepositsBlockedDuringRecovery.selector);
        vault.deposit{value: 1 ether}();
    }

    function testExitRecoveryModeRestoresDeposits() public {
        vm.startPrank(owner);
        vault.enterRecoveryMode();
        vault.exitRecoveryMode();
        vm.stopPrank();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vault.deposit{value: 1 ether}();
        assertEq(token.balanceOf(user), 1 ether);
    }

    function testOnlyAdminCanEnterOrExitRecoveryMode() public {
        vm.prank(user);
        vm.expectRevert();
        vault.enterRecoveryMode();
    }

    // ---------------------------------------------------------------
    // Recovery mode: pro-rata haircut on redemption when undercollateralized
    // ---------------------------------------------------------------

    function testRedeemAppliesProRataHaircutWhenUndercollateralized() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        // Simulate the vault becoming undercollateralized (e.g. after a loss event) by draining
        // half its ETH directly — there's no live strategy to lose funds through in Phase 2, so
        // this is the simplest way to construct an undercollateralized state for the test.
        vm.deal(address(vault), 5 ether);

        vm.prank(owner);
        vault.enterRecoveryMode();

        assertEq(vault.backing(), 5 ether);
        assertEq(vault.liabilities(), 10 ether);

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        vault.redeem(10 ether);

        // Haircut: paid = requested * backing / liabilities = 10 ether * 5/10 = 5 ether.
        assertEq(user.balance, balanceBefore + 5 ether);
    }

    function testRedeemPaysInFullInRecoveryModeIfFullyBacked() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 10 ether}();

        vm.prank(owner);
        vault.enterRecoveryMode();

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        vault.redeem(10 ether);

        assertEq(user.balance, balanceBefore + 10 ether);
    }

    // ---------------------------------------------------------------
    // rescueToken
    // ---------------------------------------------------------------

    function testRescueTokenCannotTargetRebaseToken() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Vault__CannotRescueProtocolAsset.selector);
        vault.rescueToken(token, owner, 1);
    }

    function testRescueTokenSweepsForeignToken() public {
        MockERC20 foreign = new MockERC20();
        foreign.transfer(address(vault), 100 ether);
        assertEq(foreign.balanceOf(address(vault)), 100 ether);

        address recipient = makeAddr("recipient");
        vm.prank(owner);
        vault.rescueToken(foreign, recipient, 100 ether);

        assertEq(foreign.balanceOf(recipient), 100 ether);
        assertEq(foreign.balanceOf(address(vault)), 0);
    }

    function testNonAdminCannotRescue() public {
        MockERC20 foreign = new MockERC20();
        foreign.transfer(address(vault), 10 ether);

        vm.prank(user);
        vm.expectRevert();
        vault.rescueToken(foreign, user, 10 ether);
    }
}
