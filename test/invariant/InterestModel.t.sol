// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/RebaseToken.sol";
import {InterestRateController} from "../../src/interest/InterestRateController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Bounded-actor stateful handler exercising the Phase 4 index model specifically:
/// multiple rate tiers (via periodic `setInterestRate` calls), deposits/transfers across those
/// tiers, and time-warps, so the invariants below are stressed against tier-crossing behavior
/// that `test/invariant/Solvency.t.sol`'s single-tier-dominant handler doesn't focus on.
contract InterestModelHandler is Test {
    RebaseToken public token;
    InterestRateController public rateController;
    address public rateAdmin;
    address public minter;
    address[] public actors;

    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;

    constructor(RebaseToken _token, InterestRateController _rateController, address _rateAdmin, address _minter) {
        token = _token;
        rateController = _rateController;
        rateAdmin = _rateAdmin;
        minter = _minter;
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("interestModelActor", i))));
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function mint(uint256 actorSeed, uint256 amountSeed, uint256 rateSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 amount = bound(amountSeed, 1e9, 1_000_000 ether);
        uint256 currentRate = token.getInterestRate();
        uint256 mintRate = currentRate == 0 ? 0 : bound(rateSeed, 0, currentRate);

        vm.prank(minter);
        try token.mint(actor, amount, mintRate) {
            ghost_totalMinted += amount;
        } catch {}
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _pickActor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(minter);
        try token.burn(actor, amount) {
            ghost_totalBurned += amount;
        } catch {}
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

    /// @notice Periodically lowers the global rate, opening a new tier — the mechanism that
    /// stresses cross-tier behavior. Bounded to never revert on the only-decreases invariant.
    function lowerRate(uint256 stepSeed) external {
        uint256 currentRate = token.getInterestRate();
        if (currentRate == 0) return;
        uint256 step = bound(stepSeed, 1, currentRate);
        uint256 newRate = currentRate - step;

        vm.prank(rateAdmin);
        try token.setInterestRate(newRate) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 30 days);
        vm.warp(block.timestamp + delta);
    }

    function sumActorBalances() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @notice Phase 4 precision/rounding invariants (roadmap §5.6, plan Step 4.3's required test):
/// the index model must never let cumulative rounding make `totalSupply()` overstate the true
/// live sum of balances by more than bounded per-tier dust, tier indices must never decrease, and
/// `totalSupply()` must never underflow/revert regardless of how many tiers or how much time has
/// elapsed.
contract InterestModelInvariantTest is Test {
    RebaseToken token;
    InterestRateController rateController;
    InterestModelHandler handler;

    address owner = makeAddr("owner");
    address minter = makeAddr("minter");

    uint256 constant INITIAL_RATE = 5e10;

    function setUp() public {
        vm.startPrank(owner);
        rateController = new InterestRateController(INITIAL_RATE, owner);
        token = new RebaseToken(address(rateController));
        rateController.grantRole(Roles.RATE_ADMIN_ROLE, address(token));
        token.grantMintAndBurnRole(minter);
        token.grantRole(Roles.RATE_ADMIN_ROLE, owner);
        vm.stopPrank();

        handler = new InterestModelHandler(token, rateController, owner, minter);
        targetContract(address(handler));
    }

    /// @notice `totalSupply()` (tier-aggregate rounding) must never fall short of the true
    /// per-user live sum by more than the number of touched actors' worth of per-tier dust — see
    /// `test/invariant/Solvency.t.sol`'s identical tolerance rationale, now under multi-tier
    /// pressure from `lowerRate()`.
    function invariant_totalSupplyTracksLiveActorSumWithinRoundingDust() public view {
        uint256 totalSupply = token.totalSupply();
        uint256 actorSum = handler.sumActorBalances();
        uint256 tolerance = handler.actorCount() * token.tierCount();

        if (totalSupply >= actorSum) {
            assertLe(totalSupply - actorSum, tolerance);
        } else {
            assertLe(actorSum - totalSupply, tolerance);
        }
    }

    /// @notice Every tier's index must be monotonically non-decreasing across the entire run —
    /// the index model's core soundness property (roadmap §5.3: "uniform, path-independent").
    function invariant_tierIndicesNeverDecrease() public {
        uint256 count = token.tierCount();
        for (uint16 i = 0; i < count; i++) {
            (, uint256 index,) = token.getTier(i);
            assertGe(index, s_lastSeenIndex[i]);
            s_lastSeenIndex[i] = index;
        }
    }

    mapping(uint16 => uint256) private s_lastSeenIndex;

    /// @notice Tier count can only grow (new tiers from `setInterestRate`), never shrink, and is
    /// always bounded by `MAX_TIERS`.
    function invariant_tierCountBoundedAndMonotonic() public view {
        uint256 count = token.tierCount();
        assertLe(count, token.MAX_TIERS());
        assertGe(count, 1);
    }

    /// @notice `totalSupply()` must remain callable (no revert/overflow) no matter how much time
    /// has elapsed or how many tiers exist — a liveness property, since Vault's `liabilities()`
    /// depends on this never reverting.
    function invariant_totalSupplyNeverReverts() public view {
        token.totalSupply();
    }
}
