// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Roles} from "./libraries/Roles.sol";
import {Errors} from "./libraries/Errors.sol";
import {InterestRateController} from "./interest/InterestRateController.sol";

/*
* @title RebaseToken
* @author Ciara Nightingale
* @notice This is a cross-chain rebase token that incentivises users to deposit into a vault and gain interest in rewards.
* @notice The interest rate in the smart contract can only decrease
* @notice Each will user will have their own interest rate that is the global interest rate at the time of depositing.
*/
/// @dev Phase 4 (Interest Model v2): balances are computed via a **bucketed share-index** model
/// (roadmap §5.3 Approach B) instead of the original per-user lazy-linear formula. Each distinct
/// governed rate tier owns a monotonically increasing `index`; a user's balance is
/// `shares × index[tier] / RAY`. This keeps the product's differentiating feature — genuinely
/// per-user rates, preserved cross-chain — while gaining the index model's precision and
/// path-independence (no more "balance depends on how often you were touched").
/// Rate *policy* itself now lives in `InterestRateController` (§5.8); the token only asks it for
/// "the rate a new depositor gets right now" and otherwise deals purely in tiers/shares/indices.
/// @dev Accounting note: OZ's `ERC20` base is used *only* for `name`/`symbol`/`decimals` and the
/// `allowance` bookkeeping (`approve`, `transferFrom`'s allowance-spend) — never for balances.
/// `super._balances`/`super._totalSupply` are never written; `balanceOf`, `totalSupply`,
/// `transfer` and `transferFrom` are fully overridden to operate on `shares × index` instead.
/// Feeding OZ's ledger raw token amounts while also computing balances from shares would let the
/// two silently diverge (OZ's ledger never grows, the share view does) — this is the exact bug an
/// earlier draft of this contract hit under `test/RebaseToken.t.sol`'s long-duration fuzz case.
contract RebaseToken is ERC20, AccessControl, Pausable {
    /////////////////////
    // Types
    /////////////////////

    /// @notice Per-user accrual state, packed into a single storage slot.
    /// @dev `shares` at RAY-scale for an 18-decimal token comfortably fits `uint128` (max
    /// ~3.4e38) for any realistic supply. `tierId` indexes into `s_tiers`; `uint16` bounds it far
    /// above the enforced `MAX_TIERS` cap.
    struct Checkpoint {
        uint128 shares;
        uint16 tierId;
        bool initialized;
    }

    /// @notice One rate bucket. `index` is RAY-precision (1e27) "tokens per share" and only ever
    /// increases; `rate` is the same 1e18-scaled per-second rate the original design used, so
    /// `index_new = index_old * (1e18 + rate * dt) / 1e18` is exactly the old per-user linear
    /// growth formula applied at the tier level instead of per-user (see differential test).
    /// `totalShares` is this tier's own share supply, needed to compute `totalSupply()` as
    /// `Σ tier.totalShares * tier.index / RAY` across tiers with different indices.
    struct Tier {
        uint256 rate;
        uint256 index;
        uint256 lastUpdated;
        uint256 totalShares;
    }

    /////////////////////
    // State Variables
    /////////////////////

    uint256 private constant PRECISION_FACTOR = 1e18; // rate/time fixed-point precision (unchanged from v1)
    uint256 private constant RAY = 1e27; // index storage precision

    /// @notice Hard cap on the number of distinct rate tiers that may ever exist, so unbounded
    /// bridge-in/reconciliation rate values can never grow storage or gas unboundedly (Phase 4
    /// design decision: new rates always *snap down* to an existing tier rather than minting a
    /// fresh one, except when governance itself lowers the global rate).
    uint16 public constant MAX_TIERS = 64;

    Tier[] private s_tiers;
    mapping(address => Checkpoint) private s_checkpoints;

    InterestRateController public immutable interestRateController;

    address private s_pendingAdmin; // two-step DEFAULT_ADMIN_ROLE handover target
    address private s_currentAdmin; // tracks the sole admin so acceptAdminTransfer can revoke it on handover

    /////////////////////
    // Events
    /////////////////////
    event InterestRateSet(uint256 newInterestRate);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferAccepted(address indexed previousAdmin, address indexed newAdmin);
    event TierCreated(uint16 indexed tierId, uint256 rate);
    event IndexUpdated(uint16 indexed tierId, uint256 rate, uint256 newIndex);
    event InterestAccrued(address indexed user, uint256 fromBalance, uint256 toBalance, uint256 amount);

    /////////////////////
    // Constructor
    /////////////////////

    constructor(address _interestRateController) ERC20("RebaseToken", "RBT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        s_currentAdmin = msg.sender;

        interestRateController = InterestRateController(_interestRateController);
        // Seed tier 0 at whatever rate the controller starts with, so the very first depositor
        // has a tier to join without a separate bootstrap step.
        s_tiers.push(
            Tier({rate: interestRateController.currentRate(), index: RAY, lastUpdated: block.timestamp, totalShares: 0})
        );
        emit TierCreated(0, s_tiers[0].rate);
    }

    /////////////////////
    // Functions
    /////////////////////

    /**
     * @dev grants the mint and burn role to an address. This is only called by a protocol admin.
     * @param _address the address to grant the role to
     *
     */
    function grantMintAndBurnRole(address _address) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(Roles.MINT_AND_BURN_ROLE, _address);
    }

    /// @notice Read-only view of the current DEFAULT_ADMIN_ROLE holder.
    /// @dev Exists solely so CCIP's `RegistryModuleOwnerCustom.registerAdminViaOwner` (the
    /// version currently live on Sepolia predates `registerAccessControlDefaultAdmin`) can
    /// verify the caller's authority. Not `Ownable` — there is no `onlyOwner` or
    /// `transferOwnership`; admin changes only happen via beginAdminTransfer/acceptAdminTransfer.
    function owner() external view returns (address) {
        return s_currentAdmin;
    }

    /// @notice Pauses minting, burning and transfers. Fast, single-signer authority.
    /// @dev Reads (balanceOf, getInterestRate, etc.) remain callable while paused.
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the token. Deliberately gated behind a separate, slower role than pause()
    /// so a single compromised/careless PAUSER cannot both freeze and immediately unfreeze the token.
    function unpause() external onlyRole(Roles.UNPAUSER_ROLE) {
        _unpause();
    }

    /// @notice Begins a two-step handover of DEFAULT_ADMIN_ROLE to `_newAdmin`.
    /// @dev Step 1 of 2. The transfer only completes once `_newAdmin` calls `acceptAdminTransfer`,
    /// which prevents a fat-fingered address from bricking protocol admin permanently.
    function beginAdminTransfer(address _newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_pendingAdmin = _newAdmin;
        emit AdminTransferStarted(msg.sender, _newAdmin);
    }

    /// @notice Completes the two-step admin handover. Must be called by the pending admin.
    /// @dev Grants DEFAULT_ADMIN_ROLE to the caller and revokes it from the previous sole caller
    /// of `beginAdminTransfer`. Assumes a single current admin, consistent with deployment flow.
    function acceptAdminTransfer() external {
        address pendingAdmin = s_pendingAdmin;
        if (pendingAdmin == address(0)) {
            revert Errors.NoPendingAdminTransfer();
        }
        if (msg.sender != pendingAdmin) {
            revert Errors.NotPendingAdmin(msg.sender, pendingAdmin);
        }
        address previousAdmin = s_currentAdmin;
        delete s_pendingAdmin;
        s_currentAdmin = pendingAdmin;
        _grantRole(DEFAULT_ADMIN_ROLE, pendingAdmin);
        if (previousAdmin != address(0) && previousAdmin != pendingAdmin) {
            _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        }
        emit AdminTransferAccepted(previousAdmin, pendingAdmin);
    }

    /**
     * @notice Set the interest rate in the contract
     * @param _newInterestRate The new interest rate to set
     * @dev The interest rate can only decrease. Opens (or reuses) a tier at the new rate so
     * future deposits/bridge-ins can join it; existing holders are unaffected until they touch.
     */
    function setInterestRate(uint256 _newInterestRate) external onlyRole(Roles.RATE_ADMIN_ROLE) {
        interestRateController.setRate(_newInterestRate);
        _getOrCreateTier(_newInterestRate);
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @dev returns the principal balance of the user — the underlying share count expressed in
     * tokens at the tier's index as of the user's last touch (i.e. without further extrapolating
     * time since then). Kept for interface parity with v1's `principalBalanceOf`.
     * @param _user the address of the user
     * @return the principal balance of the user
     *
     */
    function principalBalanceOf(address _user) external view returns (uint256) {
        Checkpoint memory cp = s_checkpoints[_user];
        if (!cp.initialized || cp.shares == 0) return 0;
        Tier memory tier = s_tiers[cp.tierId];
        return Math.mulDiv(cp.shares, tier.index, RAY);
    }

    /// @notice Mints new tokens for a given address. Called when a user either deposits or bridges tokens to this chain.
    /// @param _to The address to mint the tokens to.
    /// @param _value The number of tokens to mint.
    /// @param _userInterestRate The interest rate of the user. This is either the contract interest rate if the user is depositing or the user's interest rate from the source token if the user is bridging.
    /// @dev this function increases the total supply.
    /// @dev L10 fix (unchanged in spirit): a bridge-in can carry a stale, higher historical rate
    /// from before the source chain's global rate decreased. Clamping to the current controller
    /// rate first, then to the user's own existing rate if they already hold a balance, means
    /// minting can never *raise* a user's entitlement above what the "rate only decreases" policy
    /// currently allows. The clamped rate is then snapped down to the nearest existing tier
    /// (bounded storage — see `MAX_TIERS`), so a bridged rate that doesn't exactly match a local
    /// tier joins the closest tier at or below it rather than minting a brand-new one.
    function mint(address _to, uint256 _value, uint256 _userInterestRate)
        public
        onlyRole(Roles.MINT_AND_BURN_ROLE)
        whenNotPaused
    {
        uint256 fromBalance = balanceOf(_to);
        _accrue(_to);

        uint256 globalRate = interestRateController.currentRate();
        uint256 clampedRate = _userInterestRate > globalRate ? globalRate : _userInterestRate;

        Checkpoint storage cp = s_checkpoints[_to];
        uint16 targetTierId;
        if (cp.shares == 0) {
            targetTierId = _tierAtOrBelow(clampedRate);
        } else {
            uint256 existingRate = s_tiers[cp.tierId].rate;
            uint256 effectiveRate = clampedRate < existingRate ? clampedRate : existingRate;
            targetTierId = _tierAtOrBelow(effectiveRate);
        }

        // If reconciliation moved the recipient to a different tier than the one they already
        // hold shares in, migrate the existing shares' *value* across first — minting new shares
        // into `targetTierId` without doing this would silently orphan the old tier's shares
        // (they'd remain in storage but stop being reachable, since `cp.tierId` only points at
        // one tier at a time). This is the same value-preserving tier-crossing logic
        // `_transferShares` already uses for a funded recipient.
        if (cp.shares != 0 && cp.tierId != targetTierId) {
            _moveAllSharesToTier(_to, targetTierId);
        }

        _mintShares(_to, targetTierId, _value);

        emit Transfer(address(0), _to, _value);
        emit InterestAccrued(_to, fromBalance, balanceOf(_to), 0);
    }

    /// @dev Converts `_user`'s entire share balance from their current tier into an equal
    /// *value* of shares in `newTierId`, at the respective tiers' current indices. Used whenever
    /// an operation resolves to a tier different from the one a nonzero-balance user already
    /// holds — never silently drops value by leaving shares stranded in the old tier.
    function _moveAllSharesToTier(address _user, uint16 newTierId) private {
        Checkpoint storage cp = s_checkpoints[_user];
        uint16 oldTierId = cp.tierId;
        if (oldTierId == newTierId || cp.shares == 0) return;

        Tier storage oldTier = s_tiers[oldTierId];
        uint256 value = Math.mulDiv(cp.shares, oldTier.index, RAY);
        oldTier.totalShares -= cp.shares;

        Tier storage newTier = s_tiers[newTierId];
        uint256 newShares = Math.mulDiv(value, RAY, newTier.index);
        newTier.totalShares += newShares;

        cp.shares = uint128(newShares);
        cp.tierId = newTierId;
    }

    /// @notice Burns tokens from the sender.
    /// @param _from The address to burn the tokens from.
    /// @param _value The number of tokens to be burned
    /// @dev this function decreases the total supply.
    function burn(address _from, uint256 _value) public onlyRole(Roles.MINT_AND_BURN_ROLE) whenNotPaused {
        uint256 fromBalance = balanceOf(_from);
        _accrue(_from);

        _burnShares(_from, _value);

        emit Transfer(_from, address(0), _value);
        emit InterestAccrued(_from, fromBalance, balanceOf(_from), 0);
    }

    /**
     * @dev calculates the balance of the user, which is the shares held converted through their
     * tier's index, extrapolated forward to the current time — no state write, no per-user touch
     * required (the index-model's core precision/path-independence win over v1).
     * @param _user the user for which the balance is being calculated
     * @return the total balance of the user
     *
     */
    function balanceOf(address _user) public view override returns (uint256) {
        Checkpoint memory cp = s_checkpoints[_user];
        if (!cp.initialized || cp.shares == 0) return 0;
        uint256 projectedIndex = _projectIndex(s_tiers[cp.tierId]);
        return Math.mulDiv(cp.shares, projectedIndex, RAY);
    }

    /// @notice Total token supply across every tier, each projected to the current time.
    /// @dev Overridden because the OZ base ledger is never written (see contract-level dev note);
    /// this is the only correct source of truth, summing `tier.totalShares * projectedIndex / RAY`
    /// per tier rather than relying on OZ's `_totalSupply`.
    function totalSupply() public view override returns (uint256 total) {
        uint256 len = s_tiers.length;
        for (uint256 i = 0; i < len; i++) {
            Tier memory tier = s_tiers[i];
            if (tier.totalShares == 0) continue;
            total += Math.mulDiv(tier.totalShares, _projectIndex(tier), RAY);
        }
    }

    /**
     * @dev transfers tokens from the sender to the recipient. This function also mints any accrued interest since the last time the user's balance was updated.
     * @param _recipient the address of the recipient
     * @param _amount the amount of tokens to transfer
     * @return true if the transfer was successful
     *
     */
    function transfer(address _recipient, uint256 _amount) public override whenNotPaused returns (bool) {
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        _transferShares(msg.sender, _recipient, _amount);
        emit Transfer(msg.sender, _recipient, _amount);
        return true;
    }

    /**
     * @dev transfers tokens from the sender to the recipient. This function also mints any accrued interest since the last time the user's balance was updated.
     * @param _sender the address of the sender
     * @param _recipient the address of the recipient
     * @param _amount the amount of tokens to transfer
     * @return true if the transfer was successful
     *
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount)
        public
        override
        whenNotPaused
        returns (bool)
    {
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }
        _spendAllowance(_sender, msg.sender, _amount);
        _transferShares(_sender, _recipient, _amount);
        emit Transfer(_sender, _recipient, _amount);
        return true;
    }

    /// @dev Shared transfer-accounting path: accrues both parties' tiers, moves the recipient
    /// into the sender's tier if the recipient is currently empty (mirrors v1's "only adopt a
    /// rate if you don't already have tokens" rule — you can't force someone else's rate on a
    /// funded account), then moves shares tier-for-tier (same tier, so this never needs an
    /// index conversion) or converts across tiers if the recipient already belongs to a
    /// different one.
    function _transferShares(address _from, address _to, uint256 _amount) private {
        uint256 fromBalanceBefore = balanceOf(_from);
        uint256 toBalanceBefore = balanceOf(_to);
        _accrue(_from);
        _accrue(_to);

        Checkpoint storage fromCp = s_checkpoints[_from];
        Tier storage fromTier = s_tiers[fromCp.tierId];
        uint256 moveShares = Math.mulDiv(_amount, RAY, fromTier.index, Math.Rounding.Ceil);
        if (moveShares > fromCp.shares) moveShares = fromCp.shares;
        fromCp.shares -= uint128(moveShares);
        fromTier.totalShares -= moveShares;

        Checkpoint storage toCp = s_checkpoints[_to];
        if (toCp.shares == 0) {
            // Recipient is empty (or new): adopt the sender's tier outright, exactly like v1
            // adopted the sender's rate for a zero-balance recipient.
            if (!toCp.initialized) toCp.initialized = true;
            toCp.tierId = fromCp.tierId;
            s_tiers[fromCp.tierId].totalShares += moveShares;
            toCp.shares += uint128(moveShares);
        } else {
            // Recipient already holds a balance in some tier: value-convert the moved amount
            // into their tier's shares at the current index, rather than reassigning their tier
            // (mirrors v1 never lowering/raising an already-funded recipient's rate on transfer).
            Tier storage toTier = s_tiers[toCp.tierId];
            uint256 toShares = Math.mulDiv(_amount, RAY, toTier.index);
            toTier.totalShares += toShares;
            toCp.shares += uint128(toShares);
        }

        emit InterestAccrued(_from, fromBalanceBefore, balanceOf(_from), 0);
        emit InterestAccrued(_to, toBalanceBefore, balanceOf(_to), 0);
    }

    /// @dev Writes the tier's accrued index to storage (if time has passed) — the moment where
    /// "virtual" interest becomes real, analogous to v1's `_mintAccruedInterest` but operating on
    /// the shared tier index rather than a per-user principal.
    function _accrue(address _user) private {
        Checkpoint storage cp = s_checkpoints[_user];
        if (!cp.initialized) {
            cp.initialized = true;
            cp.tierId = 0;
            return;
        }
        _accrueTier(cp.tierId);
    }

    function _accrueTier(uint16 tierId) private {
        Tier storage tier = s_tiers[tierId];
        if (block.timestamp == tier.lastUpdated) return;
        tier.index = _projectIndex(tier);
        tier.lastUpdated = block.timestamp;
        emit IndexUpdated(tierId, tier.rate, tier.index);
    }

    /// @dev `index_new = index_old * (1e18 + rate * dt) / 1e18` — the same linear-growth factor
    /// v1 applied per-user, now applied once per tier regardless of how many users share it.
    function _projectIndex(Tier memory tier) private view returns (uint256) {
        uint256 dt = block.timestamp - tier.lastUpdated;
        if (dt == 0) return tier.index;
        uint256 growthFactor = PRECISION_FACTOR + tier.rate * dt;
        return Math.mulDiv(tier.index, growthFactor, PRECISION_FACTOR);
    }

    function _mintShares(address _to, uint16 tierId, uint256 _value) private {
        Checkpoint storage cp = s_checkpoints[_to];
        cp.initialized = true;
        cp.tierId = tierId;
        Tier storage tier = s_tiers[tierId];
        uint256 newShares = Math.mulDiv(_value, RAY, tier.index);
        cp.shares += uint128(newShares);
        tier.totalShares += newShares;
    }

    function _burnShares(address _from, uint256 _value) private {
        Checkpoint storage cp = s_checkpoints[_from];
        Tier storage tier = s_tiers[cp.tierId];
        uint256 burnShares = Math.mulDiv(_value, RAY, tier.index, Math.Rounding.Ceil); // round up: never let dust survive a full burn
        if (burnShares > cp.shares) burnShares = cp.shares;
        cp.shares -= uint128(burnShares);
        tier.totalShares -= burnShares;
    }

    /// @dev Finds the highest-rate *existing* tier whose rate is `<= rate` — never creates a new
    /// tier. New tiers are opened exclusively by governance via `setInterestRate`
    /// (`_getOrCreateTier`); mint-time reconciliation always snaps down to what already exists,
    /// which is what keeps `MAX_TIERS` a hard bound regardless of how many distinct bridged/
    /// merged rate values are ever presented. Tier 0 (rate 0 is impossible since the controller's
    /// initial rate seeds it, and rate only decreases from there — but as a floor, tier 0 is
    /// always `<= rate` for any `rate >= 0`) guarantees this never fails to find a match.
    function _tierAtOrBelow(uint256 rate) private view returns (uint16) {
        uint256 len = s_tiers.length;
        uint16 best = 0;
        uint256 bestRate = s_tiers[0].rate;
        bool found = false;
        for (uint256 i = 0; i < len; i++) {
            uint256 tierRate = s_tiers[i].rate;
            if (tierRate <= rate && (!found || tierRate > bestRate)) {
                best = uint16(i);
                bestRate = tierRate;
                found = true;
            }
        }
        if (found) return best;
        // Every existing tier's rate is above `rate` (e.g. a stale bridged rate lower than any
        // local tier has ever gone) — fall back to the lowest-rate tier, the most conservative
        // choice available without minting a new one.
        uint16 lowest = 0;
        uint256 lowestRate = s_tiers[0].rate;
        for (uint256 i = 1; i < len; i++) {
            if (s_tiers[i].rate < lowestRate) {
                lowest = uint16(i);
                lowestRate = s_tiers[i].rate;
            }
        }
        return lowest;
    }

    function _getOrCreateTier(uint256 rate) private returns (uint16) {
        uint256 len = s_tiers.length;
        for (uint256 i = 0; i < len; i++) {
            if (s_tiers[i].rate == rate) {
                return uint16(i);
            }
        }
        return _createTier(rate);
    }

    function _createTier(uint256 rate) private returns (uint16) {
        if (s_tiers.length >= MAX_TIERS) {
            revert Errors.RebaseToken__TierCapExceeded(MAX_TIERS);
        }
        uint16 tierId = uint16(s_tiers.length);
        s_tiers.push(Tier({rate: rate, index: RAY, lastUpdated: block.timestamp, totalShares: 0}));
        emit TierCreated(tierId, rate);
        return tierId;
    }

    /**
     * @dev returns the global interest rate of the token for future depositors, sourced from the
     * externalized `InterestRateController` (roadmap §5.8).
     * @return the current controller rate
     *
     */
    function getInterestRate() external view returns (uint256) {
        return interestRateController.currentRate();
    }

    /**
     * @dev returns the interest rate of the user's current tier.
     * @param _user the address of the user
     * @return the tier rate the user is currently earning
     *
     */
    function getUserInterestRate(address _user) external view returns (uint256) {
        Checkpoint memory cp = s_checkpoints[_user];
        if (!cp.initialized) return 0;
        return s_tiers[cp.tierId].rate;
    }

    /// @notice Number of distinct rate tiers created so far (bounded by `MAX_TIERS`).
    function tierCount() external view returns (uint256) {
        return s_tiers.length;
    }

    /// @notice Read a tier's current stored state (rate, index as of `lastUpdated`, timestamp).
    /// @dev Returns the *stored* index, not projected forward to `block.timestamp` — call
    /// `balanceOf` for a live-projected user balance.
    function getTier(uint16 tierId) external view returns (uint256 rate, uint256 index, uint256 lastUpdated) {
        Tier memory tier = s_tiers[tierId];
        return (tier.rate, tier.index, tier.lastUpdated);
    }

    /// @notice Which tier `_user` currently belongs to.
    function getUserTier(address _user) external view returns (uint16) {
        return s_checkpoints[_user].tierId;
    }
}
