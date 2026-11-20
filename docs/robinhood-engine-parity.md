# Robinhood upgradeable engine candidate

Development candidate, November 19, 2026. No contract in this package has been deployed or activated. The original paused deployments must not be connected to this replacement. The source is stacked on the adjustable-inventory release, commit `5093d7fd75529f06a44153c5a397765a18d25660`.

## Treasury proceeds

The owner requires treasury sweeping to fund physical gold inventory. `RobinhoodGoldEngine.sweepToTreasury(address token)` is DEFAULT_ADMIN-only and transfers 40% of available USDG to the configured treasury, emitting `SweptToTreasury`. Available USDG is the engine's USDG balance less pending deposits, refundable deposits, queued redemption obligations and claimable payouts, floored at zero. Only the configured USDG asset may be swept. Successful mints release their deposited USDG from the pending category after authenticated Base acceptance. The engine remains the holder and source of sweepable proceeds.

This deliberately differs from Base's 40% of total stablecoin balance: unresolved deposits and money already owed to users are excluded. Example: 4,000 settled USDG plus 1,000 pending USDG permits a 1,600 USDG sweep, leaving 3,400. Sweeping can leave insufficient liquidity for future redemptions; those redemptions queue until treasury or another funder replenishes liquidity. Sweeping does not mint SGLD or increase the gold inventory cap. Physical gold procurement and any later cap increase remain separate administrative actions.

## Contracts and administration

- `RobinhoodGoldEngine`: ERC-1967/UUPS proxy implementation with atomic initialization, locked implementation initializer, ERC-20 receipt state, separate DEFAULT_ADMIN_ROLE, RESERVE_MANAGER_ROLE and UPGRADER_ROLE identities. No local administrator mint method exists. The reserve-manager role is recorded for operational role parity; it cannot independently approve canonical issuance or refunds.
- `GoldMailboxUpgradeable`: proxy-local endpoint delegation, immutable-after-binding peer, authenticated receipt, replay protection and permissionless fee-funded outbox. Revoking the current delegate's admin role also revokes its separate Endpoint delegation. An administrator can appoint another current administrator as delegate. Future upgrades must preserve storage, including the reserved mailbox gap and OpenZeppelin namespaces. The pinned OZ 5.5 storage-based reentrancy guard is namespace-based and accepts the proxy's initial zero/not-entered state; first-call, callback and upgrade regressions cover this use.
- `BaseGoldControllerParity`: canonical escrow and settlement without discretionary entry throttles. The canonical token's adjustable inventory cap remains authoritative. Redemption requests carry a gross minimum derived from the remote engine's request-time fee snapshot; pair only with the new engine. Do not bind the old remote gateway to this controller.
- `GoldSettlementOracleManaged`: canonical Base gold pricing with validated XAU/USD feed administration and configurable staleness. Robinhood uses its own USDG/USD feed and sends authenticated price snapshots. No fictitious Robinhood XAU feed is configured.

The engine starts paused, without a peer. The initial admin/delegate, reserve-manager and upgrader may be the owner-selected address, while remaining independently grantable/revocable. A UUPS upgrader can change execution logic; that role is a governance trust boundary, not a promise that arbitrary upgrades preserve backing. A tested V2 upgrade preserves balances, pending requests, outbox delivery, roles and configuration. Implementation/proxy initialization cannot be repeated.

## Base function mapping and explicit differences

| Base capability | Candidate equivalent |
| --- | --- |
| initialize / role administration / upgradeToAndCall | Proxy `initialize(InitConfig)`; AccessControl grant/revoke/renounce; UUPS authorization restricted to UPGRADER_ROLE |
| sweepToTreasury | Same name, treasury destination and 40% rate, with the protected USDG basis described above |
| setRedeemFee | Same name, initial 25 bps, maximum 500 bps. Fee captured per request and retained through settlement, FIFO allocation and claim |
| setCollateralToken | Same name; enable/disable the verified USDG collateral. Additional assets are rejected pending asset-specific pricing and protocol review |
| setGoldPriceFeed | Managed oracle on Base; validated XAU/USD identity. Remote `setUSDGPriceFeed` validates USDG/USD instead |
| setOracleStalenessThreshold | Available on both managed gold oracle and remote USDG engine; validated positive threshold up to the protocol's 24-hour maximum |
| pause / unpause | Same names, DEFAULT_ADMIN authorization. Existing cancellation/refund/claim recovery remains possible while new risk is paused |
| mint / redeem | Same argument shape `(uint256,address)`, returns request/message IDs. Asynchronous canonical confirmation is required; no promise of synchronous token/payout delivery. Advanced request functions retain explicit slippage, expiry and recipient controls |
| processQueue | Allocates funded FIFO obligations via existing processPayouts, bounded to 100 entries. Recipient then calls claimRedemption. This is a pull payout, unlike Base's immediate push transfer, and prevents a frozen recipient blocking allocation for others |
| getQueueLength | Total payout-array length; payoutHead identifies the remaining queue, with separate queued and claimable totals |
| getCollateralValueInUsd | Managed canonical gold oracle view on Base, returns 18-decimal USD. The remote engine cannot synchronously call a Base price feed; clients must read the canonical oracle explicitly |
| reserveCap / updateReserveCap | Shared canonical token cap and `increaseGlobalSupplyCap` on Base. No independent Robinhood cap or daily/per-operation limit is added |
| reserveCapacity / confirmReservedMint / cancelReservation | Authenticated canonical intent settlement replaces manual remote reservation approval. Cancellation is a request to Base; timeout alone cannot refund while Base can still accept a mint |

These are functional mappings across the route, not a claim that all Base selectors exist on Robinhood with identical synchronous behavior. The legacy Base engine is unchanged. The remote admin does not gain unbacked mint or unilateral-refund authority to imitate a local engine API. Treasury and fee recipient remain the owner-selected address `0x42f0E74872c77939422f3c6cEb9D62984BaE5b69`.

## Validation and remaining release work

Tests cover successful mint proceeds, protected sweep categories, replenishment after sweeps, fee updates during settlement, exact integer fee/slippage inversion, role/delegate revocation, implementation/proxy initialization, storage-preserving upgrades, shared-cap races, inventory increases without local limits, repeated large mint/redemption cycles without daily throttles, forged/duplicate messages, refunds, queues, callbacks and taxed collateral.

The real Robinhood fork test uses the actual Endpoint, USDG and Chainlink feed with a new proxy. USDG balances are synthesized and authenticated delivery is impersonated only inside the disposable fork. It validates token transfer/refund/sweep behavior, not real DVN delivery or finality. Existing route forks exercise real endpoint library configuration, quoting and local sends; they are not cross-chain end-to-end execution.

Before owner signing: publish and pin exact source, inspect CI and size results, independently review the proxy/role/storage changes and fee protocol, prepare new paused deployment scripts/manifests, verify live dependencies and issuer behavior, select production DVN/finality/handler-gas settings, and rehearse exact deployments. Update treasury operations, frontend ABI/status/retry/refund/claim flows and indexing for the replacement addresses. Settle points/escrow eligibility separately. No existing constructor should be rerun and no old peer binding should be signed.
