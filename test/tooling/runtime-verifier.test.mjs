import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { encodeAbiParameters, keccak256, stringToHex } from 'viem';
import { INTERFACE_VERSION } from '../../script/export-client-abi.mjs';
import {
  ARTIFACT_NAMES, SOURCE_REVISION, REQUEST_PARAMETER, BOOK_POLICY_PARAMETER, decodeRequest, decodeBookPolicy,
  indexImmutableDeclarations, loadCommittedArtifacts, nodeBookToken, nodeRuntimePlan,
  predictNode, reconstructRuntime, verifyRuntime, releaseManifestHash, requestHash,
} from '../../script/verify-runtime.mjs';

const address = value => `0x${value.toString(16).padStart(40, '0')}`;
const hash = value => `0x${value.toString(16).padStart(64, '0')}`;
const zeros = '00'.repeat(32);
function immutableFixture() {
  const artifact = {
    ast: { absolutePath: 'src/Fixture.sol', nodes: [{ nodeType: 'ContractDefinition', name: 'Fixture', nodes: [
      { id: 1, nodeType: 'VariableDeclaration', stateVariable: true, mutability: 'immutable', name: 'engine', typeDescriptions: { typeString: 'address' } },
      { id: 2, nodeType: 'VariableDeclaration', stateVariable: true, mutability: 'immutable', name: 'lock', typeDescriptions: { typeString: 'uint64' } },
    ] }] },
    deployedBytecode: { object: `0x60${zeros}61${zeros}62${zeros}00`, immutableReferences: {
      1: [{ start: 1, length: 32 }, { start: 67, length: 32 }],
      2: [{ start: 34, length: 32 }],
    } },
  };
  const values = { 'src/Fixture.sol:Fixture.engine': address(17), 'src/Fixture.sol:Fixture.lock': 7n };
  return { artifact, values, index: indexImmutableDeclarations({ Fixture: artifact }) };
}

test('reconstructs every immutable occurrence without changing code or metadata bytes', () => {
  const { artifact, values, index } = immutableFixture();
  const expectedAddressWord = '00'.repeat(31) + '11';
  const expectedIntegerWord = '00'.repeat(31) + '07';
  assert.equal(reconstructRuntime(artifact, values, index),
    `0x60${expectedAddressWord}61${expectedIntegerWord}62${expectedAddressWord}00`);
  assert.equal(artifact.deployedBytecode.object, `0x60${zeros}61${zeros}62${zeros}00`);
});

test('fails closed on missing or unsupported immutable declarations and types', () => {
  const { artifact, values, index } = immutableFixture();
  assert.throws(() => reconstructRuntime(artifact, {}, index), /Unsupported immutable declaration/);
  assert.throws(() => reconstructRuntime(artifact, values, new Map()), /Unsupported immutable declaration/);
  index.get('2').type = 'function (uint256) external';
  assert.throws(() => reconstructRuntime(artifact, values, index), /Unsupported immutable type/);
});

test('rejects malformed, overlapping, and non-placeholder immutable ranges', () => {
  for (const mutation of [
    a => { a.deployedBytecode.immutableReferences[2][0].length = 20; },
    a => { a.deployedBytecode.immutableReferences[2][0].start = 100; },
    a => { a.deployedBytecode.immutableReferences[2][0].start = 1; },
    a => { a.deployedBytecode.object = `0x60ff${a.deployedBytecode.object.slice(6)}`; },
  ]) {
    const { artifact, values, index } = immutableFixture();
    mutation(artifact);
    assert.throws(() => reconstructRuntime(artifact, values, index), /immutable (range|ranges|placeholder)/i);
  }
});

test('rejects missing AST and conflicting declaration IDs from mixed builds', () => {
  assert.throws(() => indexImmutableDeclarations({ Unknown: {} }), /AST missing/);
  const { artifact } = immutableFixture();
  const other = structuredClone(artifact);
  other.ast.absolutePath = 'src/Other.sol';
  assert.throws(() => indexImmutableDeclarations({ Fixture: artifact, Other: other }), /Conflicting AST ID/);
});

// bookTokens = { A: { token, decimals }, B: { token, decimals } } gives each node its own book token.
function completeFixture(bookTokens) {
  const artifacts = Object.fromEntries(ARTIFACT_NAMES.map((name, i) => [name, {
    ast: { absolutePath: `src/${name}.sol`, nodes: [] },
    bytecode: { object: `0x60${i.toString(16).padStart(2, '0')}00` },
    deployedBytecode: { object: `0x61${i.toString(16).padStart(4, '0')}00` },
  }]));
  artifacts.NodeRoles.ast = { absolutePath: 'src/policy/NodeRoles.sol', nodes: [
    { nodeType: 'ContractDefinition', name: 'NodeRoles', nodes: [
      { id: 1000, nodeType: 'VariableDeclaration', stateVariable: true, mutability: 'immutable',
        name: 'activationGate', typeDescriptions: { typeString: 'address' } },
    ] },
  ] };
  artifacts.NodeRoles.deployedBytecode = { object: `0x61${zeros}00`,
    immutableReferences: { 1000: [{ start: 1, length: 32 }] } };
  const manifest = { chainId: 31337, factory: address(100), registry: address(101),
    stable: address(102), stableDecimals: 6, truthImplementation: address(103),
    releaseManifestHash: hash(777), interfaceVersion: INTERFACE_VERSION, sdkAbiHash: hash(778) };
  if (bookTokens) {
    // Make the book decimals a real immutable, so a wrong value changes the expected runtime.
    artifacts.OrderEngine.ast = { absolutePath: 'src/OrderEngine.sol', nodes: [
      { nodeType: 'ContractDefinition', name: 'OrderEngine', nodes: [
        { id: 2000, nodeType: 'VariableDeclaration', stateVariable: true, mutability: 'immutable',
          name: 'baseTokenDecimals', typeDescriptions: { typeString: 'uint8' } },
      ] },
    ] };
    artifacts.OrderEngine.deployedBytecode = { object: `0x62${zeros}00`,
      immutableReferences: { 2000: [{ start: 1, length: 32 }] } };
    manifest.stable = bookTokens.A.token;
    manifest.stableDecimals = bookTokens.A.decimals;
    for (const suffix of ['A', 'B']) {
      manifest[`node${suffix}_bookToken`] = bookTokens[suffix].token;
      manifest[`node${suffix}_bookTokenDecimals`] = bookTokens[suffix].decimals;
    }
  }
  const policy = { protocolAuthority: address(9), bookSurplusRecipient: address(9), maxBookFeeBps: 400,
    bookConfig: { feeBps: 100, resolutionBps: 2000, protocolBps: 8000, protocolRecipient: address(9) } };
  const encodedPolicy = encodeAbiParameters([BOOK_POLICY_PARAMETER], [policy]);
  const makeRequest = (i, bookToken = manifest.stable) => ({ releaseId: hash(1), userSalt: hash(i), requester: address(i),
    nodeAdmin: address(i), bookToken,
    ammSurplusRecipient: address(i), expiry: 100_000n,
    expectedBookPolicyVersion: 3, expectedBookPolicyHash: keccak256(encodedPolicy),
    ammConfig: { feeBps: 100, capitalBps: 0, lpBps: 8000, resolutionBps: 1000,
      operatorBps: 1000, operatorRecipient: address(i) },
  });
  const bytecodes = new Map([
    [manifest.truthImplementation.toLowerCase(), artifacts.TruthMarket.deployedBytecode.object],
    [manifest.factory.toLowerCase(), artifacts.NodeFactory.deployedBytecode.object],
    [manifest.registry.toLowerCase(), artifacts.ReleaseRegistry.deployedBytecode.object],
  ]);
  for (const [suffix, i] of [['A', 1], ['B', 2]]) {
    const request = makeRequest(i, bookTokens?.[suffix].token);
    manifest[`request${suffix}`] = encodeAbiParameters([REQUEST_PARAMETER], [request]);
    manifest[`bookPolicy${suffix}`] = encodedPolicy;
    const predicted = predictNode(manifest.chainId, manifest.factory, manifest.registry, request, artifacts.NodeDeployer.bytecode.object);
    manifest[`request${suffix}Hash`] = predicted.hash;
    manifest[`node${suffix}_deployer`] = predicted.deployer;
    for (const [key, value] of Object.entries(predicted.addresses)) manifest[`node${suffix}_${key}`] = value;
    const plan = bookTokens
      ? nodeRuntimePlan(manifest, request, predicted, policy, suffix)
      : nodeRuntimePlan(manifest, request, predicted, policy);
    for (const component of plan) {
      const expected = component.artifact === 'NodeRoles'
        ? `0x61${'00'.repeat(12)}${predicted.deployer.slice(2).toLowerCase()}00`
        : bookTokens && component.artifact === 'OrderEngine'
          ? `0x62${bookTokens[suffix].decimals.toString(16).padStart(64, '0')}00`
          : artifacts[component.artifact].deployedBytecode.object;
      bytecodes.set(component.address.toLowerCase(), expected);
    }
  }
  const client = {
    getChainId: async () => 31337,
    getBlockNumber: async () => 99n,
    getBytecode: async ({ address: target, blockNumber }) => {
      assert.equal(blockNumber, 99n);
      return bytecodes.get(target.toLowerCase());
    },
    readContract: async ({ functionName, blockNumber, args }) => {
      assert.equal(blockNumber, 99n);
      if (functionName === 'creationCodeHash') return keccak256(artifacts[ARTIFACT_NAMES[args[1]]].bytecode.object);
      if (functionName === 'bookPolicy') return policy;
      if (functionName === 'activeBookPolicyVersion') return 3;
      assert.equal(functionName, 'release');
      return { exists: true, revoked: false, sourceRevision: SOURCE_REVISION,
        manifestHash: manifest.releaseManifestHash, truthImplementation: manifest.truthImplementation,
        truthCodeHash: keccak256(artifacts.TruthMarket.deployedBytecode.object),
        deployerCreationHash: keccak256(artifacts.NodeDeployer.bytecode.object) };
    },
  };
  return { artifacts, manifest, client, bytecodes, policy };
}

test('verifies all 19 planned runtimes at one block, including shared roots and both LP managers', async () => {
  const fixture = completeFixture();
  const report = await verifyRuntime(fixture);
  assert.equal(report.contracts.length, 19);
  assert.equal(report.contracts.filter(c => c.contract === 'LPPositionManager').length, 2);
  assert.equal(report.contracts.filter(c => c.contract === 'TruthMarket').length, 1);
  assert.equal(report.blockNumber, '99');
});

test('rejects code changes even when addresses and request commitments remain correct', async () => {
  const fixture = completeFixture();
  fixture.bytecodes.set(fixture.manifest.nodeA_roles.toLowerCase(), '0x61000000ff');
  await assert.rejects(verifyRuntime(fixture), /Runtime mismatch: node A NodeRoles/);
});

test('rejects a release whose actual creation recipe differs from the artifact commitment', async () => {
  const fixture = completeFixture();
  const originalRead = fixture.client.readContract;
  fixture.client.readContract = async params => params.functionName === 'creationCodeHash'
    ? hash(123) : originalRead(params);
  await assert.rejects(verifyRuntime(fixture), /On-chain NodeRoles creation hash mismatch/);
});

test('cannot present one deployment twice as two independently verified nodes', async () => {
  const fixture = completeFixture();
  const m = fixture.manifest;
  m.requestB = m.requestA;
  m.requestBHash = m.requestAHash;
  for (const key of Object.keys(m)) if (key.startsWith('nodeA_')) m[key.replace('nodeA_', 'nodeB_')] = m[key];
  await assert.rejects(verifyRuntime(fixture), /Duplicate node identity/);
});

test('rejects substituted constructor requests, deployer/child addresses and wrong RPC chain', async () => {
  const requestChanged = completeFixture();
  const request = decodeRequest(requestChanged.manifest.requestA);
  request.ammSurplusRecipient = address(998);
  requestChanged.manifest.requestA = encodeAbiParameters([REQUEST_PARAMETER], [request]);
  await assert.rejects(verifyRuntime(requestChanged), /request hash mismatch/);
  for (const key of ['nodeA_deployer', 'nodeB_positionManager']) {
    const fixture = completeFixture();
    fixture.manifest[key] = address(999);
    await assert.rejects(verifyRuntime(fixture), /CREATE2? .*mismatch/);
  }
  const wrongChain = completeFixture();
  wrongChain.client.getChainId = async () => 1;
  await assert.rejects(verifyRuntime(wrongChain), /RPC chain ID mismatch/);
});

test('rejects trailing request data and derives token-unit conversion from the manifest input', () => {
  const { artifacts, manifest } = completeFixture();
  assert.throws(() => decodeRequest(manifest.requestA + '00'.repeat(32)), /Canonical request encoding/);
  const request = decodeRequest(manifest.requestA);
  const predicted = predictNode(manifest.chainId, manifest.factory, manifest.registry, request, artifacts.NodeDeployer.bytecode.object);
  const policy = decodeBookPolicy(manifest.bookPolicyA);
  const order = nodeRuntimePlan(manifest, request, predicted, policy).find(c => c.artifact === 'OrderEngine');
  assert.equal(order.values['src/OrderEngine.sol:OrderEngine.shareUnit'], 1_000_000_000_000n);
  const roles = nodeRuntimePlan(manifest, request, predicted, policy).find(c => c.artifact === 'NodeRoles');
  assert.equal(roles.values['src/policy/NodeRoles.sol:NodeRoles.activationGate'], predicted.deployer);
  const plan = nodeRuntimePlan(manifest, request, predicted, policy);
  assert.equal(plan.find(c => c.artifact === 'AmmFeeVault').values['src/fees/VenueFeeVault.sol:VenueFeeVault.maxFeeBps'], 10000);
  assert.deepEqual(Object.keys(plan.find(c => c.artifact === 'AMMEngine').values), [
    'src/AMMEngine.sol:AMMEngine.marketFactory', 'src/AMMEngine.sol:AMMEngine.feeVault',
    'src/AMMEngine.sol:AMMEngine.positionManager',
  ]);
  assert.equal(plan.find(c => c.artifact === 'BookFeeVault').values['src/fees/VenueFeeVault.sol:VenueFeeVault.maxFeeBps'], 400);
  manifest.stableDecimals = 19;
  assert.throws(() => nodeRuntimePlan(manifest, request, predicted, policy), /Unsupported book decimals/);
});

test('v7 requests omit the lock duration and bind the V3 hash domain', () => {
  const { manifest } = completeFixture();
  const request = decodeRequest(manifest.requestA);
  assert.equal(Object.hasOwn(request, 'lockDuration'), false);
  const expected = domain => keccak256(encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }, REQUEST_PARAMETER],
    [keccak256(stringToHex(domain)), BigInt(manifest.chainId), manifest.factory, request],
  ));
  assert.equal(requestHash(manifest.chainId, manifest.factory, request), expected('SOOTH_FACTORY_NODE_REQUEST_V3'));
  assert.notEqual(requestHash(manifest.chainId, manifest.factory, request), expected('SOOTH_FACTORY_NODE_REQUEST_V2'));
  const legacyParameter = structuredClone(REQUEST_PARAMETER);
  legacyParameter.components.splice(7, 0, { name: 'lockDuration', type: 'uint64' });
  const legacy = encodeAbiParameters([legacyParameter], [{ ...request, lockDuration: 7200n }]);
  assert.throws(() => decodeRequest(legacy));
});

test('pins exact raw artifact bytes, aggregate release commitment and creation bytecode', async () => {
  const { artifacts, manifest } = completeFixture();
  const dir = await mkdtemp(join(tmpdir(), 'sooth-runtime-artifacts-'));
  try {
    manifest.artifactHashes = [];
    for (const name of ARTIFACT_NAMES) {
      const raw = JSON.stringify(artifacts[name]);
      manifest.artifactHashes.push(keccak256(Buffer.from(raw)));
      await writeFile(join(dir, `${name}.json`), raw);
    }
    manifest.creationHashes = ARTIFACT_NAMES.slice(0, 6).map(name => keccak256(artifacts[name].bytecode.object));
    const sdkPath = join(dir, 'sdk-abi.json');
    const sdkRaw = JSON.stringify({ interfaceVersion: INTERFACE_VERSION });
    await writeFile(sdkPath, sdkRaw);
    manifest.sdkAbiHash = keccak256(Buffer.from(sdkRaw));
    manifest.releaseManifestHash = releaseManifestHash(manifest);
    assert.equal(Object.keys(await loadCommittedArtifacts(manifest, dir, sdkPath)).length, 12);
    await writeFile(sdkPath, sdkRaw + '\n');
    await assert.rejects(loadCommittedArtifacts(manifest, dir, sdkPath), /SDK ABI hash mismatch/);
    await writeFile(sdkPath, sdkRaw);
    const version = manifest.interfaceVersion;
    manifest.interfaceVersion = 'sooth-factory-v6';
    await assert.rejects(loadCommittedArtifacts(manifest, dir, sdkPath), /Unsupported manifest interface/);
    manifest.interfaceVersion = version;
    const commitment = manifest.releaseManifestHash;
    manifest.releaseManifestHash = hash(123);
    await assert.rejects(loadCommittedArtifacts(manifest, dir, sdkPath), /Release artifact commitment/);
    manifest.releaseManifestHash = commitment;
    manifest.creationHashes[0] = hash(55);
    await assert.rejects(loadCommittedArtifacts(manifest, dir, sdkPath), /creation hash mismatch/);
    manifest.creationHashes[0] = keccak256(artifacts.NodeRoles.bytecode.object);
    await writeFile(join(dir, 'AMMEngine.json'), JSON.stringify(artifacts.AMMEngine) + '\n');
    await assert.rejects(loadCommittedArtifacts(manifest, dir, sdkPath), /AMMEngine artifact hash mismatch/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('policy preimage and historical registry policy must match the node request', async () => {
  const changedManifest = completeFixture();
  changedManifest.manifest.bookPolicyA = encodeAbiParameters([BOOK_POLICY_PARAMETER],
    [{ ...changedManifest.policy, bookSurplusRecipient: address(999) }]);
  await assert.rejects(verifyRuntime(changedManifest), /committed book policy mismatch/);
  const changedRegistry = completeFixture();
  const originalRead = changedRegistry.client.readContract;
  changedRegistry.client.readContract = params => params.functionName === 'bookPolicy'
    ? { ...changedRegistry.policy, maxBookFeeBps: 401 } : originalRead(params);
  await assert.rejects(verifyRuntime(changedRegistry), /historical book policy mismatch/);
  assert.throws(() => decodeBookPolicy(changedRegistry.manifest.bookPolicyA + '00'.repeat(32)),
    /Canonical book policy encoding/);
});

test('a newer active policy does not replace or invalidate a node historical policy', async () => {
  const fixture = completeFixture();
  const originalRead = fixture.client.readContract;
  const newerPolicy = { ...fixture.policy, maxBookFeeBps: 900 };
  const requestedVersions = [];
  fixture.client.readContract = params => {
    if (params.functionName === 'activeBookPolicyVersion') return 4;
    if (params.functionName === 'bookPolicy') {
      requestedVersions.push(Number(params.args[1]));
      return Number(params.args[1]) === 4 ? newerPolicy : fixture.policy;
    }
    return originalRead(params);
  };
  const report = await verifyRuntime(fixture);
  assert.equal(report.contracts.length, 19);
  assert.deepEqual(requestedVersions, [3, 3]);
  assert.deepEqual(report.bookPolicies.map(p => [p.pinnedVersion, p.activeVersion, p.maxBookFeeBps]),
    [[3, 4, 400], [3, 4, 400]]);
});

const twoTokens = () => ({ A: { token: address(102), decimals: 18 }, B: { token: address(104), decimals: 6 } });

test('verifies a two-token manifest, reconstructing each node from its own book token and decimals', async () => {
  const fixture = completeFixture(twoTokens());
  const report = await verifyRuntime(fixture);
  assert.equal(report.contracts.length, 19);
  assert.deepEqual(report.bookPolicies.map(p => [p.node, p.token.toLowerCase()]),
    [['A', address(102)], ['B', address(104)]]);
  const plans = ['A', 'B'].map(suffix => {
    const request = decodeRequest(fixture.manifest[`request${suffix}`]);
    const predicted = predictNode(fixture.manifest.chainId, fixture.manifest.factory, fixture.manifest.registry,
      request, fixture.artifacts.NodeDeployer.bytecode.object);
    return nodeRuntimePlan(fixture.manifest, request, predicted, fixture.policy, suffix);
  });
  const value = (plan, artifact, key) => plan.find(c => c.artifact === artifact).values[key];
  assert.equal(value(plans[0], 'OrderEngine', 'src/OrderEngine.sol:OrderEngine.shareUnit'), 1n);
  assert.equal(value(plans[1], 'OrderEngine', 'src/OrderEngine.sol:OrderEngine.shareUnit'), 1_000_000_000_000n);
  assert.equal(value(plans[0], 'BookFeeVault', 'src/BookFeeVault.sol:BookFeeVault.baseTokenDecimals'), 18n);
  assert.equal(value(plans[1], 'BookFeeVault', 'src/BookFeeVault.sol:BookFeeVault.baseTokenDecimals'), 6n);
  assert.equal(value(plans[1], 'BookFeeVault', 'src/BookFeeVault.sol:BookFeeVault.baseToken').toLowerCase(), address(104));
});

test('rejects swapped or wrong per-node book tokens and decimals', async () => {
  const swappedTokens = completeFixture(twoTokens());
  [swappedTokens.manifest.nodeA_bookToken, swappedTokens.manifest.nodeB_bookToken] =
    [swappedTokens.manifest.nodeB_bookToken, swappedTokens.manifest.nodeA_bookToken];
  await assert.rejects(verifyRuntime(swappedTokens), /Request book token mismatch/);

  const swappedBoth = completeFixture(twoTokens());
  for (const field of ['bookToken', 'bookTokenDecimals']) {
    [swappedBoth.manifest[`nodeA_${field}`], swappedBoth.manifest[`nodeB_${field}`]] =
      [swappedBoth.manifest[`nodeB_${field}`], swappedBoth.manifest[`nodeA_${field}`]];
  }
  await assert.rejects(verifyRuntime(swappedBoth), /Request book token mismatch/);

  const swappedDecimals = completeFixture(twoTokens());
  [swappedDecimals.manifest.nodeA_bookTokenDecimals, swappedDecimals.manifest.nodeB_bookTokenDecimals] = [6, 18];
  await assert.rejects(verifyRuntime(swappedDecimals), /Runtime mismatch: node A OrderEngine/);

  const wrongDecimals = completeFixture(twoTokens());
  wrongDecimals.manifest.nodeB_bookTokenDecimals = 8;
  await assert.rejects(verifyRuntime(wrongDecimals), /Runtime mismatch: node B OrderEngine/);

  const tooMany = completeFixture(twoTokens());
  tooMany.manifest.nodeB_bookTokenDecimals = 19;
  await assert.rejects(verifyRuntime(tooMany), /Unsupported book decimals/);
});

test('a manifest without per-node book tokens verifies exactly as before, and half a pair fails closed', async () => {
  const single = completeFixture();
  assert.equal(single.manifest.nodeA_bookToken, undefined);
  assert.deepEqual(nodeBookToken(single.manifest, 'A'), { token: single.manifest.stable, decimals: 6n });
  assert.deepEqual(nodeBookToken(single.manifest, 'B'), nodeBookToken(single.manifest));
  assert.equal((await verifyRuntime(single)).contracts.length, 19);

  // Without the per-node fields, both nodes are still held to the one manifest-wide token.
  const stripped = completeFixture(twoTokens());
  for (const suffix of ['A', 'B']) {
    delete stripped.manifest[`node${suffix}_bookToken`];
    delete stripped.manifest[`node${suffix}_bookTokenDecimals`];
  }
  await assert.rejects(verifyRuntime(stripped), /Request book token mismatch/);

  const tokenOnly = completeFixture(twoTokens());
  delete tokenOnly.manifest.nodeB_bookTokenDecimals;
  await assert.rejects(verifyRuntime(tokenOnly), /Node B book token and decimals must be given together/);
  const decimalsOnly = completeFixture(twoTokens());
  delete decimalsOnly.manifest.nodeA_bookToken;
  await assert.rejects(verifyRuntime(decimalsOnly), /Node A book token and decimals must be given together/);
});
