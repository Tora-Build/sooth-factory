#!/usr/bin/env python3
"""Reproducible localhost-only two-node acceptance workflow; public Anvil keys only.

No RPC/network argument exists. The runner starts and stops its own isolated Anvil.
It does not relax code-size, initcode-size, or block-gas limits. Anvil 1.5.1 does
not enforce Osaka's EIP-7825 per-transaction gas cap; this limitation is recorded.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "deployments/local"
RPC = "http://127.0.0.1:18545"
FORGE = Path(os.environ.get("SOOTH_LOCAL_FORGE") or os.environ.get("FORGE_BIN")
             or shutil.which("forge") or "forge")
ANVIL = Path(os.environ.get("SOOTH_LOCAL_ANVIL") or shutil.which("anvil") or "anvil")
CAST = Path(os.environ.get("SOOTH_LOCAL_CAST") or shutil.which("cast") or "cast")
ARTIFACTS = ["NodeRoles", "OrderEngine", "AMMEngine", "AmmFeeVault", "BookFeeVault",
             "MarketFactory", "NodeDeployer", "TruthMarket", "LPPositionManager", "VenueFeeVault",
             "NodeFactory", "ReleaseRegistry"]
ENV = {**os.environ, "FOUNDRY_PROFILE": "deploy", "FOUNDRY_TEST": "test/factory", "FOUNDRY_SCRIPT": "script/local"}


def rpc(method, params):
    request = urllib.request.Request(RPC, json.dumps({"jsonrpc": "2.0", "id": 1,
        "method": method, "params": params}).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(json.dumps(result["error"]))
    return result["result"]


def cast(*args):
    return subprocess.check_output([str(CAST), *args], cwd=ROOT, text=True).strip()


def call(address, signature, *args, sender=None):
    request = {"to": address, "data": cast("calldata", signature, *map(str, args))}
    if sender:
        request["from"] = sender
    return rpc("eth_call", [request, "latest"])


def number(address, signature, *args):
    return int(call(address, signature, *args), 16)


def denied(address, signature, sender, *args):
    try:
        call(address, signature, *args, sender=sender)
    except RuntimeError as error:
        if "revert" not in str(error).lower():
            raise
        return {"address": address, "function": signature, "sender": sender,
                "result": "reverted", "error": str(error)}
    raise AssertionError(f"Unauthorized call unexpectedly succeeded: {signature}")


def manifest():
    return json.loads((OUT / "factory-smoke.json").read_text())


def snapshot(label):
    m = manifest()
    assert number(m["factory"], "nodeCount()") == 2
    result = {"phase": label, "block": int(rpc("eth_blockNumber", []), 16), "nodes": {}, "markets": []}
    for node in ("nodeA", "nodeB"):
        assert number(m[f"{node}_deployer"], "verifyWiring()") == 1
        surfaces = ["roles", "book", "amm", "ammVault", "bookVault", "marketFactory", "positionManager"]
        result["nodes"][node] = {}
        for surface in surfaces:
            address = m[f"{node}_{surface}"]
            code = rpc("eth_getCode", [address, "latest"])
            size = (len(code) - 2) // 2
            assert 0 < size <= 24576
            result["nodes"][node][surface] = {"address": address, "runtimeBytes": size,
                "runtimeHash": cast("keccak", code),
                "stableBalanceNative": str(number(m["stable"], "balanceOf(address)", address)),
                "communityBalanceNative": str(number(m["community"], "balanceOf(address)", address))}
    for address in m["markets"]:
        if int(address, 16) == 0:
            continue
        result["markets"].append({"address": address,
            "settled": bool(number(address, "isSettled()")),
            "outcome": number(address, "winningOutcome()"),
            "settlementKind": number(address, "settlementKind()"),
            "termsHash": call(address, "termsHash()")})
    (OUT / f"snapshot-{label}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def phase(signature, label):
    log_path = OUT / f"forge-{label}.log"
    latest = ROOT / f"broadcast/LocalSmoke.s.sol/31337/{signature.split('(')[0]}-latest.json"
    command = [str(FORGE), "script", "script/local/LocalSmoke.s.sol:LocalSmoke", "--sig", signature,
        # Forge's deployment estimate already exceeds observed execution gas.
        # An additional 10% multiplier can cross EIP-7825 even when that estimate
        # fits. Use the full estimate, without extra padding, for this phase;
        # both submitted and actual gas remain independently capped below.
        "--rpc-url", RPC, "--broadcast", "--slow", "--gas-estimate-multiplier", "100" if label == "deployed" else "150"]
    print(f"Running {label}; log: {log_path}", flush=True)
    with log_path.open("w") as log:
        process = subprocess.run(command, cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    if process.returncode:
        if latest.exists():
            failures = []
            for tx in json.loads(latest.read_text()).get("transactions", []):
                if not tx.get("hash"):
                    continue
                receipt = rpc("eth_getTransactionReceipt", [tx["hash"]])
                if receipt and receipt["status"] != "0x1":
                    failures.append({"transaction": tx, "receipt": receipt,
                        "trace": rpc("debug_traceTransaction", [tx["hash"], {"tracer": "callTracer"}])})
            (OUT / f"failed-{label}.json").write_text(json.dumps(failures, indent=2) + "\n")
        print(log_path.read_text()[-12000:], flush=True)
        raise RuntimeError(f"{label} failed with exit {process.returncode}")
    report = json.loads(latest.read_text())
    receipts = report["receipts"]
    assert receipts and all(int(r["status"], 16) == 1 for r in receipts)
    for receipt in receipts:
        observed = rpc("eth_getTransactionReceipt", [receipt["transactionHash"]])
        transaction = rpc("eth_getTransactionByHash", [receipt["transactionHash"]])
        assert observed is not None and observed["status"] == "0x1"
        assert observed["blockHash"] == receipt["blockHash"]
        assert int(observed["gasUsed"], 16) <= 16_777_216
        assert int(transaction["gas"], 16) <= 16_777_216
    shutil.copy2(latest, OUT / f"broadcast-{label}.json")
    shutil.copy2(OUT / "factory-smoke.json", OUT / f"manifest-{label}.json")
    return {"phase": label, "transactions": len(receipts),
            "maxTransactionGas": max(int(r["gasUsed"], 16) for r in receipts),
            "snapshot": snapshot(label)}


def advance(seconds):
    rpc("evm_increaseTime", [seconds])
    rpc("evm_mine", [])


def verify_chain_transaction_limits():
    """Include SDK-originated transactions as well as Forge broadcasts."""
    transactions = []
    maximum_used = 0
    maximum_limit = 0
    for height in range(1, int(rpc("eth_blockNumber", []), 16) + 1):
        block = rpc("eth_getBlockByNumber", [hex(height), True])
        for transaction in block["transactions"]:
            receipt = rpc("eth_getTransactionReceipt", [transaction["hash"]])
            used, limit = int(receipt["gasUsed"], 16), int(transaction["gas"], 16)
            assert receipt["status"] == "0x1"
            assert used <= 16_777_216 and limit <= 16_777_216
            if transaction["to"] is None:
                assert (len(transaction["input"]) - 2) // 2 <= 49_152
            maximum_used = max(maximum_used, used)
            maximum_limit = max(maximum_limit, limit)
            transactions.append(transaction["hash"])
    return {"count": len(transactions), "maxGasUsed": maximum_used,
            "maxSubmittedGasLimit": maximum_limit, "hashes": transactions}


def main():
    # Refuse to interact with an existing process, even an unrelated local chain.
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", 18545)) == 0:
            raise RuntimeError("Port 18545 is occupied; refusing to reuse an existing RPC")
    forge_version = subprocess.check_output([str(FORGE), "--version"], text=True)
    anvil_version = subprocess.check_output([str(ANVIL), "--version"], text=True)
    assert "1.8.1" in forge_version and "1.5.1" in anvil_version
    # The release manifest commits the exact ABI bytes before any deployment.
    subprocess.run([str(FORGE), "build"], cwd=ROOT, env=ENV, check=True)
    subprocess.run(["node", "script/export-client-abi.mjs"], cwd=ROOT, check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "transcript.json").write_text(json.dumps({"status": "running", "rpc": RPC}) + "\n")
    (OUT / "runtime-verification.json").unlink(missing_ok=True)
    with (OUT / "anvil.log").open("w") as log:
        process = subprocess.Popen([str(ANVIL), "--host", "127.0.0.1", "--port", "18545",
            "--chain-id", "31337", "--gas-limit", "30000000", "--hardfork", "osaka", "--silent"],
            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError("Anvil exited; inspect deployments/local/anvil.log")
                try:
                    client = rpc("web3_clientVersion", [])
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.1)
            else:
                raise RuntimeError("Anvil did not start")
            assert client == "anvil/v1.5.1" and int(rpc("eth_chainId", []), 16) == 31337
            assert int(rpc("eth_getBlockByNumber", ["latest", False])["gasLimit"], 16) == 30_000_000
            phases = [phase("run()", "deployed")]
            m = manifest()
            artifacts = OUT / "artifacts"
            artifacts.mkdir(exist_ok=True)
            sdk_abi = ROOT / "sdk/abi.json"
            sdk_hash = subprocess.check_output([str(CAST), "keccak"], cwd=ROOT,
                input="0x" + sdk_abi.read_bytes().hex(), text=True).strip()
            assert sdk_hash.lower() == m["sdkAbiHash"].lower()
            shutil.copy2(sdk_abi, artifacts / "sdk-abi.json")
            for name, expected in zip(ARTIFACTS, m["artifactHashes"], strict=True):
                source = ROOT / f"out/{name}.sol/{name}.json"
                # Hash the exact bytes that are committed by the published local release.
                digest = subprocess.check_output([str(CAST), "keccak"], cwd=ROOT,
                    input="0x" + source.read_bytes().hex(), text=True).strip()
                assert digest.lower() == expected.lower()
                shutil.copy2(source, artifacts / f"{name}.json")
            negatives = [denied(m["nodeA_marketFactory"], "setCreationPaused(bool)", m["actors"][3], "true"),
                # The former protocol veto selector must be absent, not an authorized no-op.
                denied(m["nodeA_marketFactory"], "setBookAdmissionClosed(bool)", m["actors"][3], "true"),
                denied(m["nodeA_marketFactory"], "setBookAdmissionClosed(bool)", m["actors"][3], "false")]
            advance(2 * 3600)
            subprocess.run(["node", "script/local/client-workflow.mjs", "before"], cwd=ROOT,
                env={**ENV, "SOOTH_LOCAL_RPC": RPC}, check=True)
            phases.append(phase("tradeAndResolve()", "traded"))
            m = manifest()
            negatives.append(denied(m["nodeA_marketFactory"], "setCreationPaused(bool)", m["actors"][1], "true"))
            assert number(m["nodeA_book"], "getNet(address,address)", m["markets"][3], m["actors"][6]) == 0
            advance(3 * 3600)
            phases.append(phase("settleNormal()", "normal-settled"))
            before_refund = number(m["stable"], "balanceOf(address)", m["actors"][6])
            advance(10 * 86400)
            phases.append(phase("settleTimeout()", "complete"))
            subprocess.run(["node", "script/local/client-workflow.mjs", "after"], cwd=ROOT,
                env={**ENV, "SOOTH_LOCAL_RPC": RPC}, check=True)
            snapshot("after-client-claims")
            subprocess.run(["node", "script/verify-runtime.mjs", "--manifest", str(OUT / "factory-smoke.json"),
                "--sdk-abi", str(artifacts / "sdk-abi.json"),
                "--rpc-url", RPC, "--out", str(OUT / "runtime-verification.json")], cwd=ROOT, check=True)
            m = manifest()
            assert all(row["settled"] for row in phases[-1]["snapshot"]["markets"])
            assert [row["outcome"] for row in phases[-1]["snapshot"]["markets"]] == [1, 0, 2, 2, 1, 2]
            assert number(m["nodeA_bookVault"], "claimTimeoutRefund(address,address)", m["markets"][3], m["actors"][6]) == 0
            all_transactions = verify_chain_transaction_limits()
            transcript = {"status": "complete", "rpc": RPC, "chainId": 31337, "client": client,
                "forge": forge_version.strip(), "anvil": anvil_version.strip(), "hardfork": "osaka",
                "blockGasLimit": 30_000_000, "transactionGasLimit": 16_777_216,
                "runtimeLimit": 24_576, "initcodeLimit": 49_152,
                "limitations": ["Local deterministic test assets and ManualAdjudicator only; not a production resolver profile.",
                    "Anvil 1.5.1 does not enforce the Osaka EIP-7825 per-transaction gas cap. This runner independently rejects any receipt gas used or submitted transaction gas limit above 16,777,216.",
                    "Runtime hashes in snapshots prove continuity; runtime-verification.json separately compares committed source artifacts with deployed runtime."],
                "artifactOrder": ARTIFACTS, "phases": phases, "negativePermissionProbes": negatives,
                "timeoutRefundNative": m["timeoutRefundNative"], "takerBalanceBeforeTimeoutPhase": str(before_refund),
                "forgeTransactions": sum(row["transactions"] for row in phases),
                "allTransactions": all_transactions, "transactions": all_transactions["count"]}
            (OUT / "transcript.json").write_text(json.dumps(transcript, indent=2) + "\n")
            print(json.dumps({"status": "complete", "transactions": transcript["transactions"],
                  "manifest": str(OUT / "factory-smoke.json"), "transcript": str(OUT / "transcript.json")}), flush=True)
        except BaseException as error:
            (OUT / "transcript.json").write_text(json.dumps({"status": "failed", "rpc": RPC,
                "error": str(error), "evidence": "Inspect phase broadcast, snapshot and log files."}, indent=2) + "\n")
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
