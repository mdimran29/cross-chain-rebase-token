// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shape for a future yield-generating strategy the Vault could deploy idle ETH into.
/// Not wired up in Phase 2 — the reward-reserve model in Treasury satisfies backing without a
/// live strategy. Exists now so `Vault.backing()` has an extension point that doesn't require a
/// storage-layout change later.
interface IStrategy {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function totalAssets() external view returns (uint256);
    function harvest() external returns (uint256 harvested);
}
