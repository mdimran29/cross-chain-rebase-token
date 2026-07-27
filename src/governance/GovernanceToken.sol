// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @notice Voting-weight token for RebaseGovernor. Deliberately a separate token from
/// RebaseToken rather than adding `ERC20Votes` checkpointing directly to it: RBT's balance grows
/// continuously between touches (lazy interest accrual, `balanceOf` computed on read), which is
/// fundamentally incompatible with `ERC20Votes`' checkpoint model — checkpoints only record
/// balance changes that happen via `_update` (mint/burn/transfer), so voting power read from
/// checkpoints would silently diverge from a holder's true, continuously-growing RBT balance.
/// A fixed-supply, non-rebasing token sidesteps that entirely.
/// @dev Fixed supply, minted once at deployment — no admin-gated mint surface to keep the voting
/// asset's issuance policy out of scope for this phase (a real launch would choose a genuine
/// distribution/vesting mechanism; this is the minimal scaffold Phase 3's Governor needs to
/// operate against).
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(uint256 initialSupply) ERC20("RebaseGovernance", "veRBT") ERC20Permit("RebaseGovernance") {
        _mint(msg.sender, initialSupply);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
