// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";

import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {Vault} from "../src/Vault.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {WithdrawalQueue} from "../src/vault/WithdrawalQueue.sol";
import {InterestRateController} from "../src/interest/InterestRateController.sol";

import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {Roles} from "../src/libraries/Roles.sol";

contract TokenAndPoolDeployer is Script {
    /// @notice Default global rate carried over from the pre-Phase-4 constant (`5e10`).
    uint256 public constant DEFAULT_INITIAL_RATE = 5e10;

    function run() public returns (RebaseToken token, RebaseTokenPool pool, InterestRateController controller) {
        CCIPLocalSimulatorFork ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        Register.NetworkDetails memory networkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.startBroadcast();
        controller = new InterestRateController(DEFAULT_INITIAL_RATE, msg.sender);
        token = new RebaseToken(address(controller));
        // The token calls back into the controller on every `setInterestRate`, so it needs the
        // controller's own RATE_ADMIN_ROLE (a separate AccessControl instance from the token's).
        controller.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        pool = new RebaseTokenPool(
            IERC20(address(token)),
            new address[](0),
            networkDetails.rmnProxyAddress,
            networkDetails.routerAddress,
            networkDetails.chainSelector
        );
        token.grantMintAndBurnRole(address(pool));
        RegistryModuleOwnerCustom(networkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(address(token));
        TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(token));
        TokenAdminRegistry(networkDetails.tokenAdminRegistryAddress).setPool(address(token), address(pool));
        vm.stopBroadcast();

        console2.log("token:", address(token));
        console2.log("pool:", address(pool));
    }
}

contract VaultDeployer is Script {
    /// @notice Deploys Treasury, Vault, and WithdrawalQueue together and wires them up.
    /// WithdrawalQueue must be deployed after Vault (it needs Vault's address in its own
    /// constructor) so it's wired via the one-time `setWithdrawalQueue` setter rather than a
    /// constructor arg, avoiding a circular deploy dependency.
    function run(address _rebaseToken) public returns (Vault vault, Treasury treasury, WithdrawalQueue queue) {
        vm.startBroadcast();
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(_rebaseToken), address(treasury));
        queue = new WithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        IRebaseToken(_rebaseToken).grantMintAndBurnRole(address(vault));
        vm.stopBroadcast();

        console2.log("vault:", address(vault));
        console2.log("treasury:", address(treasury));
        console2.log("withdrawalQueue:", address(queue));
    }
}

/// @notice Wires the Phase-0 role taxonomy on the token/vault and hands admin over to
/// the intended protocol admin, renouncing the deployer's own DEFAULT_ADMIN_ROLE.
/// @dev Uses the two-step transfer (beginAdminTransfer/acceptAdminTransfer) on RebaseToken
/// and single-step grant+renounce on Vault (Vault has no external actors depending on its
/// admin the way the bridged token does, so two-step isn't load-bearing there yet).
contract ConfigureRolesScript is Script {
    function run(address _rebaseToken, address _vault, address _admin, address _pauser, address _unpauser) public {
        RebaseToken token = RebaseToken(_rebaseToken);
        Vault vault = Vault(payable(_vault));

        vm.startBroadcast();
        token.grantRole(Roles.PAUSER_ROLE, _pauser);
        token.grantRole(Roles.UNPAUSER_ROLE, _unpauser);
        token.grantRole(Roles.RATE_ADMIN_ROLE, _admin);
        vault.grantRole(Roles.PAUSER_ROLE, _pauser);

        // Two-step admin handover on the token: start here, `_admin` must call
        // acceptAdminTransfer() itself to complete it.
        token.beginAdminTransfer(_admin);

        // Vault admin handover: single-step, then renounce.
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), _admin);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender);
        vm.stopBroadcast();

        require(!vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer still has vault admin");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), _admin), "vault admin not granted");
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), msg.sender), "token admin transfer not yet accepted");
        // NOTE: token admin handover only completes (and deployer admin is revoked) once
        // `_admin` calls acceptAdminTransfer() from its own account.
    }
}
