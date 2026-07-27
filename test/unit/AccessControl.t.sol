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

contract AccessControlTest is Test {
    RebaseToken public rebaseToken;
    InterestRateController public rateController;
    Vault public vault;
    Treasury public treasury;

    address public deployer = makeAddr("deployer");
    address public admin = makeAddr("admin");
    address public rateAdmin = makeAddr("rateAdmin");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        vm.startPrank(deployer);
        rateController = new InterestRateController(5e10, deployer);
        rebaseToken = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(rebaseToken));
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(rebaseToken)), address(treasury));
        vm.stopPrank();
    }

    // ---- Role matrix: who can/can't call privileged functions ----

    function testOnlyAdminCanGrantMintAndBurnRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.grantMintAndBurnRole(stranger);

        vm.prank(deployer);
        rebaseToken.grantMintAndBurnRole(address(vault));
        assertTrue(rebaseToken.hasRole(Roles.MINT_AND_BURN_ROLE, address(vault)));
    }

    function testOnlyRateAdminCanSetInterestRate() public {
        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.setInterestRate(1e10);

        vm.prank(deployer);
        rebaseToken.grantRole(Roles.RATE_ADMIN_ROLE, rateAdmin);

        vm.prank(rateAdmin);
        rebaseToken.setInterestRate(1e10);
        assertEq(rebaseToken.getInterestRate(), 1e10);
    }

    function testOnlyPauserCanPauseEitherContract() public {
        address pauser = makeAddr("pauser");
        vm.startPrank(deployer);
        rebaseToken.grantRole(Roles.PAUSER_ROLE, pauser);
        vault.grantRole(Roles.PAUSER_ROLE, pauser);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.pause();

        vm.prank(stranger);
        vm.expectRevert();
        vault.setDepositsPaused(true);

        vm.startPrank(pauser);
        rebaseToken.pause();
        vault.setDepositsPaused(true);
        vm.stopPrank();

        assertTrue(rebaseToken.paused());
        assertTrue(vault.depositsPaused());
    }

    function testMintAndBurnGatedByRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.mint(stranger, 1, 1e10);

        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.burn(stranger, 1);
    }

    // ---- Two-step admin handover ----

    function testTwoStepAdminHandoverTransfersRoleAndRevokesDeployer() public {
        vm.prank(deployer);
        rebaseToken.beginAdminTransfer(admin);

        // Deployer still has admin until acceptance.
        assertTrue(rebaseToken.hasRole(rebaseToken.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(rebaseToken.hasRole(rebaseToken.DEFAULT_ADMIN_ROLE(), admin));

        vm.prank(admin);
        rebaseToken.acceptAdminTransfer();

        assertTrue(rebaseToken.hasRole(rebaseToken.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(rebaseToken.hasRole(rebaseToken.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function testOnlyPendingAdminCanAcceptTransfer() public {
        vm.prank(deployer);
        rebaseToken.beginAdminTransfer(admin);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotPendingAdmin.selector, stranger, admin));
        rebaseToken.acceptAdminTransfer();
    }

    function testAcceptTransferRevertsWithNoPendingTransfer() public {
        vm.prank(stranger);
        vm.expectRevert(Errors.NoPendingAdminTransfer.selector);
        rebaseToken.acceptAdminTransfer();
    }

    function testDeployerHasNoResidualAdminAfterHandover() public {
        vm.prank(deployer);
        rebaseToken.beginAdminTransfer(admin);
        vm.prank(admin);
        rebaseToken.acceptAdminTransfer();

        // Deployer can no longer perform any admin-gated action.
        vm.prank(deployer);
        vm.expectRevert();
        rebaseToken.grantMintAndBurnRole(stranger);

        vm.prank(deployer);
        vm.expectRevert();
        rebaseToken.beginAdminTransfer(stranger);

        // New admin can.
        vm.prank(admin);
        rebaseToken.grantMintAndBurnRole(address(vault));
        assertTrue(rebaseToken.hasRole(Roles.MINT_AND_BURN_ROLE, address(vault)));
    }

    function testOnlyAdminCanBeginTransfer() public {
        vm.prank(stranger);
        vm.expectRevert();
        rebaseToken.beginAdminTransfer(stranger);
    }
}
