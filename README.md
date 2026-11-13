# Syncrate SGLD contracts

## Proposed staking v1 — not deployed or independently audited

`src/SGLDStaking.sol` is a separate, non-upgradeable staking vault **and** the ERC-20 sySGLD receipt token at the same address. It does not upgrade SGLDToken or SyncrateEngine and needs no SGLD minting role.

### Owner-confirmed rules

- Minimum deposit: **1 SGLD** (18 decimals).
- Exactly **30 or 90 days** per deposit; each deposit has a separate position.
- Mint exactly one sySGLD per SGLD deposited. Receipts cannot be transferred, including through allowances. There is no public receipt burn function.
- Only the position owner may exit, at or after maturity. V1 exits complete positions; partial exits are not implemented.
- Burn the corresponding sySGLD and return SGLD principal. The withdrawal accepts a bounded list of settled reward epochs to pay accrued yield in the same transaction. Passing an empty list permits principal exit without waiting for rewards.
- Both terms receive the same principal-time weighting, with earning eligibility ending at maturity even if principal remains in the vault.
- `restake` rolls a complete matured principal into a new 30/90-day position without a token round trip. The old position is closed, its receipts burned, and new receipts minted 1:1. A gap between terms earns no yield. Rewards do not automatically compound.
- Yield is paid in **existing SGLD supplied by treasury**. Old positions retain separate rights to late interest after withdrawal or restaking.

### Cash interest and treasury funding

1. Treasury receives counterparty interest offchain and reconciles its earning period.
2. Treasury converts that payment into backed SGLD through the established mint/purchase process, subject to existing reserve and backing controls. The vault never mints SGLD to manufacture yield.
3. The authorized funder creates a historical epoch, approves a precise SGLD amount and calls `fundEpoch` after epoch weighting is finalized.
4. The contract measures the exact SGLD transfer received and reserves it for that epoch's participants. A direct token donation creates neither receipts nor rewards.

Onchain funding proves that SGLD arrived, not that bank interest was actually received or that physical gold is present. Earning-period selection and offchain reconciliation remain treasury responsibilities. No fixed APY or minimum yield is promised by the contract.

### Exact historical allocation

Epochs are contiguous half-open intervals `[start,end)`, starting at deployment time, ending no later than the current block, with a maximum 90-day length. Treasury chooses suitable accounting cutoffs and splits longer periods. Funding may arrive much later and may be added to an existing epoch repeatedly. Do not attribute late cash to the current epoch merely because it arrived then: use the actual earning period.

For each immutable position:

`weight = principal × max(0, min(maturity, epochEnd) − max(openedAt, epochStart))`

Anyone may run `processEpoch` in batches of **1–100 positions**. All eligibility is calculated onchain. The position-count snapshot at epoch creation includes every possible past participant; a later deposit cannot gain a historical entitlement. Closed positions remain in the calculation. Funding is disabled until the entire snapshot is processed, and zero-weight epochs cannot receive funds.

`entitlement = floor(cumulativeEpochFunding × positionWeight / totalEpochWeight)`

Claims pay entitlement minus the amount previously claimed. Duplicate epoch IDs do not pay twice. Funding an epoch again makes only the incremental entitlement claimable. Rewards can be claimed after the relevant position matures, independently of whether principal has been withdrawn. Claims accept at most **32 epochs** per call; larger histories require multiple calls.

Per-transaction gas is bounded, but aggregate work per epoch is O(all positions existing at its creation), including historical ones. Operators must monitor keeper cost as positions grow; this intentionally simple v1 is not an indefinitely scalable checkpoint/indexer design. A permissionless keeper must complete processing before funding, and a treasury operator must actually submit funding. Nothing runs automatically merely because time passes.

### Solvency and administrative policy

- `totalSupply() == totalPrincipal`: sySGLD represents principal only, not a growing ERC-4626 share price.
- `SGLD balance >= totalPrincipal + rewardReserve` before and after value-moving actions.
- Principal and funded-yield liabilities are separate even though both use SGLD.
- Direct donations and integer rounding dust remain in custody. There is deliberately no sweep/recovery function for SGLD, principal or rewards; do not send unsupported assets to this contract.
- Rounding is down at the position entitlement level; cumulative funding avoids repeated independent-rounding allocations. Residual dust is reserved and is not treasury-withdrawable.
- `FUNDER_ROLE` creates/funds epochs; it cannot change positions or steal principal. `PAUSER_ROLE` pauses new stakes/restakes. Only the default admin can unpause and manage roles.
- Default admin transfer uses OpenZeppelin's two-step acceptance with a **two-day initial delay**. Use reviewed multisig addresses for production. This contract has no proxy/upgrade mechanism.
- Pausing deposits does not block matured exits, claims, epoch processing or reward funding. An underlying SGLD pause or incompatible future upgrade can still prevent token transfers. Such a revert rolls the staking state back atomically.
- All outgoing and incoming token transfers must move the exact amount. Fee-on-transfer/rebasing behavior is unsupported. SGLD remains an external, upgradeable dependency that must be verified before deployment.
- Principal is capped at `uint192.max`, and epoch duration at 90 days, to bound principal-second arithmetic safely. The cap is vastly above the expected supply; it is not a reserve-cap policy.

### Public interface

| Action | Purpose |
| --- | --- |
| `stake(amount, termDays)` | Exact SGLD transfer, new position, 1:1 receipt mint |
| `withdraw(positionId, epochIds)` | Matured complete principal exit plus chosen funded yields |
| `restake(positionId, termDays)` | New term for matured principal, preserving old yield claims |
| `claim(positionId, epochIds)` | Funded yield, including late payments after principal exit |
| `createEpoch(end)` | Funder creates the next elapsed accounting period |
| `processEpoch(epochId, maxPositions)` | Permissionless deterministic weighting, at most 100 positions |
| `fundEpoch(epochId, amount)` | Funder transfers existing SGLD into a finalized epoch |
| `claimable(positionId, epochId)` | Funded entitlement available after position maturity |
| `positions`, `epochs`, counts, `positionWeight` | Indexable history and reconciliation |

Position and epoch IDs start at zero. Frontends/indexers should use `Staked`, `Withdrawn`, `Restaked`, `EpochCreated`, `EpochProgress`, `YieldFunded` and `YieldClaimed` events, and confirm results against coherent contract reads. The staking address is also the sySGLD token address.

### Frontend work still required

The live staking page remains disabled and is not connected by this change. Wire the verified ABI, exact approvals, simulations, wallet/network guards, signing lifecycle, positions, claims, restaking and minimum deposit after testnet acceptance. Its provisional sySGLD market-cap adapter expects ERC-4626 `asset()`/`convertToAssets()` and **must be replaced** for this receipt model. Do not publish an address into that adapter and assume compatibility.

Historical trailing-30-day yield must use earning-period data, not the day cash is injected. APY requires explicitly documented compounding/annualization assumptions; actual distributions do not auto-compound. No invented history, forecast or guaranteed rate belongs in the chart.

## Build and verification

Solidity compiler: **0.8.30**, Cancun EVM, optimizer 200 runs. The repository contains vendored libraries; `foundry.lock` and `.gitmodules` also describe upstream dependencies. Preserve the reviewed library contents rather than silently updating them.

```sh
forge fmt --check
forge build --sizes
forge test -vvv
```

The new suite covers exact receipts, both terms, minimums, ownership/lock bypass, historical weighting, eligibility ending at maturity, restaking gaps, late funding after exit, additive funding and duplicate claims, deposit pause, unauthorized funding, epoch constraints, bounded processing/snapshot completeness, direct donations, transfer-fee rejection, reentrancy and the existing SGLD UUPS-proxy interface/underlying pause. Fuzz tests independently calculate allocations and check rounding conservation. Stateful invariants check receipt/principal equality and funded solvency across deposits, time advances, settlement, exits and claims.

Production deployment, actual Base proxy/ABI verification, treasury/multisig configuration, independent security review, testnet/fork lifecycle acceptance and operational funding monitoring remain release gates. No deployment or privileged transaction is authorized by these instructions.
