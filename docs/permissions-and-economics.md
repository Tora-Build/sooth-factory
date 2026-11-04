# Permissions and economics

**Reading guide, not a permission or accounting specification.** The [document authority map](../README.md#document-authority) identifies the sole owner of each rule; [STATUS](../STATUS.md) owns current readiness.

The accepted product distinction is operator-directed AMM economics and protocol-directed CLOB economics. The documents below translate that decision into proposed mechanisms and their economic rationale.

## Roles

For the deployment executor, node admin, protocol authority and their relationship to market participants, use the [factory role contract](factory-and-authority.md#role-contract). For beneficiaries and payment eligibility, use [fee custody and entitlement](fee-accounting-and-same-token.md#1-custody-and-authority). Administrative permission and an earned claim are separate questions in those specifications.

## Find the governing rule

| Question | Owning section |
| --- | --- |
| Who configures a node or transfers an administrative role? | [Factory role contract](factory-and-authority.md#role-contract) |
| What is committed when a market accepts funds? | [Atomic market creation](factory-and-authority.md#atomic-market-creation-and-snapshots) |
| How are fees allocated, rounded and received? | [Fee configuration](fee-accounting-and-same-token.md#2-configuration-and-commitments) and [calculation](fee-accounting-and-same-token.md#3-fee-calculation-receipt-and-rounding) |
| Who can claim ordinary, contingent or timeout revenue? | [LP/resolver entitlements](fee-accounting-and-same-token.md#4-lp-and-resolver-entitlements) and [terminal distribution](fee-accounting-and-same-token.md#5-settlement-and-timeout-policy) |
| What changes when both venues use the same token? | [Equal-collateral invariants](fee-accounting-and-same-token.md#6-invariants-with-identical-collateral) |
| How are donations and retained rounding amounts handled? | [Surplus and reserves](fee-accounting-and-same-token.md#7-donations-rounding-reserves-and-surplus) |
| Which tradeoffs matter to sponsors and makers? | [Economic hardening](economics-and-hardening.md) |
