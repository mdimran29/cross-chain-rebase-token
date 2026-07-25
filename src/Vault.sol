// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRebaseToken.sol";
import {Roles} from "./libraries/Roles.sol";
import {Errors} from "./libraries/Errors.sol";

contract Vault is AccessControl, ReentrancyGuard {
    IRebaseToken public immutable i_rebaseToken;

    // Scoped independently so redemptions can keep flowing (or be halted) without
    // necessarily touching deposits, and vice versa.
    bool public depositsPaused;
    bool public redemptionsPaused;

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);
    event DepositsPausedSet(bool isPaused);
    event RedemptionsPausedSet(bool isPaused);

    modifier whenDepositsNotPaused() {
        if (depositsPaused) {
            revert Errors.Vault__DepositsPaused();
        }
        _;
    }

    modifier whenRedemptionsNotPaused() {
        if (redemptionsPaused) {
            revert Errors.Vault__RedemptionsPaused();
        }
        _;
    }

    constructor(IRebaseToken _rebaseToken) {
        i_rebaseToken = _rebaseToken;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // allows the contract to receive rewards
    receive() external payable {}

    function setDepositsPaused(bool _isPaused) external onlyRole(Roles.PAUSER_ROLE) {
        depositsPaused = _isPaused;
        emit DepositsPausedSet(_isPaused);
    }

    function setRedemptionsPaused(bool _isPaused) external onlyRole(Roles.PAUSER_ROLE) {
        redemptionsPaused = _isPaused;
        emit RedemptionsPausedSet(_isPaused);
    }

    function deposit() external payable whenDepositsNotPaused nonReentrant {
        i_rebaseToken.mint(msg.sender, msg.value, i_rebaseToken.getInterestRate());
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @dev redeems rebase token for the underlying asset
     * @param _amount the amount being redeemed
     * @notice CEI order (burn before external call) is kept as the primary defense;
     * nonReentrant is added as defense in depth on top of it.
     *
     */
    function redeem(uint256 _amount) external whenRedemptionsNotPaused nonReentrant {
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }
        i_rebaseToken.burn(msg.sender, _amount);
        // executes redeem of the underlying asset
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            revert Errors.Vault__RedeemFailed();
        }
        emit Redeem(msg.sender, _amount);
    }
}
