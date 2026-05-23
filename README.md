# Cross-Chain Rebase Token (Foundry + Chainlink CCIP)

An educational Solidity project implementing a **cross-chain rebasing token** system using **Chainlink CCIP**.

Users deposit ETH into a vault on the source chain, receive `RebaseToken` (`RBT`), accrue linear interest over time, and can bridge tokens cross-chain while carrying their user-specific interest rate metadata.

---

## Architecture

### Core contracts

- `src/RebaseToken.sol`
  - ERC20 rebasing token with per-user interest tracking.
  - Interest rate can only decrease globally.
  - Mint/burn restricted via `MINT_AND_BURN_ROLE`.

- `src/Vault.sol`
  - Accepts ETH deposits and mints `RBT` via `RebaseToken.mint`.
  - Redeems by burning `RBT` and sending ETH back.

- `src/RebaseTokenPool.sol`
  - Custom CCIP token pool built on Chainlink `TokenPool`.
  - On source chain (`lockOrBurn`): burns bridged amount and encodes user interest rate.
  - On destination chain (`releaseOrMint`): mints amount using bridged user interest rate.

### Cross-chain behavior

1. User deposits ETH in `Vault` and receives `RBT`.
2. User bridges through CCIP router.
3. Pool burns on source chain and includes interest metadata in pool data.
4. Destination pool mints to receiver with preserved user interest rate.

---

## Project layout

- `src/` — protocol contracts
- `script/` — deployment/config/bridge interaction scripts
- `test/` — unit + fork-based cross-chain tests
- `bridgeToZKsync.sh` — end-to-end shell workflow for Sepolia ↔ zkSync Sepolia
- `foundry.toml` — Foundry config and remappings

---

## Requirements

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Git
- Access to RPC URLs for fork tests (Sepolia + Arbitrum Sepolia)

Verify:

- `forge --version`
- `cast --version`

---

## Quickstart

```bash
git clone https://github.com/mdimran29/cross-chain-rebase-token.git
cd cross-chain-rebase-token

# Pull submodules used by this repo
git submodule update --init --recursive

# Install CCIP dependency expected by remappings
forge install smartcontractkit/ccip

forge build
```

---

## Configuration

### RPC endpoints

Fork tests use Foundry RPC aliases (`eth-sepolia`, `arb-sepolia`).

You can either:

- update `foundry.toml` `[rpc_endpoints]`, or
- export environment variables and adjust your local config accordingly.

### Wallet / broadcast environment (for scripts)

Typical script execution needs:

- a configured Foundry account such as `my-wallet`
- chain-specific RPC URL(s)
- LINK balances for CCIP fees where applicable

> Use test-only wallets. Never use production keys for experimentation.

To keep your key out of `.env`, import it once into Foundry's local keystore and then use `--account my-wallet` for deployments and transactions.

---

## Build, test, and quality

### Build

```bash
forge build
```

### Unit + fuzz tests

```bash
forge test
```

### Run a specific suite

```bash
forge test --match-contract RebaseTokenTest -vv
forge test --match-contract CrossChainTest -vv
```

### Coverage

```bash
forge coverage
```

### Formatting

```bash
forge fmt
```

---

## Script usage

### 1) Deploy token + pool

Script: `script/Deployer.s.sol:TokenAndPoolDeployer`

Deploys:

- `RebaseToken`
- `RebaseTokenPool`

Also configures:

- mint/burn role for pool
- token admin registration + pool registration in CCIP registries

### 2) Deploy vault

Script: `script/Deployer.s.sol:VaultDeployer`

Deploys `Vault` and grants vault mint/burn role on token.

### 3) Configure remote pool mappings

Script: `script/ConfigurePool.s.sol:ConfigurePoolScript`

Adds remote chain + remote pool/token mappings and optional rate limiter config via `applyChainUpdates`.

### 4) Bridge tokens

Script: `script/BridgeTokens.s.sol:BridgeTokensScript`

Builds CCIP message, approves LINK/token, computes CCIP fee, and sends via router.

### 5) Deposit / redeem helpers

Script: `script/Interactions.s.sol`

- `DepositScript`
- `RedeemScript`

---

## Tests included

- `test/RebaseToken.t.sol`
  - deposit/redeem flows
  - linear interest growth checks
  - transfer behavior + user interest inheritance
  - access-control and interest-rate monotonicity checks

- `test/CrossChain.t.sol`
  - Sepolia ↔ Arbitrum Sepolia fork setup via `CCIPLocalSimulatorFork`
  - bi-directional pool configuration
  - bridge all tokens / bridge back / multiple bridge scenarios

---

## Notes & assumptions

- The protocol assumes rewards/funding exist in vault liquidity for redemptions.
- Global interest rate can only move downward.
- A user’s effective rate is preserved and bridged across chains.
- This repository is educational and not audited.

---

## Sepolia deployment

The current live Sepolia deployment uses the following addresses:

- `RebaseToken`: `0x46948AC074C0a9E9734F8AEe55a41d542CdD3b19`
- `RebaseTokenPool`: `0x088659FB202C501095850b3EcBD6A3a205030E69`
- `Vault`: `0x27748128Ec88727FCc40e5d49B237c5A8c84E1ea`

---

## Acknowledgements

- [Foundry](https://getfoundry.sh/)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Chainlink CCIP](https://docs.chain.link/ccip)
- [Chainlink Local](https://github.com/smartcontractkit/chainlink-local)