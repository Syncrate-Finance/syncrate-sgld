# SGLD on Robinhood Chain: proposed global supply architecture

> Inventory clarification, November 16: 193 is current backing, not a permanent ceiling. The completed fixed-cap upgrade is followed by the adjustable-inventory correction in [robinhood-adjustable-inventory.md](robinhood-adjustable-inventory.md). Any fixed-193 claims or deployment commands below describe the earlier candidate and are superseded for the next release.


Status: owner APPROVED this architecture for development on November 15, 2026. Phase 1 is the canonical token cap and upgrade compatibility tests. Live upgrades, deployments and role changes are NOT authorized. This document describes the complete target design; it does not imply that the cross-chain system has already been implemented.

November 16 development update: owner approved reading actual USDG/USD on Robinhood and authenticating its immutable snapshot to Base, where gold pricing remains. Feed age is capped at24hours and request lifetime at15minutes, without a constant-peg fallback. This supersedes the earlier candidate requiring both feeds on Base. See `robinhood-route-verification.md` for the current version2 implementation, live read-only evidence and remaining release gates.

## Confirmed owner requirements

- Gold backing remains the existing193troy ounces. One SGLD represents one ounce. There must be one shared issuance ceiling, not193 per network.
- Robinhood USDG minting AND redemption at launch, with the existing0.25% redemption fee and payout queue when USDG liquidity is insufficient. Existing0% mint fee retained as the design baseline.
- SGLD transfers between Base and Robinhood at launch. Fixed isolated issuance allocations were offered and the owner chose cross-chain transfers.
- Scope is SGLD. No deployment/migration of non-transferable sySGLD staking onto Robinhood, new points eligibility policy or collateral borrowing is implied.

## Verified facts and present risks

Primary sources:
- Robinhood configuration: https://docs.robinhood.com/chain/connecting/
- Canonical USDG: https://docs.robinhood.com/chain/contracts/ and https://docs.paxos.com/guides/stablecoin/usdg/mainnet
- Messaging/finality: https://docs.robinhood.com/chain/cross-chain-messaging/
- Chainlink feed guidance: https://docs.robinhood.com/chain/oracles-and-price-feeds/
- LayerZero lock/mint adapter and supported chains: https://docs.layerzero.network/v2/developers/evm/oft/quickstart

Read-only RPC snapshot in syncrate-robinhood-readonly-preflight.json confirmed Base8453 and Robinhood4663, deployed Robinhood USDG0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, Global Dollar/USDG,6decimals. Base block58107313: SGLD supply0.457522343430630543, engine cap193, reserved capacity0. These are dated observations, not promises of currently available capacity. Robinhood block115571523 verified USDG metadata/code. Public RPC endpoints are adequate for this review, not accepted production infrastructure by default.

Reviewed contract main6233193a760920c79a245547867a783654342d92. SGLDToken.mint has role control but NO token-level supply cap. SyncrateEngine enforces local totalSupply+totalReserved against reserveCap. Its confirmReservedMint clears the reservation without recording remote outstanding supply. Reusing that as foreign-mint accounting would allow capacity to be reused while remote tokens remain outstanding. cancelReservation similarly needs terminal-state safeguards in any real cross-chain protocol. A frontend supply check, shared dashboard total or an offchain keeper polling both networks cannot atomically prevent concurrent overminting.

## Recommended design: Base canonical backing, Robinhood representation

Base remains the sole canonical issuance ledger. Robinhood SGLD is a transferable1:1 representation of canonical SGLD held in a designated Base escrow. It has no independent mint authority for its local deposit engine. Only authenticated messages from the wired Base peer can create remote representations. Only verified remote burn/return instructions can release or retire escrowed canonical SGLD.

A reviewed upgrade to the existing Base SGLD implementation adds a token-level global inventory cap, initially193e18. All mint paths, including existing Base engine and the new canonical controller, must pass this cap. Preserve proxy storage layout, balances, allowances, token identity, existing staking and roles; audit every existing minter. Future inventory increases require a separately governed backing update, never a unilateral second-chain cap change. Administrative upgrades remain a governance trust assumption and need their own release approval.

Let C be canonical Base totalSupply, E the Base backing escrow balance, R Robinhood SGLD supply and I backed claims in transit. Enforce:

    C <= 193e18
    R + I <= E
    (C - E) + R + I <= C <= 193e18

Locked backing is not counted twice. SGLD in the staking vault remains part of C; sySGLD receipts do not add gold supply. Pending messages retain backing until the remote outcome is terminal. Do not mint a second independent193SGLD supply.

### USDG mint request on Robinhood

1. User approves/deposits USDG into RobinhoodMintRedeem and supplies minimum SGLD output, recipient and deadline. USDG remains held for this request, with its own unique ID and state.
2. Authenticated, finalized message reaches BaseCanonicalController. It validates origin, replay state, quote/deadline and shared capacity, then mints canonical SGLD directly into backing escrow. This immediately consumes the same193SGLD budget used by Base minting.
3. The acknowledged backing message credits Robinhood SGLD to the recipient exactly once. USDG remains in the Robinhood engine as redemption liquidity.
4. Rejection/cancellation returns USDG only after proof that no remote credit can still occur. A timeout alone never authorizes both a refund and a delayed mint. Handle failed messages, retry fees and stranded requests explicitly.

This is an asynchronous cross-chain mint. The app must show pending/confirmed/rejected states and separate network/messaging fees, not claim an instant atomic swap.

### Cross-chain transfers

Base to Robinhood locks existing SGLD and mints the corresponding remote representation after authenticated delivery. Robinhood to Base burns the remote representation and unlocks that same canonical backing after verified delivery. Transfers never replenish issuance capacity by themselves and never count escrow as additional circulating gold.

LayerZero V2 OFTAdapter/OFT is the preferred starting point, with an authenticated application/composer for USDG mint/redeem requests. Base EID30184 and Robinhood EID30416 are in LayerZero's official supported-chain list. Endpoint addresses, bidirectional DVN coverage, verification libraries, confirmations, execution options and peers still require route-level verification. Do not infer a live secure route from an EID table. Pin versions and review existing vendored LayerZero packages before choosing interfaces. Preserve/refund OFT precision dust; do not silently drop18decimal SGLD amounts or choose shared-decimal settings that overflow OFT amounts at the193SGLD maximum. If using custom256-bit amount messages, retain all authentication/replay properties.

### USDG redemption

Coordinate remote burn/escrow and canonical backing retirement through the same request state machine, with user minimum USDG output and deadline. Burn canonical backing only for a proven remote retirement; do not unlock it and pay USDG for the same claim. Pay USDG on Robinhood with the agreed0.25% fee, or record a USDG liability in a FIFO queue. Never expose queued payout funds to treasury sweeping or new discretionary withdrawals. Supply backing and stablecoin payout liabilities are separate ledgers; cap compliance alone is not solvency. Liquidity on Base does not automatically fund a Robinhood payout queue.

## Price and collateral requirements

USDG's6decimals were read onchain, but its implementation/pause/freeze/upgrade behavior still needs source review. Exact-transfer accounting, non-reentrancy, supported asset restriction and full-precision rounding are required.

A Robinhood XAU/USD feed has NOT been verified. Never copy the Base feed address onto Robinhood or use the Robinhood stock REST API as a mint oracle. The initial proposal settles quotes through the existing verified Base XAU/USD source in the canonical controller, with fresh round checks, deadlines and minimum outputs. Decide and test weekend/heartbeat policy explicitly. USDG/USD peg treatment also needs a verified feed or an explicitly accepted guarded-par policy before launch. Display quotes are indicative until canonical settlement.

## Frontend/backend structure

Retain the approved Next.js stack. Add explicit Base/Robinhood network and settlement-asset selection, correct chain-specific contracts/explorer links and USDC/USDT versus USDG decimals. Separate Base instant local mint/redeem from cross-chain pending intent flows. Show transfer fees, expected recipient, minimum output, request status, retries and claimable refunds. Personal wallet signs each transaction. The server indexes/messages read-only state; it is not a custodial signing service.

Aggregate economic supply without double-counting Base escrow. Add durable indexing/reconciliation for chain/intent/message IDs and canonical block hashes, idempotent jobs, reorg recovery and stale-data failure states. No sensitive wallet keys in app/CI. Before launch review how bridge escrow is excluded from wallet-holder points and explicitly decide whether Robinhood holders earn points. Do not silently change the current Base points rules or imply unsupported staking/LP positions are indexed.

## Implementation roadmap and acceptance

1. Approve this material contract architecture. Finish live Base role/implementation inventory, Robinhood USDG source review, oracle policy and exact messaging route/security configuration. Development approval is distinct from permission to execute a live Base upgrade, grant a minter role or deploy on Robinhood.
2. Implement token cap hardening with storage-layout/upgrade compatibility tests and a global-cap harness. No deployment yet.
3. Implement canonical escrow/controller, Robinhood representation and USDG engine with a complete asynchronous intent state machine. Test simultaneous mints, duplicate/reordered/replayed messages, cancellation/refund races, reorg/finality assumptions, bridge fees/dust, failed delivery, oracle failures and queued payout solvency.
4. Extend the app and durable status indexer. Test wallet/network/account changes, exact approvals, limits, price changes, fees and recovery. Maintain existing Base mint/redeem and sySGLD behavior.
5. Rehearse complete round trips and all failure cases on local forks/testnets. Run invariant/fuzz tests proving global cap and backing conservation across both networks, not just each contract individually. Obtain independent cross-chain/security review.
6. Only after separate owner approval: execute the reviewed Base upgrade/roles, deploy/configure both route ends paused, verify sources/peers/configuration, migrate no supply silently, then activate staged limits and monitor. No nameserver, provider billing or production financial change is authorized by this design document.

Open launch decisions: final transport and DVNs, production RPCs/indexing, oracle/peg policy, operational signer/multisig roles, quote deadlines and cancellation semantics, liquidity provisioning and incident controls. No code or deployment should pretend these are already configured.
