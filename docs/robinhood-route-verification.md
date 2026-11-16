# Route and price verification — November 16, 2026

Development only. No endpoint configuration, token upgrade, deployment or role grant was broadcast. The owner explicitly approved the Robinhood USDG price-snapshot policy for development on this date. The draft ABI/protocol is now version2; no version1 core was deployed.

## Verified public sources and read-only state

- [LayerZero deployment registry](https://metadata.layerzero-api.com/v1/metadata/deployments) and [protocol deployments](https://docs.layerzero.network/v2/deployments/deployed-contracts).
- [Chainlink Base registry](https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json) and [Robinhood registry](https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json).
- Public Base and Robinhood RPC reads at blocks58165944 /115679648, plus USDG feed read at115680327. JSON evidence in this directory records exact addresses, code hashes, rounds and probe results. These are dated observations, not assumptions that defaults or implementations never change.

The deployed endpoints report Base EID30184 and Robinhood EID30416 and match their EVM networks8453/4663. Send/receive libraries and executors have code. Both send libraries support the opposite EID. Registry-identified LayerZero Labs, Twinstake (id `nethermind`), Horizen and Paxos DVNs each returned fee quotes in both directions for a20-confirmation probe. Those reads alone do not establish an application's ACL, real message execution, production finality or provider service commitment.

**Do not inherit the current default ULN configs.** At the observed blocks they require a single registry-designated dead DVN (Base `0x6498b0632f3834d7647367334838111c8c889703`, Robinhood `0x6788f52439aca6bff597d3eec2dc9a44b8fee842`). Explicit send and receive settings must be pinned for every application direction. There is no deployed Syncrate route to configure yet.

## Real-endpoint fork rehearsal

`test/fork/GoldRouteConfigurationFork.t.sol` deploys a test-only OApp probe against each actual endpoint in disposable fork memory. It sets exact peers/libraries, explicit executor configuration and a sorted3-required-DVN/no-optional-DVN profile using LayerZero Labs, Twinstake and Horizen. It reads settings back, confirms no default-library inheritance, obtains a real endpoint fee quote and executes a fee-funded local-fork send.

The3-of-3/20-confirmation profile is a **development probe**, not an approved production security/finality setting. The400000 receive-gas option is for the simple probe handler, not proof of adequate gas for full controller/token callbacks. Full-handler gas/options, source finality, service availability, limits, ownership/delegate management and operational recovery need release review. No cross-chain DVN-delivered packet was received on a real network in these tests.

Base tests use explicit historical blocks. Robinhood's public RPC rejected older state during the first full run, so its fork tests default to a fresh latest fork and still execute all checks. `ROBINHOOD_FORK_BLOCK` can pin a block when `ROBINHOOD_FORK_RPC_URL` provides the corresponding historical state. No test catches a network failure to mark itself passed or skipped. Real USDG feed staleness will fail the check rather than substitute a test price.

## USDG source and actual transfers

USDG proxy `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` reports6decimals. Its observed EIP-1967 implementation is `0x68184c449e1a8f34fa18d289737129fd27b66f8f`. [Sourcify's verified record](https://sourcify.dev/server/v2/contract/4663/0x68184c449e1a8f34fa18d289737129fd27b66f8f?fields=all) has matching creation/runtime and identifies USDG, Solidity0.8.28. A fresh RPC code hash matches that verified runtime.

Initial implementation source review confirms controlled supply, admin-authorized upgrades and dynamic administrator-set facets. The proxy resolves pause/unpause/freeze/unfreeze/wipe selectors to `0x58cab81e3d8468a0e90df8cbfacb34535e1de942`. That facet did not return a Sourcify record during this review. Full facet verification, role-holder/governance review and reward-wallet behavior remain open; implementation identity is not a complete asset audit. Pause/freeze/confiscation and issuer upgrades remain custody/liquidity risks that contract counters cannot prevent.

`test/fork/RobinhoodUSDGSnapshotFork.t.sol` uses the actual USDG proxy, Chainlink feed and endpoint on a fresh disposable Robinhood fork. It checks live positive/current USDG pricing, exact deposit balance changes and a full rejection/refund. The user balance is synthetic fork-only state; the result is delivered through a locally impersonated endpoint/peer. No issuer role, real USDG supply or live wallet was changed, and this does not prove DVN finality or all registered reward-wallet modes.

## Approved pricing implementation

Robinhood feed `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` reports USDG/USD,8decimals,86400-second listed heartbeat. The initial actual read returned0.99993517USD, not a fixed1USD. There is no USDG/USD entry among the193 public Base feed entries inspected; private/unlisted feeds are not ruled out. Gold remains on Base at `0x5213eBB69743b85644dbB6E25cdF994aFBb8cF31`.

The visitor cannot provide a custom price: request creation reads the immutable Robinhood feed, validates round/answer/timestamps and stores normalized price/round/update/observation in the exact message. Base trusts only the authenticated configured peer's code and rechecks snapshot/age/deadline bounds, then reads its local gold feed. The oracle's public view methods are arithmetic helpers, not an attestation service for arbitrary callers. No server-signing oracle or constant-peg fallback exists.

The owner-approved feed-age ceiling is24hours; request/snapshot lifetime is at most15minutes. Expired data causes atomic source failure or terminal Base rejection/refund/restoration. Already accepted outcomes remain terminal even if their acknowledgement arrives later, preserving the cancellation-race guarantees. Source price can move after observation, and market/sequencer/transport outages can delay or reject requests. Production outage monitoring, heartbeat/weekend treatment, independent review and clear frontend pending/recovery behavior are still required.

## Validation and release scope

The first pricing revision passed local formatting/build and78tests, zero failures/skips, including10new snapshot cases, two real-endpoint route checks, the real-USDG transfer check, earlier stateful invariants and Base proxy/engine/staking compatibility. The first older-state RPC failures were not hidden; the suite was rerun with fresh Robinhood forks. A subsequent treasury correction adds an explicit immutable constructor recipient and an additional validation test. Final test/build/CI results must be recorded for that final commit separately.

## Target-chain treasury correction

**Resolved November16:** the owner explicitly selected `0x42f0E74872c77939422f3c6cEb9D62984BaE5b69` for Robinhood and instructed that signer management remains with them. A later read confirms code is now deployed there. Approved deployment input is recorded in `config/robinhood-treasury.json`; it specifies the recipient without prescribing signers or threshold. Newer read-only evidence is `robinhood-treasury-control-recheck.json`; observed signer data is not application configuration or an assertion about the owner's signer arrangements. The earlier no-code observation below is historical. Treasury selection is closed. No Safe ownership, threshold or live fee setting was changed, and no further signer confirmation is requested.

The old draft reused Base treasury `0x42f0E74872c77939422f3c6cEb9D62984BaE5b69`. Read-only checks found171bytes of contract code on Base (not an EIP-7702 delegation) and no code on Robinhood. No ownership or cross-chain deployability can be inferred from a matching address alone. USDG fees must not be sent there by default. The remote constructor now requires a nonzero, non-self treasury explicitly and exposes it immutably through `FEE_RECIPIENT()`. There is no fallback to Base's address. Selecting and verifying a controlled Robinhood recipient is a deployment gate; the owner has been asked for a public target-chain address or multisig setup choice. Evidence is in `robinhood-treasury-preflight.json`. Existing Base/staking treasury configuration is unchanged.

Final local validation including this correction: **79 tests passed, zero failures/skips**, formatting and optimized build passed. Optimized runtimes are Base11923bytes, Robinhood18265 and oracle1805. The new treasury test confirms the explicit recipient and zero-address rejection; the existing payout test confirms fees go to that configured recipient. All real-endpoint, real-USDG, price/cancellation and invariant checks remain in the final run. Remote CI must verify the final corrected commit separately from the earlier78-test commit.

Remaining before a live release: finalize approved roles/security/finality/gas/limits, complete issuer/facet and independent contract review, verify legacy Base reservations/minters, build frontend + durable reorg-aware status indexing and message retry/relay recovery, decide points escrow/Robinhood eligibility separately, and rehearse complete round trips. Only then seek separate approval for exact live upgrades/deployments/role changes. Owner approval of development and the pricing policy is not production activation authorization.
