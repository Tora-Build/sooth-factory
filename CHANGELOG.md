# Changelog

## 0.1.1

- Require `ws` 8.21.0 or later through the pnpm override; the lockfile resolves 8.22.1. This fixes the memory-exhaustion and uninitialized-memory-disclosure advisories affecting the dependency in 0.1.0.
- Restrict branch and tag creation, prevent branch force-pushes, and keep release tags immutable. Maintainers use the controlled ref-creation procedure in [CONTRIBUTING](CONTRIBUTING.md#branches-and-release-tags).
- Contract sources, deployed-version support and ABI bytes are unchanged. The contract interface label remains `sooth-factory-v0.1.0`; 0.1.1 is a repository and tooling patch release.

## 0.1.0

First public release. The contracts are experimental and have not had an independent external audit.

- `NodeFactory` deploys independently administered nodes from published releases.
- Each node runs a community AMM and a stablecoin order book as parallel venues on one shared market outcome.
- `AdjudicatorBase` and the sample `ManualAdjudicator` provide frozen resolver profiles, guardian vetoes with a per-market cap, and a timeout INVALID path.
- `MarketFactory` requires a risk acknowledgement to admit a token, and rejects a deadline more than `MAX_MARKET_DURATION` (1825 days) ahead.
- Separate fee vaults keep AMM and order book fee rights apart, including when both venues use the same token.
- `sdk/abi.json` exports the interface as `sooth-factory-v0.1.0`.
