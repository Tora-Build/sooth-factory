# Venue fees, custody, and equal collateral tokens

**Scope and authority:** this is the canonical specification for fee configuration schemas, arithmetic, custody ledgers, payment entitlements, timeout distribution, rounding, and surplus. The [factory specification](factory-and-authority.md) owns deployment, administrative capabilities, market commitments, and truth lifecycle; the [economics specification](economics-and-hardening.md) owns economic objectives and sponsor execution protections. See the [document authority map](../README.md#document-authority).

## 1. Custody and authority

The [node topology](factory-and-authority.md#topology) supplies distinct `AMMEngine`, `OrderEngine`, `AmmFeeVault`, and `BookFeeVault` custody addresses. AMM principal stays in its engine; book collateral stays in its engine; each fee vault holds only its venue's revenue. Shared truth contracts report the outcome; they do not hold or combine venue money.

Within each vault, liabilities remain keyed by `(marketId, token, bucket)` and beneficiary where applicable. The vault identity supplies the venue dimension. Instrument identity uses `(chainId, factory, nodeId, marketId, venue)`; its collateral is immutable. Monetary keys append token explicitly, and transaction presentation includes collateral and units. Public fee events identify venue/token; authenticated emitter identity identifies the vault. A token address is never used to infer venue.

Configuration calls use the administrative capabilities in the [factory role matrix](factory-and-authority.md#role-contract). The following table specifies contract-to-contract authorization and payment entitlement; an administrative role is not itself a claim on a balance.

| Action | Authorized identity | Recipient / restriction |
| --- | --- | --- |
| Register a market in both vaults | The node's bound `MarketFactory` | Atomic registration, expected configuration versions, and matching truth identity |
| Deposit AMM revenue | Bound AMM engine | Its market, collateral, and receipt only |
| Deposit book revenue | Bound OrderEngine | Its market, collateral, and fee payer only |
| Claim OPERATOR revenue | Any caller may trigger payment | Fixed market-snapshot operator recipient; caller cannot choose the destination |
| Claim PROTOCOL revenue | Any caller may trigger payment | Fixed market-snapshot protocol recipient; caller cannot choose the destination |
| Claim ordinary or contingent LP fees | Holder or validated engine flow | Earning-time holder entitlement in AmmFeeVault only |
| Claim resolver fees | Any caller may trigger payment after eligibility | The committed resolution recipient for that venue/market |
| Claim book timeout refund | Any caller may trigger payment after eligibility | Original recorded fee payer, never caller-selected |
| Sweep unattributed surplus | Any caller may trigger the bounded operation | Immutable venue-specific surplus recipient, described in section 8 |

A permissionless claim trigger cannot change the recipient or amount. A payout to a restricted token address may remain claimable; it must not block unrelated beneficiaries or the other venue. Any later payout-redirection facility must be authorized by the entitled recipient, never by a market/node/protocol admin.

## 2. Configuration and commitments

Use two append-only configuration stores, not one struct with role-dependent partial edits. Publication authorization comes from the [factory role matrix](factory-and-authority.md#role-contract). Conceptual fee interfaces are:

```solidity
publishAmmConfig(AmmConfig calldata cfg) returns (uint32 version);
publishBookConfig(BookConfig calldata cfg) returns (uint32 version);
ammConfigOf(bytes32 marketId) returns (AmmConfig);
bookConfigOf(bytes32 marketId) returns (BookConfig);
```

`AmmConfig` commits the AMM rate, allocation vector and operator recipient. The operator selects a rate from 0 to 10_000 bps; no separate operator-chosen AMM ceiling exists. Transaction-specific sponsor bounds belong to the liquidity request. The operator selects CAPITAL from 0 to 10_000 directly in the fee allocation. There are no `allowFeeGrowth` or `allowFullCapital` switches and no per-release growth-capability gate. Each market pins its selected configuration at creation. `BookConfig` commits the book rate, allocation vector and protocol recipient. At node creation the registry's standing stablecoin policy supplies the initial book config, book fee ceiling, book surplus recipient and protocol authority; later configurations are governed by that node's protocol authority within that immutable ceiling. The book ceiling protects the operator from a different governing authority and remains in force. Vault registration consumes collateral addresses/decimals and resolution-policy/recipient identifiers from [committed market terms](factory-and-authority.md#atomic-market-creation-and-snapshots), not the latest fee configuration. Fee structs do not include setters for shared resolution terms or deadline limits.

Each vault registers the exact configuration version/hash selected by the [atomic market-creation procedure](factory-and-authority.md#atomic-market-creation-and-snapshots). Registration stores an immutable reference to that venue's version and committed beneficiaries; no later lookup of the active version may determine an existing market's fee terms.

There is no separate AMM ceiling. This accepts the consequence at the arithmetic maximum: at 10_000 bps, the fee equals the LMSR base cost. A buy therefore costs twice the base cost before native-unit rounding, and a sell has zero net proceeds regardless of the CAPITAL allocation. A positive minimum-proceeds bound reverts atomically with `SlippageExceeded`; a zero minimum allows shares to be burned for zero cash and creates no seller lock. This rate was already reachable under a 10_000-bps chosen ceiling; removal changes the configuration surface, not fee mathematics. Real-engine evidence must cover six/eighteen decimals, ordinary/full-CAPITAL allocations, settlement, every applicable claim class and exact custody.

AMM allocations are `CAPITAL + LP + RESOLUTION + OPERATOR = 10_000` basis points. Book allocations are `RESOLUTION + PROTOCOL = 10_000` in the first release. The node's protocol authority controls future book splits after the registry owner's initial standing policy; there is no automatic node-operator book share. A future `MAKER_INCENTIVES` allocation requires a complete, reviewed, funded reward mechanism and its own immutable policy. First-release configuration rejects a nonzero incentive share instead of accumulating an unusable balance.

Any later incentive extension must specify eligibility, claim timing, funding source, expiration, residual ownership and anti-abuse rules before activation. Its outflow must remain bounded by committed funding, and its closure rules cannot consume ordinary user claims.

Publish validation rejects out-of-range rates, invalid recipients, arithmetic overflow, missing policy, and non-full allocation. Zero-rate configurations are valid when the chosen release bounds allow them; trading must not divide by zero or produce fictitious revenue.

An existing market's rate, allocation, and beneficiary snapshots are immutable. Accrued revenue and future revenue of that market continue to its committed recipient, including after the [authority transfers](factory-and-authority.md#role-contract) defined by the factory specification. Treasury/key rotation for old market entitlements is not a fee-ledger operation in this first-release design.

## 3. Fee calculation, receipt, and rounding

All vault ledgers use native token units. WAD pricing quantities remain in engines and must not be credited directly as vault money. Decimal conversion is performed against the market's pinned decimals. For an identical token used in both venues, the observed and pinned decimals must agree at creation; mismatched values revert.

### AMM

Keep the pricing and receipt discipline unless an explicitly reviewed economic change replaces it. For a WAD trading fee `F`, with AMM vector `(c, l, r, o)` and `B = 10_000`:

```text
C = floor(F * c / B)                       // engine-local capital amount, in WAD
R = floorNative(F - C)                     // transferable revenue, in native units
D = B - c
LP = floor(R * l / D)
RESOLUTION = floor(R * r / D)
OPERATOR = R - LP - RESOLUTION
```

The engine applies `C` according to the market's committed capital-growth mode. `R` is the only new liability credited by AmmFeeVault. Engine receipts, fees, trader obligations, and floor claims must reconcile in native units: `F - C - toWad(R)` is an engine-side conversion remainder already attributable to this market, not a transferable vault fee or node-wide surplus. Any eventual disposition follows AMM principal/LP accounting, not a protocol sweep. The normal incoming-round-up/outgoing-round-down conventions must be conserved through buys, sells, funding, and redemptions.

A sell pays the authenticated seller directly in the same transaction. For quoted net proceeds `P` WAD, pay `floorNative(P)` through the engine's exact-transfer push and debit only `toWad(floorNative(P))` from market collateral, aggregate token liabilities and the LP cash ledger. Debit transferable vault revenue separately. Thus `P - toWad(floorNative(P))` remains in that market's existing principal/LP accounting, including its earning-position cash allocation; it never leaves the liability ledger and creates no new beneficiary, seller claim, sweep or recovery route. Rounding happens on each sell, rather than on a later aggregate lock claim. The caller's WAD minimum-proceeds bound remains enforced against `P`; native receipt is its rounded-down conversion, disclosed by the SDK. Failed, false-returning or inexact payout reverts all trade, fee and position changes atomically. Zero native proceeds cause no token transfer. There is no seller queue, duration or later claim.

If `c == B` (100% CAPITAL), the full-allocation check forces `l == r == o == 0`. Take an explicit no-revenue path: `C = F`, `R = 0`; no vault deposit or division by `D` occurs. The vault retains its zero-denominator guard against an invalid nonzero revenue deposit. The engine uses the same capital-growth mechanism as for partial CAPITAL. Zero CAPITAL gives fixed depth between explicit sponsor additions. Both growth switches were removed by owner decision on 2026-10-10; the operator controls allocation through future configurations and each market keeps its creation snapshot.

Native custody reconciliation must distinguish exhausted whole-native claims from fractional accounting residue. A sell's conversion remainder stays in market principal before LP exit. At the maximum fee, engine custody and liabilities remain zero. Ordinary allocations retain exactly one native LP rounding liability in the vault, while full CAPITAL leaves the vault empty. These fixtures are not a universal bound on residue across arbitrary trades. No recovery or reassignment path is introduced.

`OPERATOR` includes only this AMM revenue's integer split remainder. A nominal operator weight of zero may therefore receive bounded split dust. Configuration views and the SDK disclose this immutable rounding rule and present effective native allocations for an entered fee, separately from engine-local capital and conversion remainder; zero weight is not advertised as an exact zero-receipt guarantee. No AMM split remainder can reach PROTOCOL.

### CLOB

Keep the taker fee on each matched quantity `q` at complementary price `p`:

```text
feeBasis = sum_over_fills(min(p, 1 - p) * q)
F = ceilNative(bookRate * feeBasis)         // one aggregate rounding per taker action
RESOLUTION = floor(F * resolutionBps / B)
PROTOCOL = F - RESOLUTION
```

BUY and SELL fills contribute to the same basis; complementary side encoding must not reduce it. Split and merge are fee-free complete-set conversions, not trading-fee exemptions. Selling split inventory as a taker pays the same complementary-price fee as any other taker. Makers pay zero. Aggregate the basis and round the fee upward once per submitted action, not per level. Sale proceeds can pay the fee; a dust sale whose fee exceeds proceeds needs explicitly bounded input or reverts.

### Inventory backing and native rounding

The owner-approved inventory ledger replaces signed-net ownership. Owned YES/NO includes the reserved subset; net exposure is derived. All book quantities remain expressed in WAD but must be multiples of `shareUnit = 10^(18 - tokenDecimals)`. One such unit is a claim on one native collateral unit. Split pulls exactly `amount / shareUnit`, credits both outcomes and increases both supplies; merge burns equal available quantities and pays exactly that amount. This deliberately rejects sub-native share quantities instead of introducing fractional complete-set collateral. It permits one-millionth of a share with a six-decimal token.

Resting BUY cash is `ceil(outcomeTick * remainingNativeShares / 1000)`. Each partial fill consumes the difference between the previous reserve and the exact remaining reserve; cancellation refunds that reserve exactly. Resting SELL orders reserve the named outcome, with no additional principal. Their cumulative proceeds are `floor(outcomeTick * cumulativeFilledNativeShares / 1000)` and a fill pays the difference from the previous cumulative amount. The counterparty receives/pays the complementary amount for mint/merge fills so each complete set is funded/released by exactly one native unit per native share. Transfer fills move the maker's exact cash amount. The difference from unrounded price multiplication is less than one native unit per fill and must be visible in simulation and enforced cash bounds. Repeated partial fills cannot drain rounding reserves.

The four fill types are same-outcome inventory transfers, complementary BUY minting, and complementary SELL merging. Before settlement, YES and NO supplies are equal and their backing remains intact during transfers; resting BUY cash is additional custody. Matching is bounded, plans aggregate taker cash/fees, collects any exact taker input before maker payouts, and then applies the fills. Reentrancy guards and exact token deltas apply to every path.

`maxTokenIn` and `minTokenOut` bind the action's native cash after fees and any resting BUY reservation. Refunds of the caller's cancelled pre-existing orders are separate and cannot inflate the reported execution proceeds. A violation rolls back fills, reservations, cancellations and fees atomically. SELL defaults may require zero new input, but the contract must not subsidize a tiny fee from another holder. Merge consumes only available pairs; settlement consumes only available balances, leaving reservations owned and cancellable. Cancellation/merge/claims do not require an open trading window.

INVALID redemption carries a half-native-unit remainder per market/account. Compute payout from `availableNativeYES + availableNativeNO + previousRemainder`, divide by two, and retain the parity bit. Cancelling reservations and settling in several calls must pay the same total as one combined claim. The remaining half unit cannot be transferred or paid alone; it remains attributable market backing and may combine with a later released odd share. Merge pays complete pairs exactly and does not erase this remainder. `invalidRemainderOf` and `InvalidRemainderChanged` expose it separately from native cash and gross share balances.

Failed recipient payouts are deferred only if both custody and recipient balances remain unchanged; successful payouts require exact deltas. Across markets, book custody must cover the sum of market backing (outcome liabilities, resting cash and any retained rounding) plus `totalDeferred`, and deferred claims must reconcile to individual creditors. No fee-free conversion, venue or node can borrow another domain's backing.

The book vault records the precise resolution amount from each receipt against its original fee payer for possible timeout refund. PROTOCOL takes only book split dust. There is no AMM LP, AMM CAPITAL, OPERATOR, or unallocated book bucket.

### Exact source-funded receipts

Recommended interface: `depositRevenue(marketId, expectedNative, feePayer)` on each vault, callable only by its bound venue engine. The vault determines the registered token itself; the caller cannot substitute one. In one guarded call it reads both custody balances, pulls exactly `expectedNative` from the engine, and verifies vault increase and engine decrease equal the expected amount. The engine has already charged that amount to the same market's accounting. Credits are created only after successful receipt; a failure reverts the complete trade.

No public `notify` may create credit from a previously donated balance, a caller-supplied historical balance, a naked transfer, another market's surplus, or another venue's allowance. Engine and vault reentrancy guards cover token callbacks, deposit, claims, and surplus sweep paths. Allowances are limited to the bound vault and the accepted transfer model; the allowance grants no cross-venue access. Zero deposits create no liability and no refundable entitlement.

These checks assume honest balance reporting. They reject inexact observed transfer deltas and guarded reentrant operations; they do not detect every callback or rebase between operations and cannot make a malicious or upgradeable issuer trustworthy. Independent custody prevents normal accounting from using the other venue's collateral, but a token issuer can still freeze or falsify that token everywhere. Canonical stablecoin admission and operator AMM token policy must document this risk separately.

## 4. LP and resolver entitlements

Preserve separate LP entry positions, earning-time weights, and ordinary/contingent fee indexes. Checkpoint both sides before position transfer or wrapper movement. New liquidity earns only future fees; it never inherits previous ordinary fees or historical contingent resolver forfeitures.

Ordinary LP revenue belongs only to the AMM earning-time holders. AMM RESOLUTION amounts also accrue into a contingent index when earned, but remain resolver obligations unless timeout invalidation occurs. This records a conditional entitlement, not two funded liabilities. Maintain one physical funded amount and one selected terminal beneficiary path.

The initial release keeps LP revenue claims settlement-gated, including ordinary revenue, to retain the established entitlement machinery while changing authority/custody. Early ordinary-fee withdrawal is a separate proposed improvement requiring transfer/wrapper/checkpoint and finalization proofs. Principal and contingent fees must never become early-withdrawable merely because ordinary fees later do.

The resolver recipient is committed in market terms and must not be read from mutable admin state at claim time. Each venue pays only its own committed resolution obligations. A zero resolver fee does not ensure resolution service; any minimum sponsor/service payment is a separate explicitly funded budget, never an unfunded fee promise.

## 5. Settlement and timeout policy

The [market lifecycle](factory-and-authority.md#market-lifecycle) fixes the shared terminal state: adjudicated completion requires `t < deadline + invalidationBuffer`; after that cutoff an unsettled finite market can only finalize as timeout INVALID. A timely proposal alone never preserves resolver eligibility beyond the cutoff. The two vaults read that settlement kind and finalize their fee ledgers independently, permissionlessly, and idempotently. Either may invoke timeout invalidation when those lifecycle conditions hold. Finalizing one venue never debits the other; a revert or unavailable recipient in one vault must not prevent the other from finalizing or paying its own claims.

| Terminal state | AmmFeeVault RESOLUTION | BookFeeVault RESOLUTION |
| --- | --- | --- |
| Validly resolved YES / NO | Committed resolver can receive it; contingent LP index is not payable | Committed resolver can receive it; contingent payer refunds are not payable |
| Adjudicated INVALID | Same as normal resolved outcome | Same as normal resolved outcome |
| Permissionless timeout INVALID (`INVALIDATED`) | Redirect within AMM to the already accrued contingent LP entitlements | Refund the resolution component to its original fee payers |

**Book timeout refund.** It refunds the resolution component because the paid-for resolution service was not delivered. It gives neither operator nor protocol a new revenue windfall from resolver failure, does not route book money to AMM LPs. Refunds do not reimburse the complete trading fee or trader opportunity cost.

For each fee deposit with resolution allocation `r_i`, increment `refundableResolution[marketId][feePayer]` by exactly `r_i` and increment the aggregate resolution bucket by the same amount. The authenticated book engine supplies the taker whose settlement actually paid the fee. A relayer or smart account is treated according to the actual authenticated trading account; an arbitrary caller-supplied refund recipient is forbidden. If the engine later supports signed orders or sponsored fee payment, its payer attribution must be specified before enabling that route.

Before terminal settlement, payer balances are contingent views and cannot be claimed. On timeout, disable resolver claims and enable payer claims without iterating over users. On normal resolution, enable the resolver claim and permanently disable payer claims. Payer balances need not be cleared by iteration on normal resolution: the terminal mode makes them unpayable, and they are not additional liabilities. Each payout decrements its selected bucket and total liability exactly once. One rounding unit cannot be refunded twice or left without an owner.

Ordinary book PROTOCOL revenue continues to its committed recipient regardless of timeout; this policy forfeits only the RESOLUTION share. That remains a limitation of fee-forfeiture incentives: paid adjudicated INVALID is not proof of truthful resolution. Evidence requirements, independent challenges, and resolution service funding are defined separately from this accounting rule.

## 6. Invariants with identical collateral

For every custody contract `V` and token `T`, require `balance(V,T) >= liabilities(V,T)` after completed state transitions. Exact equality need not hold because direct token donations are possible. Across registered markets, `liabilities(V,T)` equals the sum of outstanding market obligations plus separately enumerated venue obligations; it is never reduced just because a market is settled, delisted, transferred to a new admin, or absent from an indexer.

In fee vaults, all payable claims and reserved allocation/rounding amounts are included in liabilities. For each AMM token, `totalLiabilitiesOf(token) = sum_market(marketCollateral + claimableFloorLiability)` in WAD. Market collateral includes retained buy, fee, sell and settlement conversion amounts; floor liability includes unclaimed fractional entitlements after LP burns. Native engine balance must be at least `ceilNative(totalLiabilitiesOf(token))`. There is no locked seller term or discharged sell remainder outside these ledgers. Direct donations may make custody greater than liabilities; they remain outside pricing. Book engines separately account for share backing, resting-order escrow, deferred refunds/payouts, and conversion reserves according to their custody model. A test harness must reconcile the actual ledger categories rather than assuming the vault formula proves engine solvency.

For `tokenA == bookToken == T`:

1. AMM trading changes only AMM custody/fee ledgers; book trading changes only book custody/fee ledgers, apart from reading the shared truth state.
2. AMM LP principal, fees, and timeout contingencies have zero access to book collateral or book revenue. Book refunds and protocol claims have zero access to AMM custody.
3. Token equality does not change the [factory role matrix](factory-and-authority.md#role-contract) or the payment entitlements in section 2. Each vault applies its own authorization and fixed-recipient checks; holding both roles or separately owning a claim does not merge ledger entitlements.
4. Configuration version numbers may coincide numerically without identifying the same configuration. Venue is part of every lookup.
5. Distinct venue positions stay distinct even if their collateral address and outcome are equal. No implicit conversion, cross-margin, netting, or combined share redemption is introduced.
6. Depleting all legitimate claims in either venue first leaves the other fully backed. This holds for every ordering of operator/protocol, LP, trader, resolver, and refund claims.
7. Actual same-token price discrepancies may permit ordinary cross-venue trading. That is not authority leakage; it must not grant privileged custody access or a free claim on the other venue's pool.

## 7. Donations, rounding reserves, and surplus

Use explicit funded donation functions when sponsorship is intended: an AMM principal addition goes through the LP/sponsor path and receives its defined position; a tagged fee-budget donation has a named market and precommitted beneficiary policy. Do not silently treat a transfer as depth growth, a fee payment, or a taker entitled to a timeout refund. First-release fee-deposit entry points accept only engine-collected trade revenue; any tagged fee-budget extension requires its own funded source and accounting operation.

Raw ERC-20 transfers to vaults cannot reliably be attributed to a sender or market. Each vault therefore has a fixed `unattributedSurplusRecipient` chosen at node creation: the AMM address is selected by the node admin; the book address is fixed by the protocol owner's standing stablecoin policy and cannot be substituted by the node requester. They may be their respective treasury contracts. This recipient is immutable for that custody instance; a later role transfer cannot redirect earlier untagged donations. The factory and opposite role cannot choose a replacement.

`sweepUnattributedSurplus(token)` is permissionless, reentrancy-guarded, and transfers only `max(balance - totalLiabilities, 0)` to that fixed recipient. It accepts no arbitrary recipient and no market-closing assertion. Every credited fee becomes a liability before a sweep could observe it, and the vault holds its guard across the full receipt operation. A failed/inexact outgoing transfer reverts instead of marking money paid. Registered-token and accidental-other-token sweeps obey the same rule. Events identify vault/venue/token/recipient and amount.

Closing a market does not make its unused-looking balance surplus. Unclaimed LP fees, resolver/refund entitlements, deferred payouts, fractions awaiting further checkpoints, and earned rounding reserves remain liabilities indefinitely under this first-release policy. In particular, the earning-time LP accumulator's unallocated division remainder must not be swept merely because total LP supply reached zero: former holders can still have earned fee claims. A future residual-release policy needs a mathematical bound or complete entitlement extinction proof and an explicit original recipient rule; it cannot be a discretionary admin subtraction from liabilities.

Engine surplus recovery needs the same complete-obligation proof. The initial design authorizes no generalized engine balance sweep until every engine-specific reserve is reconciled; raw engine donations remain outside the pricing state. Neither factory nor protocol owner gets an AMM recovery exception. This is a bounded implementation constraint, not a claim that a raw donation is owned by every LP.
