# Architecture

**Explanatory overview.** This page adds no requirements. Use the [document authority map](../README.md#document-authority) to find the owning specification and [STATUS](../STATUS.md) for current readiness.

## Node and market identity

A node serves a community, topic, application or operator. Its market offers parallel AMM and CLOB participation around a shared outcome.

For enforceable identity and commitments, use the factory specification's [deployment identity](factory-and-authority.md#release-and-deployment-identity) and [market creation](factory-and-authority.md#atomic-market-creation-and-snapshots). Display topics help discovery; the canonical identity and settlement rules determine which instrument a user actually trades.

## Factory

The [factory topology](factory-and-authority.md#topology) shows how a release becomes an independently operated node. Its [role contract](factory-and-authority.md#role-contract) owns administrative capabilities; its deployment section owns wiring, authorization and verification. This overview does not define a second topology or permission matrix.

## Community AMM

The AMM serves sponsor-funded participation and discovery. [Sponsor policy](economics-and-hardening.md#4-amm-sponsor-policy) explains the budget, execution protections and economic tradeoffs. [Fee accounting](fee-accounting-and-same-token.md#2-configuration-and-commitments) defines how the resulting revenue is allocated and claimed.

## Stablecoin CLOB

The CLOB serves active traders and commercial makers. [Commercial CLOB policy](economics-and-hardening.md#5-commercial-clob-policy) owns economic requirements and measurements; the [fee specification](fee-accounting-and-same-token.md#3-fee-calculation-receipt-and-rounding) owns fee mechanics. Shared access is useful distribution, while capital and executable quotes come from participants.

## Shared settlement

Both venues depend on the same market outcome. The factory specification owns [market lifecycle](factory-and-authority.md#market-lifecycle) and [resolver binding/admission](factory-and-authority.md#resolution-and-network-admission). The fee specification owns [terminal fee distribution](fee-accounting-and-same-token.md#5-settlement-and-timeout-policy); economics explains [resolution funding and incentives](economics-and-hardening.md#6-resolution-is-a-shared-service-with-separately-funded-obligations).

## Network services

Discovery helps a community market reach outside traders without making popularity a contract transition. For the exact boundary between discovery, selected-book access and broader execution, use [network scope](factory-and-authority.md#network-identity-and-trading-access).

