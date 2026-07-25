// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RebaseToken} from "../../src/RebaseToken.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";

/// @notice Re-enters `redeem` from its `receive()` hook, simulating a malicious depositor
/// trying to drain the vault via reentrancy during the ETH payout of `redeem`.
contract MaliciousRedeemer {
    Vault public immutable vault;
    bool public attacking;
    uint256 public reentrancyAttempts;

    constructor(Vault _vault) {
        vault = _vault;
    }

    function attack(uint256 amount) external payable {
        vault.deposit{value: amount}();
        attacking = true;
        vault.redeem(amount);
        attacking = false;
    }

    receive() external payable {
        if (attacking) {
            reentrancyAttempts++;
            // Try to redeem again before the first call finishes.
            vault.redeem(msg.value);
        }
    }
}

contract ReentrancyTest is Test {
    RebaseToken public rebaseToken;
    Vault public vault;
    Treasury public treasury;
    MaliciousRedeemer public attacker;

    address public owner = makeAddr("owner");
    uint256 public constant SEND_VALUE = 1e18;

    function setUp() public {
        vm.startPrank(owner);
        rebaseToken = new RebaseToken();
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(rebaseToken)), address(treasury));
        rebaseToken.grantMintAndBurnRole(address(vault));
        vm.stopPrank();

        attacker = new MaliciousRedeemer(vault);
        vm.deal(address(attacker), SEND_VALUE);
        // Fund the vault with extra ETH so a successful reentrant redeem would be
        // detectable (i.e. the vault isn't merely failing due to lack of funds).
        vm.deal(address(vault), 10 * SEND_VALUE);
    }

    function testReentrantRedeemReverts() public {
        vm.expectRevert();
        attacker.attack(SEND_VALUE);
    }

    function testReentrancyAttemptNeverSucceeds() public {
        try attacker.attack(SEND_VALUE) {
            fail();
        } catch {
            // Expected: the outer attack() call reverts because the nested redeem()
            // inside receive() reverts via the ReentrancyGuard, which bubbles up.
        }
        // No tokens should have been burned twice / no double payout occurred.
        assertEq(rebaseToken.balanceOf(address(attacker)), 0);
    }
}
