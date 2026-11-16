# Adjustable inventory and correction deployment

193 SGLD represents today's bullion-backed mintable supply, not a permanent ceiling. Base is the sole global issuance authority. The global invariant is `canonical supply <= current inventory cap`; remote supply plus in-flight claims equals the Base controller's backing liability, which cannot exceed canonical supply. Locked canonical backing is not counted twice.

## Current live state and correction

Owner deployed fixed-cap implementation `0x7A930a4B191A6e88281681380426C821C5d0B19E` in Base transaction `0x6d166f7117dbe61f118dc9dcacb71bf87330eff57d2442d0067cfc2104be5414`, then upgraded the existing proxy in transaction `0x4f56d269440774171207f8bf28695dc9f5e8c654851a563c17650de0f57e031d`, block 58219974. Do not repeat either completed command. The existing live cap remains 193 until a separately signed correction is confirmed.

`SGLDTokenAdjustableCap` keeps the original inheritance/storage unchanged and adds an isolated ERC7201 namespace `syncrate.storage.InventoryCap`. Atomic `upgradeToAndCall(candidate, initializeAdjustableSupplyCap())` initializes version6 with 193 SGLD. It neither increases today's inventory nor changes balances, allowances, roles, pause state, token name, symbol or decimals. Missing initialization fails closed for minting while leaving transfers/burns available.

The `MAX_CANONICAL_SUPPLY()` selector is retained for existing integrations and now reads configured inventory. Only DEFAULT_ADMIN_ROLE may call `increaseGlobalSupplyCap(newCap)`. The new value must exceed the previous value; decreases/equal values revert. An event records old/new caps. This operation does not mint. Confirming additional bullion backing is an offchain governance responsibility; no physical-inventory oracle or arbitrary remote owner mint is introduced. No increase above193 is currently approved.

## Base and Robinhood integration

Base controller deployment accepts a positive initialized canonical cap, instead of requiring193. Per-operation, outstanding backing and daily capacity settings are bounded by the current cap. An inventory increase does not automatically raise these separate operating limits. Explicit changes require the controller paused, preserve already-spent bucket allowance and never block exits.

Robinhood no longer has an independent fixed193 ceiling. Its private credit path is reachable only through the configured authenticated Base peer for backing transfers, accepted mint results or rejected redemption restorations, with existing request/replay checks unchanged. Thus an increased canonical cap cannot strand a valid remote credit or restoration. Canonical enforcement and authenticated transport remain essential; the remote gateway has no public/admin mint role. This change does not synchronize or increase the old Base engine's independent reserveCap: administrators must separately align that existing engine's inventory policy when new backing arrives.

## Signing sequence

1. Deploy the new implementation only using `script/crosschain/DeployAdjustableCap.s.sol:DeployAdjustableCap`. This script checks chain, administrator, current fixed implementation/runtime, initialized193cap, supply and engine reservations. It never upgrades, changes a cap, grants a role or activates a gateway.
2. Verify the actual creation receipt and runtime hash. Do not use simulation-predicted addresses as live inputs.
3. Prepare and separately sign the atomic version6 proxy upgrade using that verified implementation. Recheck current state immediately before signing. Preserve cap193.
4. Verify version6/current cap and unchanged ledger/roles, then deploy the Base controller and Robinhood gateway from this revised source and continue authenticated route configuration.

No signing password/key is read by scripts. Operator signs locally through an encrypted Foundry alias. Temporary paused setup remains; RH minting is intended to be public when the functional frontend goes live. USDG reservation during asynchronous settlement remains required.

## Validation and remaining release work

Tests cover fixed-version5 migration, state and role preservation, permission failures, missing/repeated initialization, increases without minting, all-minter cap enforcement, maximum arithmetic boundaries and fuzzed cap/amounts. Cross-chain cases exercise issuance beyond193, remote supply beyond193, rejected redemption restoration above193, bridge returns, refundability at the new cap, dynamic exposure configuration and unchanged budget after inventory increases. Conservation invariants now include randomized inventory increases.

Disposable Base fork tests exercise the actually deployed fixed implementation at block58219974. Fork-only test increases to250/300/1000 are examples, never production settings. Final test/CI results belong to the exact candidate commit. Source verification and tests are not an external audit. Transport security/finality/options/peers, selected positive operating limits, issuer review, recovery and frontend integration remain separate release work. No real DVN round trip is claimed.
