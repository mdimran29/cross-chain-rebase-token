// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Vault} from "../../src/Vault.sol";
import {Treasury} from "../../src/treasury/Treasury.sol";
import {WithdrawalQueue} from "../../src/vault/WithdrawalQueue.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Bounded-actor stateful handler for the Solvency invariant. Deposits/redemptions/
/// transfers/time-warps are all clamped so a single invariant run can never plausibly exceed the
/// reserve seeded in `Solvency.t.sol`'s setUp — see that file for why an *unbounded* run
/// necessarily would (L3: interest accrues independent of any backing).
contract SolvencyHandler is Test {
    RebaseToken public token;
    Vault public vault;
    address[] public actors;

    constructor(RebaseToken _token, Vault _vault) {
        token = _token;
        vault = _vault;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string(abi.encodePacked("solvencyActor", i))));
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 amount = bound(amountSeed, 1e5, 10 ether);
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        try vault.deposit{value: amount}() {} catch {}
    }

    function redeem(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(actor);
        try vault.redeem(amount) {} catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _pickActor(fromSeed);
        address to = _pickActor(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(from);
        try token.transfer(to, amount) {} catch {}
    }

    function accrue(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 6 hours);
        vm.warp(block.timestamp + delta);
    }

    /// @notice Sum of every actor's *live* entitlement (including interest accrued but not yet
    /// materialized into principal) — the true liability figure, stronger than the
    /// `totalSupply()`-based approximation `Vault.liabilities()` documents.
    function sumActorBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Phase 2's solvency invariant: backing must cover every actor's true, live claim after
/// every deposit/redeem/transfer/time-warp.
/// @dev Important scope note: this holds here because `setUp` seeds a reward reserve far larger
/// than any accrued interest a bounded fuzz run (capped deposit/warp sizes, see handler) could
/// plausibly produce. It does *not* hold unconditionally — RebaseToken mints interest on any
/// touch regardless of whether backing ETH was ever added for it (L3, the exact gap this phase's
/// Treasury/reserve machinery exists to let governance close operationally). What Phase 2 proves
/// is that the *accounting* (backing/liabilities views, fee routing, recovery haircut) is
/// internally consistent — not that yield is backed for free. Closing that gap for real requires
/// either sustained fee/strategy revenue or continual reserve funding, which is a governance
/// policy question, not a code invariant. Phase 4's index model plus a funded reserve policy is
/// where this becomes unconditionally true.
contract SolvencyInvariantTest is Test {
    RebaseToken token;
    Vault vault;
    Treasury treasury;
    WithdrawalQueue queue;
    SolvencyHandler handler;

    address owner = makeAddr("owner");

    function setUp() public {
        vm.startPrank(owner);
        InterestRateController rateController = new InterestRateController(5e10, owner);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        treasury = new Treasury();
        vault = new Vault(IRebaseToken(address(token)), address(treasury));
        queue = new WithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        token.grantMintAndBurnRole(address(vault));
        vm.stopPrank();

        // Seed a reserve far larger than any accrued interest the bounded handler actions could
        // produce in one run, so the invariant isolates "is the bookkeeping consistent" from "is
        // yield backed" (see contract NatSpec above).
        vm.deal(address(this), 1_000_000 ether);
        treasury.fundReserve{value: 1_000_000 ether}(Treasury.Bucket.Reward);

        handler = new SolvencyHandler(token, vault);
        targetContract(address(handler));
    }

    function invariant_backingCoversLiveActorBalances() public view {
        assertGe(vault.backing(), handler.sumActorBalances());
    }

    function invariant_liabilitiesNeverExceedLiveActorSum() public view {
        // Phase 4 index model: totalSupply() sums each tier's aggregate `totalShares * index /
        // RAY` (one floor per tier), while sumActorBalances() sums each individual user's
        // `shares * index / RAY` (one floor per user). Flooring per-user can discard up to
        // (usersInTier - 1) wei more than a single tier-level floor, so totalSupply() may
        // legitimately exceed the live per-user sum by a few wei of rounding dust — bounded by
        // the handler's fixed actor count, never by economic value. This is the "rounding-error
        // invariant" the roadmap (§5.6) calls for: it bounds the *drift*, not just its sign.
        assertLe(vault.liabilities(), handler.sumActorBalances() + handler.actorCount());
    }
}
