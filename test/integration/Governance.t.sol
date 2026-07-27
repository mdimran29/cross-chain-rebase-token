// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {GovernanceToken} from "../../src/governance/GovernanceToken.sol";
import {RebaseGovernor} from "../../src/governance/RebaseGovernor.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice End-to-end Phase 3 test: propose -> vote -> queue -> execute through a real
/// TimelockController + Governor, the Emergency Council's subtractive-only pause authority, the
/// Guardian's direct veto of a queued Timelock operation, and confirmation that the deployer ends
/// up with zero residual unilateral power anywhere. Pool is intentionally out of scope here — its
/// role wiring (`LANE_ADMIN_ROLE` -> Timelock, `PAUSER_ROLE` -> Council) is mechanically identical
/// to Vault/Treasury's and already exercised by the Phase 0/1 access-control unit tests; adding it
/// here would only pull in CCIP router/RMN mocking with no new governance behavior to prove.
contract GovernanceIntegrationTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;

    GovernanceToken govToken;
    TimelockController timelockController;
    RebaseGovernor governor;

    address deployer = makeAddr("deployer");
    address council = makeAddr("council"); // stand-in for the Gnosis Safe Emergency Council
    address guardian = makeAddr("guardian"); // stand-in for the Guardian multisig
    address voterA = makeAddr("voterA");
    address voterB = makeAddr("voterB");
    address voterC = makeAddr("voterC");

    uint48 constant VOTING_DELAY = 1; // blocks
    uint32 constant VOTING_PERIOD = 50; // blocks
    uint256 constant MIN_TIMELOCK_DELAY = 2 days;
    uint256 constant QUORUM_NUMERATOR = 4; // 4%
    uint256 constant GOV_SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.startPrank(deployer);

        // ---- Core protocol (Phase 0-2 state) ----
        InterestRateController rateController = new InterestRateController(5e10, deployer);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        token.grantMintAndBurnRole(address(vault));

        // ---- Governance token: distributed to three voters who each self-delegate ----
        govToken = new GovernanceToken(GOV_SUPPLY);
        govToken.transfer(voterA, 400_000 ether);
        govToken.transfer(voterB, 300_000 ether);
        govToken.transfer(voterC, 300_000 ether);
        vm.stopPrank();

        vm.prank(voterA);
        govToken.delegate(voterA);
        vm.prank(voterB);
        govToken.delegate(voterB);
        vm.prank(voterC);
        govToken.delegate(voterC);

        // Let delegation land in a checkpoint strictly before any proposal snapshot.
        vm.roll(block.number + 1);

        vm.startPrank(deployer);

        // ---- Timelock: deployer holds TIMELOCK_ADMIN_ROLE only long enough to wire roles
        // below, then renounces it at the end of setUp — the Timelock is self-administering
        // (`DEFAULT_ADMIN_ROLE` held by `address(this)` per its own constructor) from then on.
        timelockController = new TimelockController(MIN_TIMELOCK_DELAY, new address[](0), new address[](0), deployer);

        governor = new RebaseGovernor(govToken, timelockController, VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_NUMERATOR);

        timelockController.grantRole(timelockController.PROPOSER_ROLE(), address(governor));
        timelockController.grantRole(timelockController.CANCELLER_ROLE(), address(governor));
        timelockController.grantRole(timelockController.EXECUTOR_ROLE(), address(0));
        timelockController.grantRole(timelockController.CANCELLER_ROLE(), guardian);

        // ---- Migrate value-changing roles to the Timelock, pause-only to the Council ----
        token.grantRole(Roles.RATE_ADMIN_ROLE, address(timelockController));
        token.grantRole(Roles.UNPAUSER_ROLE, address(timelockController));
        token.grantRole(Roles.PAUSER_ROLE, council);

        vault.grantRole(Roles.FEE_ADMIN_ROLE, address(timelockController));
        vault.grantRole(Roles.UNPAUSER_ROLE, address(timelockController));
        vault.grantRole(Roles.PAUSER_ROLE, council);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(timelockController));
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

        treasury.grantRole(Roles.TREASURER_ROLE, address(timelockController));
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), address(timelockController));
        treasury.renounceRole(treasury.DEFAULT_ADMIN_ROLE(), deployer);

        // RebaseToken's DEFAULT_ADMIN_ROLE uses a two-step handover: begin it here, then complete
        // it through the Timelock itself below (a real deploy would run this as the very first
        // governance-scheduled action; we do the same thing here, just via the deployer's
        // temporary bootstrap scheduling rights rather than a full Governor vote, since it's
        // one-time infrastructure setup, not an ongoing policy decision).
        token.beginAdminTransfer(address(timelockController));

        timelockController.grantRole(timelockController.PROPOSER_ROLE(), deployer);
        timelockController.grantRole(timelockController.EXECUTOR_ROLE(), deployer);
        vm.stopPrank();

        bytes memory acceptAdminCalldata = abi.encodeCall(RebaseToken.acceptAdminTransfer, ());
        vm.startPrank(deployer);
        timelockController.schedule(address(token), 0, acceptAdminCalldata, bytes32(0), bytes32(0), MIN_TIMELOCK_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_TIMELOCK_DELAY + 1);

        vm.startPrank(deployer);
        timelockController.execute(address(token), 0, acceptAdminCalldata, bytes32(0), bytes32(0));
        // Bootstrap complete: revoke the deployer's temporary scheduling rights, then renounce
        // its own admin over the Timelock — nothing left for a single key to unilaterally control.
        timelockController.revokeRole(timelockController.PROPOSER_ROLE(), deployer);
        timelockController.revokeRole(timelockController.EXECUTOR_ROLE(), deployer);
        timelockController.renounceRole(timelockController.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();
    }

    function _vote(uint256 proposalId) internal {
        vm.prank(voterA);
        governor.castVote(proposalId, 1); // For
        vm.prank(voterB);
        governor.castVote(proposalId, 1); // For
        // voterC abstains from voting — still comfortably above quorum (4% of 1M = 40k; A+B = 700k).
    }

    // ---------------------------------------------------------------
    // Full lifecycle: propose -> vote -> queue -> execute; delay enforced
    // ---------------------------------------------------------------

    function testFullLifecycleChangesInterestRateAndEnforcesDelay() public {
        uint256 newRate = 1e10;
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(RebaseToken.setInterestRate, (newRate));
        string memory description = "Lower the global interest rate to 1e10";

        vm.prank(voterA);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        _vote(proposalId);

        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Delay enforced: executing before the Timelock's minDelay elapses must revert.
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + MIN_TIMELOCK_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(token.getInterestRate(), newRate);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // ---------------------------------------------------------------
    // Council: pauses fast, cannot change value/rate
    // ---------------------------------------------------------------

    function testCouncilCanPauseButCannotChangeRateOrFees() public {
        vm.prank(council);
        token.pause();
        assertTrue(token.paused());

        vm.prank(council);
        vm.expectRevert();
        token.setInterestRate(1);
    }

    function testCouncilCannotSetVaultFees() public {
        vm.prank(council);
        vm.expectRevert();
        vault.setDepositFeeBps(100);
    }

    function testCouncilCannotUnpause() public {
        vm.prank(council);
        token.pause();

        vm.prank(council);
        vm.expectRevert();
        token.unpause();
    }

    // ---------------------------------------------------------------
    // Guardian: can veto a queued (not yet executed) Timelock operation
    // ---------------------------------------------------------------

    function testGuardianCanVetoQueuedProposal() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(RebaseToken.setInterestRate, (1));
        string memory description = "Suspicious rate change";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(voterA);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);
        _vote(proposalId);
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
        bytes32 timelockId = timelockController.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        vm.prank(guardian);
        timelockController.cancel(timelockId);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        vm.warp(block.timestamp + MIN_TIMELOCK_DELAY + 1);
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function testStrangerCannotVetoQueuedProposal() public {
        address[] memory targets = new address[](1);
        targets[0] = address(token);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(RebaseToken.setInterestRate, (1));
        string memory description = "Another rate change";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(voterA);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + VOTING_DELAY + 1);
        _vote(proposalId);
        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);

        bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
        bytes32 timelockId = timelockController.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        timelockController.cancel(timelockId);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
    }

    // ---------------------------------------------------------------
    // No residual unilateral owner anywhere
    // ---------------------------------------------------------------

    function testDeployerHasNoResidualPowerAnywhere() public view {
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), deployer));

        assertFalse(token.hasRole(Roles.RATE_ADMIN_ROLE, deployer));
        assertFalse(token.hasRole(Roles.UNPAUSER_ROLE, deployer));
        assertFalse(token.hasRole(Roles.PAUSER_ROLE, deployer));
        assertFalse(vault.hasRole(Roles.FEE_ADMIN_ROLE, deployer));
        assertFalse(vault.hasRole(Roles.UNPAUSER_ROLE, deployer));
        assertFalse(vault.hasRole(Roles.PAUSER_ROLE, deployer));
        assertFalse(treasury.hasRole(Roles.TREASURER_ROLE, deployer));

        assertFalse(timelockController.hasRole(timelockController.PROPOSER_ROLE(), deployer));
        assertFalse(timelockController.hasRole(timelockController.EXECUTOR_ROLE(), deployer));
        assertFalse(timelockController.hasRole(timelockController.DEFAULT_ADMIN_ROLE(), deployer));

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(timelockController)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(timelockController)));
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), address(timelockController)));
    }
}
