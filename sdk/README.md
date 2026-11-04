# Local reference client and replay

`index.mjs` prepares explicit contract calls for a caller-selected node. `replay.mjs` reconstructs a small set of discovery and accounting projections from canonical logs. These are local reference adapters for the [implementation acceptance workflow](../script/local/README.md), not a deployed application, hosted indexer, or cross-node execution/aggregation service.

Generate `abi.json` from the current compiled contracts with `pnpm abi`. The bundle identifies its interface version; regenerate it after contract interface changes. Node 22+ and the repository's pinned `viem` dependency are required.

## Naming and interface compatibility

The current interface is `sooth-factory-v0.1.0`. Its bundle exports only `ManualAdjudicator` among adjudicators. This repository ships that demo and test sample with its shared `AdjudicatorBase`. Any other adjudicator must implement `IAdjudicator` and meet the [resolution and admission specification](../docs/factory-and-authority.md#resolution-and-network-admission). `sdk/calls.mjs` holds the token-admission helpers.

`configureMarket` and market creation reject a deadline of zero or more than `MAX_MARKET_DURATION` ahead.

The AMM pays sellers directly in the trade transaction. The complete node request uses `SOOTH_FACTORY_NODE_REQUEST_V3`. Native `split`/`merge`, independently owned YES/NO balances and reservations, standing book policies, bounded tick cancellation and surplus venue identity remain. The SDK and ABI must match the selected release. `abiDigest` and `buildDigest` in [`abi.json`](abi.json) identify the exported interface and compiled metadata/runtimes. The release manifest authenticates the interface version and keccak256 hash of the exact bundle bytes alongside the compiler artifacts, so changing bundle exports changes a future release commitment even when the interface label stays the same. Use the runtime verifier to authenticate those commitments and deployed code.

The first successful proposal leaves `isTradingOpen` and `isLiquidityOpen` false, including after a veto. `isLive()` is the compatibility predicate (`state == LIVE` at or after `startTime`) and is not a trading or liquidity gate. `inspectMarket` reads `isTradingOpen` and `isLiquidityOpen` and does not call `isLive()`. An early-resolution profile may propose before the deadline. That proposal closes trading for the rest of the market. Profile-specific proof and timing requirements remain in the [resolution and admission specification](../docs/factory-and-authority.md#resolution-and-network-admission); the current SDK does not supply oracle encoders.

Naming is `MarketFactory` for markets and `NodeFactory` for nodes. Creation retains operator autonomy, separate AMM and book vaults, and equal-token support.

### Maker interface

`prepareBookOrder(client, node, market, request)` requires an account, explicit `action: 'BUY' | 'SELL'`, `outcome: 'YES' | 'NO'`, `priceTick` of that named outcome, and WAD `amount`. It encodes `placeOrder(market, OrderParams)`. `OrderParams` also carries bounded `matchLimit`, on-chain `validUntil`, resting `expiry` (zero selects the market's trading deadline), `rest`, `postOnly`, `maxTokenIn` and `minTokenOut`. `OrderResult` reports filled WAD quantity, remainder order ID, native input/output and aggregate fee. `simulatePreparedOrder` returns that exact result for the simulated state after any necessary approval.

`prepareSplit(client, node, market, account, amount, options)` and `prepareMerge(...)` prepare native complete-set conversion. Quantities must align to `shareUnit()`. Split defaults to its exact collateral input; merge defaults to its exact collateral output and checks that both outcomes are available. Merge remains available after trading closes. The [accounting specification](../docs/fee-accounting-and-same-token.md#inventory-backing-and-native-rounding) owns conversion, partial-fill rounding and settlement rules.

`getBookInventory` pins reads to one block and returns `yesOwned`, `noOwned`, `yesReserved`, `noReserved`, `cashReserved`, `yesAvailable`, `noAvailable`, derived `net` and `invalidHalfNativeUnit`. The last field is a fractional INVALID-settlement carry (zero or one half of a native unit), never spendable native cash by itself. A zero net never implies zero holdings. Wallet cash is a separate ERC-20 read. `prepareCancelById` is the canonical cancellation route and checks the exact order's market identity. The tick convenience helper `prepareCancel` scans at most 32 caller-owned IDs. A successful transaction can report `cancelledOrderId=0` while only advancing its cursor. Consumers must inspect `MakerCancelProgress` and `OrderCancelled`; success alone does not prove cancellation. Further calls continue from the saved cursor.

Outcome encoding is `NO=0, YES=1`; action is `BUY=0, SELL=1`; normalized book direction is `BID=0, ASK=1`. BID prices descend and ASK prices ascend on the YES-price axis. Do not reuse an old YES/NO depth reader based on matching selectors alone.

## Trust boundary

Select the chain, factory, node ID and release ID from a source your application trusts, then call `verifyNode`. It checks the active factory record and the node's immutable wiring/runtime continuity. Source-artifact verification is a separate step implemented by [`script/verify-runtime.mjs`](../script/verify-runtime.mjs). A working getter or approved release label alone is not a source audit or a production resolver guarantee.

Prepared objects are trusted, in-process outputs of this adapter. Keep them unchanged until submission. **`validatePrepared` checks freshness and lifecycle; it does not authenticate arbitrary remote payloads or decode and validate a caller-substituted transaction/approval.** Rebuild locally from trusted inputs after crossing a serialization, network or plugin boundary. Applications accepting external requests need their own schema, signer, destination and calldata validation.

Use a trusted RPC and verify receipts after submission. Off-chain validation cannot prevent state changes between the last read and transaction inclusion.

## Preparing and submitting

1. Obtain a verified node and inspect the intended market. Instrument identity includes chain, factory, node, market and venue. Identical token addresses or question text do not merge markets or permissions.
2. Prepare the intended action. Display its token, spender, native-token budget, fee policy and expiry to the signer.
3. Send `approvalTransaction(prepared)` if needed. It requests only the prepared amount and the selected venue's spender. Follow any admitted token's required zero-first approval procedure when replacing an existing allowance.
4. The application calls `validatePrepared` immediately before external signing, then submits its returned transaction. The SDK has no signing path and does not invoke this check automatically for an external wallet. A rejection requires deliberate refresh and review of the new terms; never silently replace a sponsor's quote/state hash.
5. Confirm the actual receipt and reconcile transfers/events. Revoke unused allowances when the application no longer needs them.

The SDK emits no unlimited approval. Existing allowances and token-specific approval behavior remain the application's responsibility. Equal AMM/CLOB collateral still requires separate AMM and book spender approvals.

## Action semantics

| Action | Protection and limitations |
| --- | --- |
| Market creation | The admitted caller is the bootstrap payer and initial LP owner under the [factory commitment rules](../docs/factory-and-authority.md#atomic-market-creation-and-snapshots); initial funding, both registrations and LP mint occur in the creation transaction. The caller supplies a finite native-token budget, future opening/deadline, opening odds, depth and explicit resolution terms. Preparation captures both fee versions/hashes, the frozen profile and timeout buffer. Contract validation enforces those snapshots and the funding maximum. A predicted address is provisional: another creation by the same creator can change its nonce before inclusion. Use the emitted `MarketCreated` address as authoritative. |
| Sponsor addition | The quote binds native input, minimum WAD receipt units, exact quoted odds, deadline and pricing-state hash. These bounds are enforced on chain. An intervening trade or addition can invalidate the quote, including a small trade inside an otherwise acceptable odds band. This trades inclusion reliability for protection of the accepted entry state. |
| AMM sell | Direct `tradePositions` calls pay the seller exactly in the same transaction. The return, `PositionTraded.cost` and minimum-proceeds bound remain WAD amounts; each sell's native payout rounds down separately. `presentAmmSellProceeds` presents cash and the market-retained fraction. A failed or inexact transfer reverts the entire trade. Zero native proceeds move no tokens. |
| BUY order | Acquires the named outcome without automatically merging opposite inventory. `bookDebitBound` gives a conservative finite native-input ceiling including fee and rounding headroom; it is not an expected fill. Resting cash belongs to this order. Price, submission expiry, resting expiry, matching work and cash bounds are enforced on chain. |
| SELL order | Sells only available inventory of the named outcome. A resting sell reserves those shares and needs no extra principal. The default `maxTokenIn=0` rejects dust sales whose fee exceeds proceeds; callers can deliberately select another finite bound. Simulation displays exact native results. See [maker rules](../docs/economics-and-hardening.md#closing-and-quote-maintenance). |
| Split/merge | Split funds two owned outcome balances with exact collateral. Merge burns only available pairs; reserved shares must first be cancelled. Neither conversion charges a trading fee. |
| Head maintenance | `prepareHeadMaintenance` prepares 1–1024 spent/expired-entry steps for an identity-checked tick, even after trading closes. Expired orders release inventory or refund cash. Estimate gas, submit, verify the receipt and retry the quote. It neither broadcasts automatically nor removes live unexpired blockers. |
| Cancellation | `prepareCancelById` identifies one exact order and preserves node/market checks after trading or listing closes. It does not promise that the order is still active when mined. The bounded tick helper may require repeated progress calls. |

`rest=true` permits an eligible remainder to rest; it does not guarantee placement. Exhausting `matchLimit` discards the unfilled remainder, and remainders below the minimum resting size do not rest. Self-crossing cancels the existing maker order and releases its reservation. Reconcile the returned `filled` and `orderId` with receipts under the [canonical maker rules](../docs/economics-and-hardening.md#closing-and-quote-maintenance).

Depth, prices, position shares, contribution WAD and floor-payout WAD use 18-decimal accounting. Approvals, token debits, fee liabilities and fee payments use each token's native precision. In `LPProceedsClaimed`, convert `floorPaid` from WAD before adding native `feesPaid`; `redeemedWad` is a recorded entitlement, not an additional transfer.

Resolution source quality, service funding, commercial maker profitability, and sponsor renewal value require the separate [economic and release evidence](../docs/economics-and-hardening.md). ManualAdjudicator in the local workflow is a demo fixture.

## AMM fee presentation

`getAmmFeePresentation(client, node, market, feeWad)` pins the market's config and collateral reads to one block and presents effective amounts for an entered WAD fee. `presentAmmConfig(config, { decimals, feeWad })` supplies the same pure calculation for a config already obtained from a trusted source. The operator chooses CAPITAL from zero through 100% in the allocation vector under the [canonical fee policy](../docs/fee-accounting-and-same-token.md#amm); there is no separate growth switch or opt-in.

The AMM trading rate accepts 0–10,000 bps without a separate node ceiling. At 10,000 bps, the existing presentation disclosure states that buys cost twice the pre-fee base amount before native rounding and sells return zero net proceeds; a positive minimum output rejects those sells. This describes the accepted fee behavior, separately from whether those fees are retained as CAPITAL or allocated to vault beneficiaries. Book fee ceilings remain part of the standing book policy.

The result separates engine-local `capitalWad` and `conversionRemainderWad` from `vaultRevenueNative`, `lpNative`, `resolutionNative` and `operatorNative`. It also reports `nominalOperatorNative`, `operatorSplitRemainderNative` and a mandatory rounding disclosure: OPERATOR receives the integer split remainder even when its nominal allocation is zero. At 100% CAPITAL the entire entered fee is retained as `capitalWad`, all vault allocations and conversion remainder are zero, and the presentation uses no zero denominator. Its disclosure explicitly identifies that branch. The helper presents allocation of an entered fee; it does not quote a trade, authorize a config or label retained capital as withdrawable fee income. The bundle's `capabilities.fullCapital` describes interface support; it is not a permission gate.

`presentAmmSellProceeds(proceedsWad, decimals)` separately converts a sell quote's `netAmount`, return value or `PositionTraded.cost` into `payoutNative`, `paidWad` and `retainedInMarketWad`. The [canonical rounding rule](../docs/fee-accounting-and-same-token.md#amm) keeps that last fraction in market principal and LP accounting, with no seller claim or new beneficiary. Do not aggregate WAD proceeds before converting several sells: payout rounding occurs for each trade. This helper presents a supplied amount; it does not prepare or submit a trade. `capabilities.directAmmSellPayout` identifies this behavior.

## Replay scope

`NodeReplay(chainId, factories, { releaseIds })` requires explicit approved release IDs and consumes an ordered, canonical block stream from the selected factories, including empty blocks between observations. The caller authenticates that release selection against the source/runtime evidence. It checks parent continuity, deduplicates repeated blocks, rejects duplicate/mismatched logs, and rebuilds after a replacement branch rooted in a known block. An unknown parent requires caller-driven resynchronization. This is a reference projection, not a consensus verifier or an automatic finalized-head/reorg subscription service.

The projections cover node/market identity, CLOB gross and reserved inventory, derived net, resting orders and exact cash reservations, node-scoped deferred payouts, per-venue fee receipts/liabilities/payments, LP receipt balances/supply, sponsor contributions and floor payouts. `InventoryChanged` is authoritative for ownership; `OrderFilled` carries remaining quantity and cash reserve so consumers do not duplicate contract rounding. `InvalidRemainderChanged` updates the separate `invalidRemainders` half-native-unit map; settlement may leave reserved shares and a fractional carry, and a merge does not erase that carry. Per-block reconciliation requires order reservations to match account snapshots.

AMM `PositionTraded` sells project `ammSellPaidNative` by instrument/token/seller and `ammSellRetainedWad` by instrument/token using the collateral decimals from `MarketCreated`. Both convert each sell separately. The latter is cumulative retained-at-sale rounding, not a current liability or a seller entitlement; subsequent trading and LP exits can change market principal. Missing market collateral history rejects the block. The local workflow independently compares the payout projection to same-transaction ERC-20 transfers and harness balance deltas at six and eighteen decimals.

For each transaction, market, collateral and actual payer, summed `OrderExecuted.fee` must match book-vault `RevenueDeposited`. The immediately following `FeeDistributed` events must allocate each receipt completely. Their RESOLUTION component projects the original payer's conditional refund without recalculating config arithmetic. `bookRefundState(node, market, payer)` returns the vault-finalization mode, `refundableNative` matching the contract view, and `claimableNative`. Before book-vault finalization the amount is contingent; timeout finalization enables payer claims and adjudicated finalization disables them, including adjudicated INVALID. Refund claims decrement only their original payer. The truth contract settling alone does not finalize the vault projection. Reorgs rebuild the receipts, distributions, modes and payments together.

`SurplusSwept` must identify the emitter's venue; its separate `surplusSwept` projection includes factory, node, venue, vault, token and recipient and never changes fee liabilities. Instrument keys remain chain/factory/node/market/venue; asset ledger keys additionally include token. Unknown events are ignored. Full resolution evidence, LP entitlement valuation, hosted book depth, token admission, persistent checkpoints, pagination and cross-node aggregation are outside this adapter. Rebuilding the full stored history is suitable for the local transcript, not a production indexing performance claim.

Delisting filters discovery results; it does not delete identity or disable direct contract exits. The local client workflow compares replayed fee liabilities, payer refund views, gross/reserved/net inventory, INVALID carry and LP balances with live contract reads after settlement and claims.

## Verification

Run `pnpm test:client` after a matching contract build and ABI export. The [local runner](../script/local/README.md) exercises real SDK sponsor, maker, cancellation and claim transactions, then replays their receipts and checks deployed runtime artifacts. Its market creation transactions are produced by the Solidity harness; this does not establish a live SDK creation flow or a production frontend/indexer deployment.
