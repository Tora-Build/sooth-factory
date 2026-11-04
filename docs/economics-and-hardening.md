 Use the canonical [settlement and timeout payment policy](fee-accounting-and-same-token.md#5-settlement-and-timeout-policy).# Economics and hardening

This document owns economic rationale, sponsor budgets and liquidity-entry protection, growth-policy requirements, maker-readiness measures and interactions. See [document authority](../README.md#document-authority) for specification ownership and [current status](../STATUS.md) for readiness. Fee/accounting mechanisms belong to the [fee specification](fee-accounting-and-same-token.md); administrative capabilities, market commitments, and settlement authority belong to the [factory specification](factory-and-authority.md). No implementation or economic-return claim is implied.

## 1. Economic objective and boundaries

| Venue | Intended capital provider | What the capital purchases | Success criterion |
| --- | --- | --- | --- |
| Community AMM | Sponsor or other informed LP choosing to fund discovery | Immediate execution, information discovery, community participation, and optional token utility | Useful participation and information relative to an explicit subsidy budget; sponsors willingly renew |
| Stablecoin CLOB | Active, inventory-owning market maker | A commercial opportunity to quote and manage risk | Net trading returns justify inventory, adverse selection, operating, financing, and settlement costs; makers keep quoting |

The AMM may intentionally transfer value to better-informed traders. That is discovery expenditure, not by itself an accounting defect. Separate-entry LP positions protect entry-specific ownership and prospective fee entitlement; they do not insure principal or guarantee yield. Liquidity-add sandwiches and misleading entry quotes consume sponsor funds without equivalent discovery value and remain hardening targets.

The CLOB has no passive AMM LP pool. A maker owns its orders and gross YES/NO inventory, including inventory reserved for selling. Net exposure is a derived risk view, not the ownership ledger. A maker incentive, if introduced, is a distinct funded program; it does not grant a claim on AMM sponsors’ capital or fees. Factory deployment, a listing, and an aggregation API provide access but do not supply inventory.

The parallel-venue product decision lets communities and professional traders participate for different purposes. Community-token prices also depend on the collateral’s value conditional on the event: present collateral-denominated prices and returns, without claiming that different-collateral quotes must converge to one probability.

## 2. Economic implications of fees and authority

Use the canonical [role capabilities](factory-and-authority.md#role-contract), [fee configuration and buckets](fee-accounting-and-same-token.md#2-configuration-and-commitments), and [market snapshots](factory-and-authority.md#atomic-market-creation-and-snapshots). Their economic purpose is predictable sponsor and maker commitments: future policy experimentation must not rewrite the return assumptions on which existing participants funded a market.

No economic optimum follows from the authority split. Compare fee and allocation candidates on identical trading scenarios; a larger LP allocation competes with depth growth, resolution funding, and operator revenue. A zero trading fee or full reinvestment can be economically coherent only with another funded way to pay fixed resolution costs.

Evaluate actual native-unit proceeds using the canonical [fee calculation and rounding](fee-accounting-and-same-token.md#3-fee-calculation-receipt-and-rounding), including its full-capital no-revenue branch. Quantify the potentially nonclaimable tail under [rounding-reserve retention](fee-accounting-and-same-token.md#7-donations-rounding-reserves-and-surplus); bucket allocation does not establish complete cash evacuation. Show retained capital, payable earnings, conditional earnings, and reserved rounding amounts separately to avoid counting one token twice in sponsor ROI.

## 3. Economics of using the same token

Equal-collateral support lets operators without a community token fund discovery in the supported book stablecoin. Apply the canonical [custody boundary](fee-accounting-and-same-token.md#1-custody-and-authority) and [identical-collateral invariants](fee-accounting-and-same-token.md#6-invariants-with-identical-collateral) rather than inferring claim equivalence from an ERC-20 address. Economic arbitrage through independent trades still carries balance, execution, and settlement risks.

A same-token issuer freeze or depeg affects both venues simultaneously. Physical custody separation cannot diversify that common issuer risk, and separate node vaults do not establish per-market isolation among markets sharing one vault and token.

## 4. AMM sponsor policy

### Budget, starting odds, and ownership

Each sponsorship quote must show token identity and decimals, depth added, total maximum token input, entry odds, minimum position units, execution deadline, policy ID, and principal lock/settlement conditions. A sponsor chooses the amount of loss it is willing to fund; the protocol must not create a subsequent recapitalization obligation. Show residual principal and fees separately from contribution amounts. Where a fiat estimate is available, label its source/time and keep the binding budget denominated in the actual token.

For a symmetric initial LMSR at 50/50, the familiar starting subsidy is `b × ln(2)` under this normalization. This is not a formula for arbitrary later additions or a promise that the sponsor retains that deposit. Use the implementation’s exact rounded quote for execution and test its worst-case funded obligations.

A 50/50 seed is acceptable when deliberately funding uncertain community discovery. A strongly skewed, already-known event needs a justified prior or an explicit sponsor acknowledgement of the additional information subsidy. Avoid a universal token quantity across assets with different prices and decimals. An opening auction remains a research option; no auction security or honest price assumption is adopted here.

The [LP entitlement mechanism](fee-accounting-and-same-token.md#4-lp-and-resolver-entitlements) supplies the ownership baseline for sponsor-return measurements. Public UI copy should describe capital at risk and the sponsor’s chosen objective; avoid presenting sponsorship as insured yield.

### Fixed depth and deliberate reinvestment

The node admin selects fixed depth between explicit sponsor additions (`CAPITAL = 0`) or fee-funded growth (`0 < CAPITAL <= 100%`) through each published AMM allocation. No separate node-level opt-in or protocol/release capability approval is required. Each market pins the chosen configuration at creation, so later publications cannot alter funded markets. At 100% CAPITAL all trading fees stay in engine capital and no ordinary LP, resolution or operator fee revenue is created.

The operator also chooses the AMM rate without a separate chosen ceiling; at the allowed 100% rate buys cost twice the LMSR base and sells net zero, an explicitly accepted extreme whose minimum-proceeds behavior is owned by the [fee specification](fee-accounting-and-same-token.md#2-configuration-and-commitments).

| Policy | Benefit | Economic cost and required disclosure |
| --- | --- | --- |
| Fixed depth between explicit additions | Simple budget attribution; ordinary fees need not buy more exposure | Capacity does not grow automatically; spreads/slippage may remain high until a sponsor adds capital |
| Fee-funded depth growth | Reinvests part of trading fees into deeper execution | Increasing `b` without proportionate inventory scaling moves non-neutral odds toward 50%; the capital allocation is exposed to future trading losses |
| Alternative adaptive mechanism | Could seek price-neutral reinvestment or another capacity objective | Research-only until a complete funding, position-ownership, rounding, and solvency proof exists |

Apply the [market commitment rules](factory-and-authority.md#atomic-market-creation-and-snapshots) to the selected growth policy. Show capital retained separately from withdrawable LP fees, and avoid counting the same retained token as both principal gain and fee payout. Fixed depth addresses one source of odds movement; it does not solve liquidity-add MEV.

### Liquidity-add execution protection

Require bounded token input, a minimum issued position quantity, a finite deadline, and a sponsor-selected odds range for every supported addition path. The SDK must generate bounded quotes and reject silent unlimited defaults. Refresh quotes when the assumed pool state changes. These are execution controls, not a theorem that arbitrage profit is zero.

The local implementation additionally requires the exact `liquidityStateHash` returned by `quoteLiquidityWithState`. The hash binds chain, engine, market, depth, inventory, fractional accounting and total LP weight. A trade or another addition that changes this state invalidates the pending addition; the SDK also fixes the quoted odds and minimum units. This blocks execution against an altered pricing state, at the cost of requoting and possible denial of execution in active markets. It does not prevent loss from an already unfavorable quoted state, information-driven trading after sponsorship, or the intended discovery subsidy. Initial creation separately uses the commitments in the [factory specification](factory-and-authority.md#atomic-market-creation-and-snapshots).

A ±5-percentage-point regression still admits a profitable in-band sandwich. Its absolute loss scales with depth; calling a fixed small-token result “negligible” is not a general mitigation. Derive default tolerances from starting odds, proposed `deltaB / b`, token input, fees, reinvestment policy, and a published maximum acceptable sponsor execution loss. Require a tighter quote or reject unsupported size/state combinations rather than pretending that one universal band is safe.

Acceptance must measure attacker net token proceeds after fees, ending exposure, sponsor outcome-specific residual changes, and source of the transfer. Report gas and financing both excluded and separately estimated; an attack does not become safe merely because one chain’s gas once exceeded its profit. If bounded execution cannot meet the chosen loss tolerance, batching or another activation mechanism requires a separate mechanism review before implementation.

### Ordinary earnings, conditional earnings, and locks

Use the canonical [LP entitlement and claim gates](fee-accounting-and-same-token.md#4-lp-and-resolver-entitlements) and [settlement commitments](factory-and-authority.md#atomic-market-creation-and-snapshots). Measure the funding cost of the time between contribution, earning, and usable payout; accounting income is not the same as available cash. An early-fee enhancement would trade improved cash access against more accounting complexity and must not be credited as an implemented improvement in sponsor projections.

AMM sellers have no lock. Each sell is paid in its transaction under the [exact payout and remainder rule](fee-accounting-and-same-token.md#amm), preserving the deadline and proposal trading gates. This does not accelerate LP principal or fee claims.

Immediate cash access allows contract callers to complete borrowed-funds round trips within one transaction. Required evidence distinguishes isolated buy/sell and sell/buy cycles, which must not create token profit, from interleaved trading, where another trader's price impact can create ordinary P&L. Interleaved tests must reconcile every actor and engine/vault balance and all remaining obligations after each step; a per-actor no-profit assertion would incorrectly prohibit ordinary trading gains. Exercise both token precisions, zero through maximum fees and zero/partial/full CAPITAL, alongside hostile recipients, callbacks, terminal claim orders and same-block stale liquidity quotes.

## 5. Commercial CLOB policy

The canonical [CLOB fee calculation](fee-accounting-and-same-token.md#clob) defines execution charges for the inventory book. Measure the combined effect of the chosen rate, tick size, minimum order quantity, and decimal conversions: tiny orders can have a materially different effective rate after native-unit rounding. Lower nominal fees alone do not establish better maker returns or cheaper complete trade lifecycles.

Professional readiness needs executable quoting and risk management: documented order/cancel behavior, bounded matching work and gas, expiry or an explicit client cancellation strategy, atomic replacement if supported, inventory/funding visibility, cancel/refund liveness, a versioned maker interface, and reliable settlement data. Distinguish required client behavior from proposed contract features. Shared discovery and routing must preserve node, chain, market, venue, and collateral identity.

### Complete sets and inventory ownership

This section owns the resulting maker behavior.

The owner-approved maker requirement is native conversion of one unit of book collateral into one YES plus one NO, and the reverse conversion of an available pair back into collateral. A maker can split 100 stablecoins, hold 100 YES and 100 NO simultaneously, reserve both inventories in sell orders, cancel the unfilled quantities and merge the remaining pairs. This explicitly supersedes the prior net-only ledger and separately collateralized close-order mechanism. Keep the existing factory, authority, AMM and fee hardening; implement one coherent replacement book rather than two concurrent accounting models.

Store owned YES and NO balances independently. Reservations are subsets of ownership; available inventory is owned minus reserved, and net exposure is total owned YES minus total owned NO, including reservations. A SELL requires available inventory of its named outcome and reserves only that inventory when resting. A BUY reserves cash for its resting remainder. No automatic merge or offset may consume deliberate holdings or reservations. Split/merge are fee-free collateral conversions; every taker trade, including an inventory sale, follows the same canonical fee rule. Shares are internal book balances; transferable outcome tokens, cross-node fungibility and external exchange API compatibility are separate features.

Separate outcome (`NO=0`, `YES=1`) from action (`BUY=0`, `SELL=1`) and normalized book direction (`BID=0`, `ASK=1`). Users give the price of their named outcome; matching normalizes to the YES-price axis. BUY YES and SELL NO occupy bids; SELL YES and BUY NO occupy asks. Same-outcome buy/sell fills transfer inventory, complementary buys create a backed pair, and complementary sells destroy a pair and release its backing. Exact native cash and fee arithmetic belongs to the [fee specification](fee-accounting-and-same-token.md#clob).

### Closing and quote maintenance

The canonical order API binds outcome, BUY/SELL action, limit price, quantity, finite matching work, submission expiry and [native cash bounds](fee-accounting-and-same-token.md#clob). An inventory SELL replaces the prior close-only mechanism: it cannot sell more than the available named outcome and requires no extra principal for a resting order. Multiple sells cannot reserve the same units. A BUY acquires the requested outcome without implicitly consuming opposite inventory. Clients show ownership, availability, reservations and derived net separately.

Submission expiry and resting expiry are distinct commitments. Orders may be immediate-or-cancel, resting or post-only under the typed interface. Expired orders cannot execute; bounded cleanup releases their reservations/refunds. Cancellation and merge remain available after the trading cutoff. Settlement redeems available holdings; reserved inventory remains owned and must be cancelled before redemption or merge. A veto must not resurrect expired orders. Atomic replacement and off-chain signed orders remain separate scope.

Matching-budget exhaustion discards the unfilled remainder even when `rest=true`, preventing crossed resting quotes. The budget counts live queue entries: fills, and expired or self-crossing orders that the taker cancels. A cancelled or fully filled order is unlinked from that tick's live list, so a spent entry is not walked by matching and cannot hide a later order at the same tick. `MAX_DEAD_SKIPS` (512, readable from the engine) is the former scan cap; matching does not consult it. Quote views and `advanceHead` still scan the append-only array and will not pass a live order; clearing a spent prefix remains part of the funded maintenance duty below. Remainders below the contract's minimum resting size also do not rest. A self-cross cancels the existing maker order and releases its reservation instead of generating a self-trade. Clients must use the returned filled quantity and order ID to determine what executed and what remains live.

Use transaction simulation for executable quantity and native cash results, then enforce user bounds at inclusion. Simulation can become stale and is not a fill guarantee. Book views distinguish the bid/ask axis from outcome balances and omit expired liquidity. An ABI selector match alone does not establish compatible price or enum semantics.

Cancellation by order ID is the canonical maker route. The tick-based convenience `cancel` inspects at most 32 of that maker's historical IDs per call and returns the cancelled order ID, or zero when it only advanced past dead IDs. `MakerCancelProgress` records the resulting cursor and cancelled ID. Cursor progress is persisted even when no live order was found within the budget; a call already at the end reverts `NothingToCancel`. It never skips a live order or changes maker priority. Clients must inspect the return/event and repeat a progress-only call, or cancel the known ID directly. Shared queue-head cleanup is separately bounded.

Queue views can require scanning entries. Node operations must assign a funded maintenance runner, monitor quote failures and queue growth, and submit bounded cleanup calls for spent or expired prefixes. The SDK prepares these calls but does not run a keeper. Cleanup must never skip a live unexpired order or change its priority. Local recovery tests do not establish production keeper uptime.

Measure maker results as `realized spread/trading income + earned rebates - adverse-selection and inventory losses - gas - financing - operating costs`; report residual mark-to-market exposure separately. Use consistent attribution to avoid counting the same price change in both trading P&L and inventory loss. Neither gross volume nor a temporarily tight displayed spread proves profitability. Portfolio evidence should include quiet markets, information shocks, stale-quote losses, and delayed resolution.

Use the [canonical incentive scope](fee-accounting-and-same-token.md#2-configuration-and-commitments) when evaluating any future maker program. Prefer measured executable liquidity over nominal deposits or self-generated volume, but do not claim a manipulation-proof scoring rule without testing it. Separate incentive-funded returns from unsubsidized trading returns so that a temporary reward budget is not presented as repeatable commercial profitability.

## 6. Resolution is a shared service with separately funded obligations

Use the factory’s [resolution authority and admission](factory-and-authority.md#resolution-and-network-admission), [market commitments](factory-and-authority.md#atomic-market-creation-and-snapshots), and [market lifecycle](factory-and-authority.md#market-lifecycle). Economic evaluation uses those exact commitments: ambiguity about what settles and when increases maker inventory risk and sponsor funding cost even when the custody accounting is solvent.

Resolution has a fixed operating cost even when a market attracts no trades. Real-value activation needs a disclosed plan before real-value activation: a separately committed subsidy, a resolver’s funded service commitment, or another reviewed arrangement. Fees can replenish that budget but speculative future volume must not be its only assumed source. When one service receives revenue from both venues, count combined compensation once in cost analysis and use the canonical [entitlement accounting](fee-accounting-and-same-token.md#4-lp-and-resolver-entitlements) for each payment.

Its economic limitation is that fee forfeiture rewards timely completion more directly than truth. INVALID may be the correct answer under the committed rules; neither INVALID nor a guardian veto by itself establishes misconduct. Timeout refunds also do not reimburse all trader opportunity costs. Separately prepaid resolution service budgets need their own explicit completion/refund agreement rather than inheriting the trading-fee rule by accident.

The manual adjudicator is explicitly demo/test-only; use the factory’s [resolution admission requirements](factory-and-authority.md#resolution-and-network-admission) for real-value access. If a later product proposal introduces bonds, evaluate redirectable value, correlated token prices, dispute independence, and honest participation cost. A bond cannot verify truth on its own and cannot be counted as present economic security merely because it is under discussion.

## 7. Interactions that must be tested together

| Interaction | Potential conflict | Design response |
| --- | --- | --- |
| Reinvestment versus sponsor income | More depth commits earnings to additional risk; more dividends remove automatic capacity growth | Apply [committed policy](factory-and-authority.md#atomic-market-creation-and-snapshots); compare execution cost and sponsor loss on identical scenarios |
| Fixed depth versus add protection | Changing fee/capital policy changes sandwich profitability | Recompute limits and attacker optimization against the final policy, not a historical fee split |
| Same token versus authority split | A combined portfolio view can conceal money crossing economic domains | Use [same-token accounting invariants](fee-accounting-and-same-token.md#6-invariants-with-identical-collateral); report returns by venue before any portfolio aggregation |
| Early withdrawals versus timeout rebates | Improved cash access would add accounting complexity and conditional-reserve risk | Use [LP payment mechanics](fee-accounting-and-same-token.md#4-lp-and-resolver-entitlements); measure cash timing under the implemented policy |
| Operator autonomy versus participant commitments | An admin could improve future economics by disadvantaging existing holders | Use [snapshot and authority rules](factory-and-authority.md#atomic-market-creation-and-snapshots); preserve the original funding assumptions in historical P&L |
| Resolution costs versus rebates and revenue | Every beneficiary competes for the same collected fee | Use [canonical allocations](fee-accounting-and-same-token.md#2-configuration-and-commitments) plus disclosed external budgets; never assume one fee funds multiple full promises |
| Sponsor incentives versus participation metrics | Subsidized accounts can self-trade or manufacture identities | Publish concentration and retention measures; stress reward abuse; do not reward raw volume alone |
| Stablecoin convenience versus settlement risk | Identical denomination may hide different questions, issuers, or challenge rules | Use [instrument/admission identity](factory-and-authority.md#resolution-and-network-admission); measure exposures under their actual settlement terms |
