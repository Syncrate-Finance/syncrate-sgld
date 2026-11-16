# Paused deployment candidate

> Inventory clarification, November 16: 193 is current backing, not a permanent ceiling. The completed fixed-cap upgrade is followed by the adjustable-inventory correction in [robinhood-adjustable-inventory.md](robinhood-adjustable-inventory.md). Any fixed-193 claims or deployment commands below describe the earlier candidate and are superseded for the next release.


This package prepares the owner-selected Base/Robinhood deployment. It does not authorize or perform a live deployment, token upgrade, minter grant or activation. All rehearsals are disposable fork tests. Actual new addresses are unknown until confirmed deployment receipts; addresses printed by dry runs are predictions, not deployed contracts.

## Confirmed public inputs

Owner selected `0x9C8671eC3e032BbDb0A9B7577468763dc553DA40` for administration and LayerZero delegation on both chains. The existing encrypted-keystore deployer is that same address. Robinhood fee recipient is `0x42f0E74872c77939422f3c6cEb9D62984BaE5b69`. Signer/threshold management stays with the owner; no treasury owner checks or changes are performed by these scripts. `config/robinhood-paused-deployment.json` records the public inputs and inactive initial state.

The canonical supply cap remains193SGLD. No independently mintable193SGLD Robinhood allocation is created.

## Three deployment stages and a separate upgrade

| Stage | Script/action | Effect |
| --- | --- | --- |
| A | `script/crosschain/DeployCanonicalCap.s.sol:DeployCanonicalCap` | Creates the capped implementation only; checks current Base asset/admin/legacy implementation and zero legacy reservations. Prints a runtime hash and proposed atomic upgrade calldata. It does not upgrade the proxy. |
| B | Separately reviewed owner `upgradeToAndCall` | Future live action, outside these scripts. Must atomically initialize cap version5; preserve all balances/allowances/roles. Do not take implementation addresses from rehearsal logs. |
| C | `script/crosschain/DeployBaseGoldController.s.sol:DeployBaseGoldController` | Requires the verified actual capped implementation address/hash and initialized193cap. Creates gold oracle and paused Base controller. No peer, minter role or entry limits are configured. |
| D | `script/crosschain/DeployRobinhoodGold.s.sol:DeployRobinhoodGold` | Checks Robinhood chain, actual USDG implementation/runtime/symbol/decimals, feed identity and selected treasury deployment. Creates a paused, zero-supply gateway with no peer. |

Base scripts reject unexpected token identity/admin, nonzero legacy reservations and wrong network. Remote script rejects changes to the reviewed USDG implementation/runtime and wrong network. These checks are deliberate stops for review, not automatic migration or reservation cancellation. Existing mainnet staking is already deployed and is not recreated by this package.

Scripts contain `vm.startBroadcast` to describe the signer and recorded transactions. Foundry does not send them unless the operator explicitly requests broadcasting. The agent ran only `forge test`; it did not use `--broadcast`, a key or a keystore. Scripts never read a private key/password. Future approved live signing remains in the owner's Foundry terminal with the encrypted keystore. Do not rerun a creation stage after it has a successful live receipt.

### Local rehearsal

Pinned Foundry1.7.1 / Solidity0.8.30, Cancun, optimizer200:

```sh
forge fmt --check
forge build --sizes
forge test --match-contract GoldDeploymentRehearsalTest -vv
forge test -vv
```

Base fork tests use the recorded historical blocks. Public Robinhood tests use fresh latest state; pin `ROBINHOOD_FORK_BLOCK` only with an RPC providing that history. Public endpoints can fail or throttle. Failures are never converted into skipped/passing checks.

The Base rehearsal creates the implementation, verifies the real proxy was not upgraded by that script, then impersonates the admin to perform the separate upgrade **inside fork memory**. It uses the actual candidate address/runtime hash through public environment inputs `SGLD_CAPPED_IMPLEMENTATION` and `SGLD_CAPPED_RUNTIME_HASH`, runs the controller script and checks paused/unconfigured state and delegate. A later test-only activation measures the cold handler against actual Base token/gold-feed code. The Robinhood rehearsal runs the actual script and checks paused state, selected admin/delegate/treasury and zero supply/liabilities. No rehearsal address or synthetic balance is usable as a live deployment record.

For optional read-only CLI simulation of Stage A or D, run the corresponding script with the matching RPC and `--sender` set to the confirmed deployer, without `--broadcast`. Stage C cannot be simulated against today's uncapped live proxy until the separately reviewed upgrade has occurred; use the full fork rehearsal for that sequence now. Only after approval and actual receipts may verified deployment addresses/hash replace the public environment inputs for Stage C. No example command in this guide sends a transaction.

## Staged exposure limits

The new Base controller starts with zero limits and cannot unpause until a positive profile is explicitly configured. No production rollout amounts were selected automatically. `configureExposureLimits(perOperation, outstanding, capacityPerDay)` is owner-only and requires pause. Values are raw18-decimal SGLD, nonzero and bounded by193SGLD; per-operation amount cannot exceed outstanding or bucket capacity.

- Per-operation cap applies to direct Base bridge locks and canonically accepted Robinhood mints.
- Outstanding cap counts all recorded remote backing, including in-flight claims.
- A token bucket refills gradually at capacity/24hours. There is no calendar-midnight reset burst. Successful new mint/lock consumes allowance; failed transfer/mint does not. Refundable rejection consumes no budget.
- Raising/lowering the profile never grants a fresh burst: available tokens are clipped to the new capacity, preserving spent allowance. After an increase, additional allowance accrues over time.
- Bridge returns, accepted redemptions, refunds, existing credits and payouts retain their existing paths; they do not require entry capacity. Exits do not refill the entry bucket. Lowering outstanding cap below already locked backing blocks new exposure without confiscating or locking exits.

The limits are operational controls on this controller, not an alternative to the token-level193cap or an assurance against malicious privileged token upgrades. Existing Base minting is not throttled by this new controller's bucket.

## Handler gas evidence

Cold application-handler tests forward1million gas and require measured use below900000. Observed examples: Base accepted mint411937, Base redemption349726, cancellation270963, remote mint result116723, redemption queue176191, bridge credit104324, Base bridge return105760, token restoration111636. The real Base token/gold-feed rehearsal observed408953 for its mint handler. These are local test observations, not exact future costs.

The candidate Type3 executor receive option is1.5million gas with zero native value. Real endpoint fee-quote/local-fork-send tests run with that option on both networks. This includes margin above tested application paths, but transport/executor overhead, fees, source finality, relayer availability, production state changes and independent review still need release acceptance. The3-DVN/20-confirmation probe profile remains a development example, not owner approval of production finality. No actual DVN-delivered cross-chain packet was demonstrated.

## Activation is separate

Validation on November16: formatting and optimized build passed; the complete local suite passed **97 tests, zero failed/skipped**. This includes10exposure-limit tests,5cold-handler gas tests,3deployment-script rehearsals, both real-endpoint option/fee tests and all earlier conservation/pricing/asset/staking checks. Current optimized runtimes: Base controller12786bytes, Robinhood18265 and oracle1805, below EIP-170. These measurements and local test success are separate from remote CI and independent review. Final source hashes/CI results belong to the exact pushed candidate commit.

All deployment stages leave gateways paused with no peers, security wiring, minter grant or positive rollout limits. No unpause, USDG funding, mint, bridge, redemption or staking transaction appears in the deployment scripts. Zero peer/role/limits are intentional initial state, not missing defaults to be filled automatically.

Before later activation, record confirmed receipts/verified sources and exact runtime/configuration hashes; verify all existing minters/reservations; review and set explicit send/receive libraries, DVNs, confirmations, executor/options and peers on both ends (never inherit the current dead-DVN defaults); grant only the necessary canonical minter role; approve positive rollout values; complete issuer/facet and independent review; and rehearse complete recovery paths. Frontend/indexer/relay recovery and explicit points escrow/Robinhood eligibility policy remain required. The existing frontend historical-points RPC CI gate is also still unresolved. The package does not claim launch readiness or silently waive these items.
