# Local two-node acceptance

Run from the repository root after installing the pinned dependencies:

```sh
python3 script/local/run-local-smoke.py
```

The runner requires Forge 1.8.1, Anvil 1.9.0, Cast, Python 3.10+ and Node 22+. It resolves Forge from `SOOTH_LOCAL_FORGE`, then `FORGE_BIN`, then `PATH`. Anvil and Cast resolve from `SOOTH_LOCAL_ANVIL` and `SOOTH_LOCAL_CAST`, respectively, then `PATH`. The version checks remain active. If several tool versions are installed, select the pinned executables explicitly:

```sh
SOOTH_LOCAL_FORGE=/path/to/forge-1.8.1 \
SOOTH_LOCAL_ANVIL=/path/to/anvil-1.9.0 \
SOOTH_LOCAL_CAST=/path/to/cast \
python3 script/local/run-local-smoke.py
```

Anvil 1.9.0 and Forge 1.8.1 come from different Foundry releases. To install both, run the commands below in this order. The last install stays active, so `PATH` keeps Forge 1.8.1. Then set `SOOTH_LOCAL_ANVIL=$HOME/.foundry/versions/v1.9.0/anvil`.

```sh
foundryup --install 1.9.0
foundryup --install 1.8.1
```

It starts its own isolated Anvil on `127.0.0.1:18545`, chain 31337, and stops that process on success or failure. It refuses an occupied port and accepts no RPC URL argument. The public Anvil development mnemonic, freely minted test assets and ManualAdjudicator are exclusively local fixtures. ManualAdjudicator is Factory's only shipped sample adjudicator; production profiles are supplied externally through the [adjudicator interface](../../src/interfaces/IAdjudicator.sol).

The four phases prepare and activate two independent nodes; fund six markets with equal and different collateral; sponsor and trade through the SDK and contracts; transfer both roles and publish future fee policies; exercise veto, YES, NO, adjudicated INVALID and timeout INVALID; and claim principal, venue fees and an original-payer timeout refund after the book inventory has already closed. Both nodes' books trade, and YES, NO, invalid and timeout outcomes exercise book inventory as well as AMM claims.

The harness sells AMM positions for both six- and eighteen-decimal tokens and checks the seller's balance immediately after each trade. It reconciles the engine debit against seller cash plus vault revenue, verifies the remaining position and proves the sub-native sell remainder stays in market principal. `ammSellPayoutsNative` records these measured balance deltas. There is no delayed seller claim. Client replay independently matches each payout to ERC-20 transfers in its trade receipt; the [fee specification](../../docs/fee-accounting-and-same-token.md#amm) owns the per-sell rounding rule.

The SDK maker splits 100 stablecoins into 100 YES and 100 NO, reserves both inventories in sell offers at 0.52, receives two partial 40-share fills, cancels the remaining reservations and merges its 60 remaining complete sets. The taker merges its 40 purchased sets. The fixture checks free cash after the first fill, zero additional cash for inventory offers, exact native fees, owned and reserved quantities, and simulated execution against receipts. The final client hook proves cancellation by ID and claims after local delisting, then reconciles version-allowlisted replay with gross inventory, cash reservations, derived net exposure, fee-payer refunds and venue liabilities.

The queue fixture creates and cancels 40 orders in reverse order. Cancellation's automatic head advance already consumes 32 entries, leaving eight spent entries before the measured maintenance call. A one-step `eth_call` returns head 33 without persisting it, establishing pre-call head 32; the actual bounded cleanup leaves terminal head 40. The evidence records created/cancelled counts, residual counts, both head observations and quote gas separately.

`client-workflow.json` classifies each submitted transaction as `SDK_PREPARED` or `DIRECT_CONTRACT` and totals those actual records. Counts come from each new run. A script-originated transaction is not automatically an SDK-prepared transaction, and the SDK does not sign; the script invokes `validatePrepared` before its external wallet signs.

A five-native-unit complete set separately exercises INVALID settlement with outstanding inventory orders. Its first free-inventory claim carries one half-native unit; cancellation and an intervening complete-set merge preserve that entitlement; the final claim pays it. On-chain balances and replayed remainder events prove that the full five units return across these claim boundaries.

Deployment uses `beginNode` followed by `completeNode` under the published stablecoin book policy. The operator supplies AMM terms and accepts the active policy's exact version/hash when beginning, without a per-node protocol approval transaction. A prepared node has no market factory or active discovery record. Completion rechecks authorization, expiry, release eligibility, current stablecoin support and the pinned historical policy commitment. A newer publication neither blocks completion nor replaces its terms. Failure and revocation cases are covered by `test/factory/FactoryDeployment.t.sol`.

The local harness republishes the book policy between node A's two stages, changing its ceiling from 500 to 600 bps while keeping the actual trading fee unchanged. Node A completes with the original 500 bps ceiling and all original book terms; node B begins under the newer version and receives 600 bps. The independent runtime report reconstructs both vaults from their committed historical policies and records pinned versus active versions without treating equality as an activation requirement.

Before local deployment the runner builds contracts and exports the current `sooth-factory-v0.1.0` SDK ABI, with ManualAdjudicator as its only adjudicator. The release manifest commits the interface version and keccak256 of those exact ABI bytes alongside the twelve artifact hashes. The lock-free request uses the V3 hash domain and AMM construction has two address arguments. The manifest records each node's encoded standing book policy for independent constructor reconstruction. The runtime verifier compares that preimage with both the request commitment and the registry's historical policy; later policy changes do not rewrite an active node.

The runner keeps the 30,000,000 block gas limit, 24,576 runtime size limit and 49,152 initcode size limit enabled. Anvil 1.9.0 does not itself enforce Osaka's 16,777,216 transaction gas cap, so the runner independently checks both submitted gas limits and actual receipt gas for every transaction, including SDK transactions. The separately capped factory unit test checks both stages before this run.

The deployment phase submits 100% of Forge's computed gas estimate, without an additional multiplier. Other phases retain their 150% multiplier. The runner rejects both a submitted limit above the transaction cap and actual execution above it; this does not increase any chain limit. Current measured maxima belong to the generated transcript and [STATUS](../../STATUS.md).

Generated evidence is under `deployments/local/`:

- `transcript.json`: authoritative success/failure status, transaction limits and phase summaries.
- `factory-smoke.json` and `manifest-*.json`: addresses, exact requests, phase state and release commitments.
- `artifacts/`: the 12 exact compiler artifact files and `sdk-abi.json` bundle committed by the local release.
- `runtime-verification.json`: independent CREATE/CREATE2 prediction, registry creation hashes and complete deployed runtime comparison, with immutable words derived from source artifacts and constructor inputs.
- `broadcast-*.json`, `snapshot-*.json` and `forge-*.log`: receipts, independent chain reads and execution diagnostics.
- `client-workflow.json`: separately counted SDK-prepared/direct transactions, queue measurements and event-replay reconciliation.

Fee rates, allocations and the seven-day invalidation buffer are explicit test inputs. They are not production economic defaults. Local success does not establish production resolver security, token eligibility or commercial liquidity performance.
