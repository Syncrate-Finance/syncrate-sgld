# Robinhood SGLD: development contract core

This is phase 2 development under the owner-approved Base-canonical design. It is **not deployed, independently audited or configured as a live route**. The cap upgrade remains a candidate, not a live upgrade. No existing Base token, engine, staking contract or frontend was changed by this phase.

## Contracts and accounting

| Contract | Responsibility |
| --- | --- |
| `BaseGoldController` | Holds canonical SGLD backing, locks/unlocks bridge transfers, and is the single terminal authority for USDG mint/redemption requests. |
| `RobinhoodGold` | Remote 18-decimal SGLD ERC-20 and USDG request/payout ledger in one contract. Has no public/owner mint or arbitrary burn role. |
| `GoldMailbox` | Uses the existing vendored LayerZero V2 OApp's endpoint/peer authentication. Persistent outbox, fee quotes, permissionless dispatch/retry, version checks and payload deduplication. |
| `GoldSettlementOracle` | Candidate Base settlement adapter requiring both XAU/USD and USDG/USD feeds. Freshness, round completeness, positive prices and decimals validation. |
| `GoldMessages` | Versioned request, terminal outcome and transfer formats using full-width uint256 token amounts. |

Base canonical supply C must stay at or below 193e18 through phase 1's token-level cap. Let E be the controller's recorded backing liability, R remote supply and I the sum of backed pending credits, returns and unsettled redemption retirements. The tested invariant is `R + I == E`, with `E <= C <= 193e18` and actual canonical escrow balance at least E. Extra tokens donated directly to escrow do not authorize remote minting. Economic supply is `(C - E) + R + I`, not the sum of both ERC-20 supplies.

The Base controller constructor requires an initialized `MAX_CANONICAL_SUPPLY() == 193e18` token. It deliberately cannot be wired against the current uncapped implementation. Each gateway starts paused and requires its peer to be bound before unpausing. Local endpoint EID is checked against constructor configuration. There are no production endpoint/peer/feed addresses populated in this implementation.

## Messaging choice and trust boundary

This implementation uses a **custom LayerZero OApp payload protocol, not stock OFT/OFTAdapter**. The approved design allowed uint256 messages as an alternative to OFT shared-decimal truncation/overflow. All 18 decimals survive transfer; no shared-decimal uint64 amounts or silent dust deductions are used. Custom token accounting and messages need independent cross-chain review; standard OApp authentication does not independently audit these application rules.

The existing LayerZero library is vendored in the repository, pinned by the parent repository tree (`lib/LayerZero-v2` tree `e511319105576fe640439c49d9916cb4b70d0a98`). No dependency upgrade was introduced. Relevant source interfaces were inspected against the vendored code and [LayerZero's OApp documentation](https://docs.layerzero.network/v2/developers/evm/oapp/overview).

Only the configured endpoint and exact remote peer can deliver. The peer may be set once, for the configured remote EID, and cannot be swapped later. Payload hashes are idempotent even when the same payload is resent under a new transport GUID. Unique operation IDs include source EID, source gateway and monotonic nonce. Conflicting requests cannot overwrite terminal outcomes. State changes and deduplication roll back together if delivery fails.

The OApp owner and endpoint delegate remain governance trust assumptions because they control pause/configuration and transport verification settings. Endpoint/DVN/library/executor/finality configuration is **not verified by these unit tests**. The test endpoint is explicitly a mock which permits adversarial duplicate and reordered delivery, not a simulated production verification network. No peer migration, arbitrary token rescue, treasury liquidity sweep or owner mint exists. Future inventory increases or route migrations need additional reviewed development; the remote cap is fixed at 193 SGLD for this release.

## USDG mint

1. `requestMint(amount, minOutput, deadline, recipient)` takes exact USDG, protects it in `pendingUSDG`, records the request and queues a message. It does not immediately mint SGLD.
2. Anyone pays the source messaging fee with `dispatch(messageId, options)`. `quoteDispatch` supplies the endpoint fee quote. Dispatch only sends a previously committed payload.
3. Base checks the immutable request content, deadline, current oracle quote, minimum output and shared token cap. Acceptance mints canonical SGLD directly into escrow and records backing. Failure produces a terminal rejection; no remote credit has been authorized.
4. Base queues the immutable result. A separate fee-funded dispatch delivers it to Robinhood. Acceptance releases the USDG reservation into local redemption liquidity and mints the exact backed remote amount. Rejection moves the deposit to protected `refundableUSDG`.
5. Only the original depositor can call `claimRefund` and select the refund address. A failed/frozen/taxed transfer rolls back the claim, preserving its reservation.

No automatic keeper or response funding service is delivered here. Either user/operator may dispatch a stored message; this needs frontend/status-indexer/keeper integration before launch. Native transport fees are distinct from USDG collateral. Execution options must fund adequate receive gas and use zero native-value drop; replies use a separate dispatch and incoming native value is rejected.

Base pause stops all new oracle settlement decisions, including redemptions, so a suspected pricing incident can be contained. It leaves already terminal replies, bridge returns and cancellation outcomes available. Remote pause blocks new mints/bridge sends while allowing existing result delivery, redemption requests, refunds and allocated payout claims. If Base pricing is paused, a pending redemption can await recovery or request terminal cancellation after its deadline; it never restores tokens just because time passed.

## Cancellation and delayed messages

After the deadline the requester can queue `requestCancellation(id)`. This alone neither refunds USDG nor restores burned remote SGLD. Base decides the terminal outcome:

- Cancellation first: records rejection and prevents an original request arriving later from minting/burning backing.
- Original accepted first: cancellation cannot undo that outcome. The same accepted response remains dispatchable even after the deadline.
- Original expired/rejected first: the rejection stays terminal.

Each response includes the exact original request hash. There is no timeout-only refund, operator override of an accepted request, or refund plus delayed mint path. A disconnected or misconfigured transport can delay completion; it cannot be bypassed by an offchain timeout. Recovery/retry operations and incident procedures must be rehearsed on a real verified route before launch.

## Transfers

Base to Robinhood: `bridgeToRobinhood` takes exact canonical SGLD, increases backing liability, and queues an exact remote credit. Robinhood to Base: `bridgeToBase` burns the caller's remote SGLD and queues a release of its existing canonical backing. No canonical supply is minted or burned by an ordinary transfer. No independent remote minter is granted. Gateway destination addresses are rejected so users cannot deposit into a gateway through its own bridge path.

## USDG redemption and fee

`requestRedemption` burns remote SGLD immediately, creating a pending retirement right. Base verifies the request, deadline and fresh quote against the user's **net USDG minimum**. Acceptance burns exactly that amount of canonical backing; rejection preserves backing and later restores the remote tokens to the original owner. A failed canonical burn rolls delivery back for retry. Remote transfers/redemptions cannot spend the same burned tokens again.

Accepted results create gross USDG liabilities in a FIFO queue in **acknowledgement arrival order**. Local Base liquidity does not pay Robinhood liabilities. `processPayouts(maxCount)` (1 to 100) allocates available USDG to queue entries without touching pending mint deposits, refunds or previously allocated payouts. An underfunded entry waits; later entries cannot jump it.

The recipient then calls `claimRedemption(id, recipient)`. It pays 99.75% of the gross USDG quote to the selected address and 0.25% to the existing treasury `0x42f0E74872c77939422f3c6cEb9D62984BaE5b69`, with integer rounding down on the fee. Only the original designated redemption recipient can redirect the claim. This pull payout prevents a frozen recipient or treasury from blocking FIFO allocation to everyone else. Failed payout transfers leave the allocated liability intact. Anyone can top up through `fundLiquidity`; there is no sweep that can remove liability funds.

`totalReservedUSDG` includes pending deposits, refundable deposits, queued payouts and allocated payouts. Queued liabilities may exceed local liquidity; pending/refund/allocated amounts must always remain fully reserved. Approval amounts, user minimum output and messaging fee presentation belong to the next frontend phase.

## Oracle and unresolved production policy

The adapter converts 6-decimal USDG and 18-decimal SGLD using full-precision integer ratios. It does not assume USDG is always worth USD 1. Gold and USDG/USD feeds must be actual verified **Base** feeds. No verified Base USDG/USD feed has been selected, so this adapter is not yet a usable production configuration. If such a feed is unavailable, a guarded-par alternative needs an explicitly approved risk policy and separate implementation/tests; never insert a constant peg or fake address silently.

The tests' USD 4000 gold, USD 1 USDG and one-day staleness bounds are **fixtures only**. Production heartbeat/weekend policy, decimal behavior, USDG freeze/pause/upgrade/source review and any sequencer-outage handling still need completion. A Robinhood XAU feed is not assumed and no Base feed address is copied onto Robinhood.

## Validation and remaining gates

Local formatting/build and the complete Foundry suite must pass. New coverage includes 18-decimal precision, send/delivery failure and retry, wrong endpoint/peer/network/value, duplicate/reordered/conflicting messages, both cancellation races, expired quotes, cap races with Base/remote minters, oracle failures/depeg, redemption rejection/restoration, 0.25% fees, FIFO liquidity shortage, protected pending/refund/allocated funds, frozen recipients, taxed collateral, reentrancy and ownership/pause restrictions.

Local validation completed November 15, 2026 (client date): **65 tests passed, zero failed/skipped**, including 29 new cross-chain tests and both existing actual Base fork tests. Each new invariant ran 128 sequences / 8192 calls with zero handler reverts; the bridge precision fuzz test ran 256 cases. Formatting and optimized build passed. Runtime sizes: Base controller 11414 bytes, Robinhood token/engine 16249, oracle 1566, all below EIP-170. All 29 imported library source files match their baseline Git blobs; no dependency changes were included. GitHub CI must be checked independently after the push. Nonfatal sandbox Foundry cache warnings and existing lint warnings are not suppressed.

Two new stateful invariants independently track pending credits, returns and retirements while fuzzing mint/redeem/bridge/cancel/delivery/top-up/claim/time/competing-minter operations. They check global economic backing and protected USDG balances. Existing actual Base token-upgrade/staking fork tests remain part of the regression suite. These local checks do not demonstrate real Robinhood deployment or DVN finality.

Before release: verify deployed USDG source and route addresses/configuration, select oracle policy and operational roles, build durable request indexing/relaying/frontend recovery, review points escrow exclusion/Robinhood eligibility separately, implement/review staged rate limits and incident controls, rehearse on real testnets/forks, obtain independent security review, and request separate owner approval for any live upgrade/deployment/role change. No mainnet operations are performed or authorized by this document.
