# Canonical SGLD cap: development phase 1

The owner approved development of Base-canonical SGLD with a shared 193 SGLD limit, Base backing escrow, authenticated Robinhood representations, transfers and USDG mint/redemption. No live upgrade, deployment or role change is authorized by this work.

## This change

`SGLDTokenCapped` is an upgrade candidate for the existing Base proxy, not another token deployment. Every mint path passes a fixed `193e18` ceiling inside `_update`, including additional minters that might be authorized later. Burning canonical SGLD restores headroom. Transfers, locking backing and staking do not restore headroom. Remote issuance must consume escrowed canonical backing in a later phase; this cap alone is not a bridge.

The candidate inherits the existing token without adding state. The only legacy source edit marks `_update` virtual so the cap can wrap it. The existing inheritance order, namespaced library storage, roles, balances, allowances, pause behavior and upgrade authorization remain in place. This is tested on local proxies and the actual Base proxy state; it is not an independent audit or permission to upgrade.

`initializeGlobalSupplyCap()` requires the existing default admin and reinitializer version 5. The live snapshot at Base block 58110779 has initializer version 4. Intended eventual activation is an atomic admin-authorized `upgradeToAndCall` with this initializer, after separate release approval. If initialization is omitted, minting fails closed while existing transfers and burns retain their normal authorization/pause behavior. If existing supply exceeds the ceiling, initialization reverts and an atomic upgrade rolls back instead of altering holder balances. Old ticker/name reinitializers cannot run after version 5.

There is intentionally no mutable cap setter in this first implementation. Increasing backing requires a separately reviewed governance/upgrade change. The existing upgrade admin remains a trust assumption: an authorized later upgrade could change these rules.

## Read-only preflight

Observed Base block **58110779**, not a claim about every future block:

- Proxy: `0x10C5E0643bCc6C915Cad0335f70A96c1532766eb`.
- Implementation: `0x21D4dAf073A381631356513072dFD3A6372CCbE8`.
- Canonical supply: `0.457522343430630543 SGLD`.
- `0x9C8671eC3e032BbDb0A9B7577468763dc553DA40` holds default admin.
- Existing engine `0x37c0078D297243A22ac247cd93f1cafed9Dbe461` holds minter role.
- These known-address checks are **not a complete historical inventory of every role holder**. Full RoleGranted/RoleRevoked history, custody review and independent storage/security review remain release requirements.

## Validation

Pinned tools: Foundry 1.7.1, Solidity 0.8.30, Cancun, optimizer 200, existing repository dependencies unchanged.

```sh
forge fmt --check
forge build --sizes
forge test -vv
```

`BASE_FORK_RPC_URL` can override the public Base endpoint for fork tests. The cap fork is pinned at block 58110779 and requires historical reads. Tests use only Foundry's disposable in-memory fork and impersonation. They contain no broadcasting or private key access.

Coverage includes: upgrade state preservation, paused upgrade, admin checks, repeated initialization, unauthorized minting/upgrades, missing initialization, over-cap atomic rollback, exact ceiling/one-wei overflow, huge input overflow protection, secondary minter, burns/transfers, staking receipt/principal compatibility, fuzzed amounts and stateful mint/burn accounting. The Base fork also exercises the existing engine's USDC/oracle mint flow and the already deployed staking vault through deposit and matured exit after the candidate upgrade.

Local validation passed on November 15, 2026 (client date): formatting, optimized build and **36 tests**, including both Base fork tests. The new cap fuzz case ran 256 inputs; the new cap invariant ran 128 sequences / 8192 calls. Candidate runtime is 7438 bytes. Foundry cache write warnings in the sandbox are nonfatal; legacy engine lint warnings remain outside this change. GitHub CI status must be recorded separately after pushing; local success is not remote CI evidence.

## Remaining phases and release gates

1. Phase 1: canonical cap candidate and compatibility tests (this change).
2. Build authenticated escrow/representation and asynchronous USDG request state machines. Prove replay safety, message ordering, cancellation/refund safety and backing conservation across both networks.
3. Verify actual transport endpoints/DVNs/libraries/finality, production RPC/indexer, price/peg policy, quote deadlines and operational roles. Do not populate guessed addresses or enable a route using mocks.
4. Connect frontend and durable request tracking, rehearse round trips/failures, review points escrow exclusions and Robinhood eligibility separately.
5. Independent review and separate owner approval before any live upgrade, minter grant, deployment or activation.

No Robinhood token, bridge, USDG engine, application integration or live route is delivered by phase 1. Existing staking behavior and website code are not changed.
