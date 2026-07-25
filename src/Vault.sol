// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRebaseToken.sol";
import {Roles} from "./libraries/Roles.sol";
import {Errors} from "./libraries/Errors.sol";

interface ITreasuryForVault {
    function reserveBalance() external view returns (uint256);
}

/// @notice ETH on/off-ramp for RebaseToken, hardened per Phase 2 (Vault Solvency & Fees):
/// explicit backing/liabilities accounting, capped fees routed to a Treasury, guarded-launch
/// limits, a pull-based withdrawal queue for liquidity crunches, and a governance-triggered
/// recovery mode with pro-rata haircut if the vault is ever undercollateralized.
contract Vault is AccessControl, ReentrancyGuard {
    IRebaseToken public immutable i_rebaseToken;
    ITreasuryForVault public immutable i_treasury;
    address public withdrawalQueue;

    // Scoped independently so redemptions can keep flowing (or be halted) without
    // necessarily touching deposits, and vice versa.
    bool public depositsPaused;
    bool public redemptionsPaused;

    /// @notice Governance-only, redeem-only mode entered when the vault can no longer be
    /// trusted to serve deposits safely. Deposits stay blocked until `exitRecoveryMode()` — a
    /// human PAUSER cannot lift this by unpausing `depositsPaused`, since the checks are
    /// independent (see `deposit()`).
    bool public recoveryMode;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 200; // 2%
    uint256 public constant MAX_WITHDRAWAL_FEE_BPS = 200; // 2%

    uint256 public depositFeeBps;
    uint256 public withdrawalFeeBps;

    // Guarded-launch limits. Default to "unbounded" so behavior is unchanged until a deploy
    // script or governance sets real values, mirroring how Phase 0 rate limits are configured
    // externally (config/chains.json) rather than hardcoded.
    uint256 public maxDepositPerTx = type(uint256).max;
    uint256 public maxDepositPerAddress = type(uint256).max;
    uint256 public globalTvlCap = type(uint256).max;
    uint256 public minDeposit;
    /// @notice 0 disables the daily net-flow check entirely.
    uint256 public dailyNetFlowLimit;

    mapping(address => uint256) public depositedByAddress;

    uint256 private s_flowBucketStart;
    uint256 private s_flowBucketInflow;
    uint256 private s_flowBucketOutflow;

    enum FeeType {
        Deposit,
        Withdrawal
    }

    event Deposit(address indexed user, uint256 netAmount);
    event Redeem(address indexed user, uint256 netAmount);
    event RedeemQueued(address indexed user, uint256 indexed requestId, uint256 netAmount);
    event DepositsPausedSet(bool isPaused);
    event RedemptionsPausedSet(bool isPaused);
    event RecoveryModeSet(bool active);
    event FeeCharged(FeeType indexed feeType, address indexed payer, uint256 amount);
    event DepositFeeSet(uint256 bps);
    event WithdrawalFeeSet(uint256 bps);
    event MaxDepositPerTxSet(uint256 value);
    event MaxDepositPerAddressSet(uint256 value);
    event GlobalTvlCapSet(uint256 value);
    event MinDepositSet(uint256 value);
    event DailyNetFlowLimitSet(uint256 value);
    event WithdrawalQueueSet(address indexed queue);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

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

    modifier onlyQueue() {
        if (msg.sender != withdrawalQueue) revert Errors.Vault__NotQueue(msg.sender);
        _;
    }

    constructor(IRebaseToken _rebaseToken, address _treasury) {
        i_rebaseToken = _rebaseToken;
        i_treasury = ITreasuryForVault(_treasury);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // allows the contract to receive rewards
    receive() external payable {}

    /// @notice One-time wiring of the withdrawal queue. Deployed after Vault (it needs Vault's
    /// address in its own constructor), so it can't be passed into Vault's constructor without a
    /// circular dependency — set once here instead.
    function setWithdrawalQueue(address _queue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (withdrawalQueue != address(0)) revert Errors.Vault__QueueAlreadySet();
        withdrawalQueue = _queue;
        emit WithdrawalQueueSet(_queue);
    }

    function setDepositsPaused(bool _isPaused) external onlyRole(Roles.PAUSER_ROLE) {
        depositsPaused = _isPaused;
        emit DepositsPausedSet(_isPaused);
    }

    function setRedemptionsPaused(bool _isPaused) external onlyRole(Roles.PAUSER_ROLE) {
        redemptionsPaused = _isPaused;
        emit RedemptionsPausedSet(_isPaused);
    }

    /// @notice Enters redeem-only recovery mode. Deposits stay blocked until governance calls
    /// `exitRecoveryMode()` — independent of the normal pause switches, so a PAUSER cannot
    /// inadvertently (or maliciously, with a merely-compromised pauser key) reopen deposits
    /// during an active recovery.
    function enterRecoveryMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        recoveryMode = true;
        emit RecoveryModeSet(true);
    }

    function exitRecoveryMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        recoveryMode = false;
        emit RecoveryModeSet(false);
    }

    function setDepositFeeBps(uint256 _bps) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        if (_bps > MAX_DEPOSIT_FEE_BPS) revert Errors.Vault__FeeExceedsCap(_bps, MAX_DEPOSIT_FEE_BPS);
        depositFeeBps = _bps;
        emit DepositFeeSet(_bps);
    }

    function setWithdrawalFeeBps(uint256 _bps) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        if (_bps > MAX_WITHDRAWAL_FEE_BPS) revert Errors.Vault__FeeExceedsCap(_bps, MAX_WITHDRAWAL_FEE_BPS);
        withdrawalFeeBps = _bps;
        emit WithdrawalFeeSet(_bps);
    }

    function setMaxDepositPerTx(uint256 _value) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        maxDepositPerTx = _value;
        emit MaxDepositPerTxSet(_value);
    }

    function setMaxDepositPerAddress(uint256 _value) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        maxDepositPerAddress = _value;
        emit MaxDepositPerAddressSet(_value);
    }

    function setGlobalTvlCap(uint256 _value) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        globalTvlCap = _value;
        emit GlobalTvlCapSet(_value);
    }

    function setMinDeposit(uint256 _value) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        minDeposit = _value;
        emit MinDepositSet(_value);
    }

    function setDailyNetFlowLimit(uint256 _value) external onlyRole(Roles.FEE_ADMIN_ROLE) {
        dailyNetFlowLimit = _value;
        emit DailyNetFlowLimitSet(_value);
    }

    /// @notice Total ETH claim outstanding against the vault. An approximation: lazy interest
    /// accrual means a user's true `balanceOf` can exceed their minted principal until their
    /// next touch, so real liabilities are `>= totalSupply()`. Precise, checkpointed accounting
    /// arrives with the Phase 4 index model — until then this is a conservative-but-not-exact
    /// lower bound, adequate for the solvency *monitoring* this phase establishes.
    function liabilities() public view returns (uint256) {
        return i_rebaseToken.totalSupply();
    }

    /// @notice ETH actually available to back `liabilities()`: everything held directly plus
    /// whatever Treasury has explicitly committed to the reward/insurance reserves.
    function backing() public view returns (uint256) {
        return address(this).balance + i_treasury.reserveBalance();
    }

    /// @notice Backing as a fraction of liabilities, scaled by 1e18 (1e18 == fully backed).
    function reserveRatio() public view returns (uint256) {
        uint256 liab = liabilities();
        if (liab == 0) return type(uint256).max;
        return (backing() * 1e18) / liab;
    }

    /// @notice ETH immediately payable without touching amounts already earmarked for pending
    /// withdrawal-queue claims.
    function freeLiquidity() public view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 committed =
            withdrawalQueue == address(0) ? 0 : WithdrawalQueueLike(withdrawalQueue).totalPendingClaims();
        return bal > committed ? bal - committed : 0;
    }

    function deposit() external payable whenDepositsNotPaused nonReentrant {
        if (recoveryMode) revert Errors.Vault__DepositsBlockedDuringRecovery();
        if (msg.value < minDeposit) revert Errors.Vault__DepositBelowMinimum(msg.value, minDeposit);
        if (msg.value > maxDepositPerTx) revert Errors.Vault__DepositExceedsPerTxCap(msg.value, maxDepositPerTx);
        if (address(this).balance > globalTvlCap) {
            revert Errors.Vault__DepositExceedsTvlCap(address(this).balance, globalTvlCap);
        }

        uint256 fee = (msg.value * depositFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = msg.value - fee;

        uint256 newTotal = depositedByAddress[msg.sender] + netAmount;
        if (newTotal > maxDepositPerAddress) {
            revert Errors.Vault__DepositExceedsAddressCap(newTotal, maxDepositPerAddress);
        }
        depositedByAddress[msg.sender] = newTotal;

        _recordFlow(netAmount, 0);
        if (fee > 0) {
            _chargeFee(FeeType.Deposit, fee);
        }

        i_rebaseToken.mint(msg.sender, netAmount, i_rebaseToken.getInterestRate());
        emit Deposit(msg.sender, netAmount);
    }

    /// @notice Redeems rebase tokens for ETH. Serves instantly from free liquidity when
    /// possible; otherwise enqueues a pull-claimable withdrawal request. In recovery mode, an
    /// undercollateralized vault pays out pro-rata rather than reverting or paying some users in
    /// full at others' expense.
    /// @dev CEI order (burn before external effects) is kept as the primary defense; nonReentrant
    /// is added as defense in depth on top of it.
    function redeem(uint256 _amount) external whenRedemptionsNotPaused nonReentrant {
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }
        uint256 userRate = i_rebaseToken.getUserInterestRate(msg.sender);

        // Snapshot before burning: the haircut ratio must reflect liabilities/backing
        // *including* this user's own outstanding claim. Burning first would remove it from the
        // denominator and corrupt the ratio for the very redemption being processed (it can even
        // zero out liabilities entirely if this is the last holder).
        uint256 preBurnLiabilities = liabilities();
        uint256 preBurnBacking = backing();

        i_rebaseToken.burn(msg.sender, _amount);

        uint256 payableAmount = _applyRecoveryHaircut(_amount, preBurnLiabilities, preBurnBacking);

        uint256 fee = (payableAmount * withdrawalFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = payableAmount - fee;

        _recordFlow(0, netAmount);
        if (fee > 0) {
            _chargeFee(FeeType.Withdrawal, fee);
        }

        if (freeLiquidity() >= netAmount) {
            emit Redeem(msg.sender, netAmount);
            _payOut(msg.sender, netAmount);
        } else {
            if (withdrawalQueue == address(0)) revert Errors.Vault__RedeemFailed();
            uint256 requestId = WithdrawalQueueLike(withdrawalQueue).requestRedeem(msg.sender, netAmount, userRate);
            emit RedeemQueued(msg.sender, requestId, netAmount);
        }
    }

    /// @notice Pays out a claimed withdrawal-queue request. Callable only by the queue itself.
    function disburse(address to, uint256 amount) external onlyQueue nonReentrant {
        _payOut(to, amount);
    }

    /// @notice Restores a cancelled withdrawal request's RBT at its original rate snapshot.
    function restoreFromQueue(address user, uint256 amount, uint256 userRate) external onlyQueue nonReentrant {
        i_rebaseToken.mint(user, amount, userRate);
    }

    /// @notice Rescues ERC20 tokens accidentally sent to the vault. Excludes RBT by construction
    /// (only foreign tokens are ever in scope) — ETH, the vault's actual backing asset, has no
    /// rescue path at all, so it can never be swept out under this function's cover.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == address(i_rebaseToken)) revert Errors.Vault__CannotRescueProtocolAsset();
        bool success = token.transfer(to, amount);
        if (!success) revert Errors.Vault__RedeemFailed();
        emit TokenRescued(address(token), to, amount);
    }

    function _applyRecoveryHaircut(uint256 amount, uint256 liab, uint256 bak) internal view returns (uint256) {
        if (!recoveryMode) return amount;
        if (liab == 0) return amount;
        if (bak >= liab) return amount;
        return (amount * bak) / liab;
    }

    function _chargeFee(FeeType feeType, uint256 amount) internal {
        (bool success,) = payable(address(i_treasury)).call{value: amount}("");
        if (!success) revert Errors.Vault__FeeTransferFailed();
        emit FeeCharged(feeType, msg.sender, amount);
    }

    function _payOut(address to, uint256 amount) internal {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) {
            revert Errors.Vault__RedeemFailed();
        }
    }

    /// @dev Rolls the bucket forward once a day has elapsed, rather than storing one entry per
    /// historical day — keeps storage bounded, same pattern as CircuitBreaker's rolling window.
    function _recordFlow(uint256 inflow, uint256 outflow) internal {
        if (dailyNetFlowLimit == 0) return;
        if (block.timestamp >= s_flowBucketStart + 1 days) {
            s_flowBucketStart = block.timestamp;
            s_flowBucketInflow = 0;
            s_flowBucketOutflow = 0;
        }
        s_flowBucketInflow += inflow;
        s_flowBucketOutflow += outflow;
        uint256 netOutflow = s_flowBucketOutflow > s_flowBucketInflow ? s_flowBucketOutflow - s_flowBucketInflow : 0;
        if (netOutflow > dailyNetFlowLimit) {
            revert Errors.Vault__DailyNetFlowLimitExceeded(netOutflow, dailyNetFlowLimit);
        }
    }
}

interface WithdrawalQueueLike {
    function totalPendingClaims() external view returns (uint256);
    function requestRedeem(address user, uint256 amount, uint256 userRateSnapshot) external returns (uint256 requestId);
}
