// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {RebaseTokenPool} from "../../src/RebaseTokenPool.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {GovernanceToken} from "../../src/governance/GovernanceToken.sol";
import {RebaseGovernor} from "../../src/governance/RebaseGovernor.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Phase 3 (Governance & Timelock): deploys the Timelock + Governor + voting token, then
/// migrates every value-changing role on Token/Vault/Pool/Treasury from the deployer to the
/// Timelock, and every pause-only role to the Emergency Council — resolving L5 (a single EOA/
/// multisig owner with instant, unilateral power).
/// @dev Design principle carried over from the roadmap (§2.1, §3.13): the Timelock+Governor path
/// is slow and can change economic parameters; the Council path is fast but can *only* pause,
/// never move funds or change yield terms. Nothing here lets one key do both.
contract DeployGovernanceScript is Script {
    struct GovernanceDeployment {
        GovernanceToken governanceToken;
        TimelockController timelock;
        RebaseGovernor governor;
    }

    /// @param initialVotingDelay In blocks (`Votes.clock()` defaults to block number, not
    /// timestamp) — roadmap targets ~1 day; convert using the target chain's block time.
    /// @param initialVotingPeriod In blocks — roadmap targets ~3-5 days.
    /// @param minTimelockDelay In *seconds* (`TimelockController` uses `block.timestamp`) —
    /// roadmap targets 24-72h.
    function deployGovernance(
        address governanceTokenInitialHolder,
        uint256 governanceTokenInitialSupply,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 quorumNumeratorValue,
        uint256 minTimelockDelay,
        address guardian
    ) public returns (GovernanceDeployment memory deployment) {
        vm.startBroadcast();

        deployment.governanceToken = new GovernanceToken(governanceTokenInitialSupply);
        if (governanceTokenInitialHolder != msg.sender) {
            deployment.governanceToken.transfer(governanceTokenInitialHolder, governanceTokenInitialSupply);
        }

        // No proposers/executors at construction and no external admin: every role below is
        // granted explicitly afterward, and the Timelock self-administers (`DEFAULT_ADMIN_ROLE`
        // held by `address(this)` per its own constructor) rather than depending on an EOA.
        deployment.timelock = new TimelockController(minTimelockDelay, new address[](0), new address[](0), address(0));

        deployment.governor = new RebaseGovernor(
            deployment.governanceToken,
            deployment.timelock,
            initialVotingDelay,
            initialVotingPeriod,
            initialProposalThreshold,
            quorumNumeratorValue
        );

        // Only the Governor may schedule/cancel operations through normal proposal flow; anyone
        // may execute once an operation is ready (its parameters were already fixed at schedule
        // time, so open execution doesn't add privilege, only removes a liveness dependency).
        deployment.timelock.grantRole(deployment.timelock.PROPOSER_ROLE(), address(deployment.governor));
        deployment.timelock.grantRole(deployment.timelock.CANCELLER_ROLE(), address(deployment.governor));
        deployment.timelock.grantRole(deployment.timelock.EXECUTOR_ROLE(), address(0));

        // Guardian: can veto (cancel) a queued-but-not-yet-executed operation directly on the
        // Timelock within the delay window — independent of, and in addition to, the Governor's
        // own proposal-cancellation path.
        if (guardian != address(0)) {
            deployment.timelock.grantRole(deployment.timelock.CANCELLER_ROLE(), guardian);
        }

        vm.stopBroadcast();

        console2.log("governanceToken:", address(deployment.governanceToken));
        console2.log("timelock:", address(deployment.timelock));
        console2.log("governor:", address(deployment.governor));
    }

    /// @notice Migrates value-changing roles to the Timelock and pause-only roles to the
    /// Emergency Council across Token/Vault/Pool/Treasury, then renounces the deployer's own
    /// copies everywhere a single-step renounce is safe.
    /// @dev RebaseToken's `DEFAULT_ADMIN_ROLE` uses a two-step handover
    /// (`beginAdminTransfer`/`acceptAdminTransfer`) that only the *pending* admin can complete.
    /// Since the pending admin here is the Timelock contract itself, completing it requires a
    /// separate governance action (schedule + wait `minDelay` + execute a call to
    /// `acceptAdminTransfer()`) — that cannot happen synchronously inside this script. This
    /// function only *begins* that transfer; running `acceptAdminTransfer` through the Timelock
    /// is the first proposal a real deployment should queue.
    function migrateRoles(
        address _rebaseToken,
        address _vault,
        address _pool,
        address _treasury,
        address timelock,
        address council
    ) public {
        RebaseToken token = RebaseToken(_rebaseToken);
        Vault vault = Vault(payable(_vault));
        RebaseTokenPool pool = RebaseTokenPool(_pool);
        Treasury treasury = Treasury(payable(_treasury));

        vm.startBroadcast();

        // ---- Value-changing roles -> Timelock ----
        token.grantRole(Roles.RATE_ADMIN_ROLE, timelock);
        token.grantRole(Roles.UNPAUSER_ROLE, timelock);
        token.beginAdminTransfer(timelock); // see NatSpec: completed by a later governance action

        vault.grantRole(Roles.FEE_ADMIN_ROLE, timelock);
        vault.grantRole(Roles.UNPAUSER_ROLE, timelock);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), timelock);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender);

        pool.grantRole(Roles.LANE_ADMIN_ROLE, timelock);
        pool.grantRole(Roles.UNPAUSER_ROLE, timelock);
        pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), timelock);
        pool.renounceRole(pool.DEFAULT_ADMIN_ROLE(), msg.sender);

        treasury.grantRole(Roles.TREASURER_ROLE, timelock);
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), timelock);
        treasury.renounceRole(treasury.DEFAULT_ADMIN_ROLE(), msg.sender);

        // ---- Pause-only (subtractive) role -> Emergency Council ----
        token.grantRole(Roles.PAUSER_ROLE, council);
        vault.grantRole(Roles.PAUSER_ROLE, council);
        pool.grantRole(Roles.PAUSER_ROLE, council);

        vm.stopBroadcast();

        require(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer still has vault admin");
        require(!pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer still has pool admin");
        require(!treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer still has treasury admin");
    }
}
