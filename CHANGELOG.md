# Changelog

## 0.1.0

First public release. The contracts are experimental and have not had an independent external audit.

- `NodeFactory` deploys independently administered nodes from published releases.
- Each node runs a community AMM and a stablecoin order book as parallel venues on one shared market outcome.
- `AdjudicatorBase` and the sample `ManualAdjudicator` provide frozen resolver profiles, guardian vetoes with a per-market cap, and a timeout INVALID path.
- `MarketFactory` requires a risk acknowledgement to admit a token, and rejects a deadline more than `MAX_MARKET_DURATION` (1825 days) ahead.
- Separate fee vaults keep AMM and order book fee rights apart, including when both venues use the same token.
- `sdk/abi.json` exports the interface as `sooth-factory-v0.1.0`.
