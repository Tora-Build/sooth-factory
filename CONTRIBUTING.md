# Contributing

For vulnerabilities, follow the [security reporting policy](SECURITY.md). Public issues and pull requests must not contain exploit details or credentials.

## Proposals

Describe the user or operator need, the exact authority or cash flow affected, the current behavior, the proposed behavior, and alternatives. Security-relevant designs must explain effects on existing markets, custody, settlement, configuration snapshots, and claims.

Edit each rule in its authoritative home first, as listed in the [document authority map](README.md#document-authority). Link to it from summaries; do not copy its formula, permission table or payout policy into another document.

## Changes and validation

Use focused branches and conventional commits, for example `docs(fees): specify venue fee authority`. Report only checks you actually ran. Tests must exercise authorization boundaries and economic invariants, not only successful factory creation.

## Build and verify locally

Use Node 22+, pnpm 10.30.1 and native Foundry Forge 1.8.1. The wrapper rejects other Forge versions and the zkSync build. Solidity 0.8.33, optimizer settings and remappings are pinned in [foundry.toml](foundry.toml). Initialize the exact recursive gitlinks before installing JavaScript dependencies:

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile --ignore-scripts
export FORGE_BIN=/path/to/native/forge
pnpm build
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=500 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true pnpm test:contracts --fuzz-seed 0x5d56b26
pnpm abi
pnpm test:client
"$FORGE_BIN" fmt --check
git diff --check
```

The full contract command includes the 6- and 18-decimal multi-market invariants. Regenerate the [ABI bundle](sdk/abi.json) after contract changes; client tests compare it against current compiler output. [SDK usage and limits](sdk/README.md) describe the supported adapter and replay boundary.

Run the [local two-node workflow](script/local/README.md) after changes to any deployed constructor, engine, vault, runtime verifier or client workflow. Its runner owns an isolated local Anvil and generated evidence; it is not a public-chain deployment script.

Keep large compiler artifacts, node dependencies and generated local-chain state out of Git. Do not commit private keys, credentials, environment files or deployment secrets.
