#!/usr/bin/env node
// Read-only, source-artifact verification. Expected immutable words come only
// from the committed request and CREATE/CREATE2 recipe, never from live code.
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { INTERFACE_VERSION } from './export-client-abi.mjs';
import {
  concatHex, createPublicClient, decodeAbiParameters, encodeAbiParameters,
  getAddress, getCreateAddress, getCreate2Address, http, keccak256, stringToHex,
} from 'viem';

export const SOURCE_REVISION = '0x5d56b26198e716a8fc82cea3af1bf415c770549a';
export const ARTIFACT_NAMES = [
  'NodeRoles', 'OrderEngine', 'AMMEngine', 'AmmFeeVault', 'BookFeeVault',
  'MarketFactory', 'NodeDeployer', 'TruthMarket', 'LPPositionManager', 'VenueFeeVault',
  'NodeFactory', 'ReleaseRegistry',
];
const field = (name, type) => ({ name, type });
export const BOOK_POLICY_PARAMETER = { type: 'tuple', components: [
  field('protocolAuthority', 'address'), field('bookSurplusRecipient', 'address'),
  field('maxBookFeeBps', 'uint16'),
  { name: 'bookConfig', type: 'tuple', components: [
    field('feeBps', 'uint16'), field('resolutionBps', 'uint16'),
    field('protocolBps', 'uint16'), field('protocolRecipient', 'address'),
  ] },
] };
export const REQUEST_PARAMETER = {
  type: 'tuple', components: [
    field('releaseId', 'bytes32'), field('userSalt', 'bytes32'),
    field('requester', 'address'), field('nodeAdmin', 'address'),
    field('bookToken', 'address'), field('ammSurplusRecipient', 'address'),
    field('expiry', 'uint64'),
    field('expectedBookPolicyVersion', 'uint32'), field('expectedBookPolicyHash', 'bytes32'),
    { name: 'ammConfig', type: 'tuple', components: [
      field('feeBps', 'uint16'), field('capitalBps', 'uint16'), field('lpBps', 'uint16'),
      field('resolutionBps', 'uint16'), field('operatorBps', 'uint16'),
      field('operatorRecipient', 'address'),
    ] },
  ],
};

function equalHex(a, b, label) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.toLowerCase() !== b.toLowerCase()) {
    throw new Error(`${label} mismatch`);
  }
}
function hexBytes(value, label) {
  if (typeof value !== 'string' || !/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) {
    throw new Error(`${label} must be linked hexadecimal bytes`);
  }
  return Buffer.from(value.slice(2), 'hex');
}
function unsigned(value, label) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new Error(`${label} is not an exact integer`);
  const result = BigInt(value);
  if (result < 0n) throw new Error(`${label} must be nonnegative`);
  return result;
}

export function decodeRequest(encoded) {
  const [request] = decodeAbiParameters([REQUEST_PARAMETER], encoded);
  equalHex(encodeAbiParameters([REQUEST_PARAMETER], [request]), encoded, 'Canonical request encoding');
  return request;
}

export function decodeBookPolicy(encoded) {
  const [policy] = decodeAbiParameters([BOOK_POLICY_PARAMETER], encoded);
  equalHex(encodeAbiParameters([BOOK_POLICY_PARAMETER], [policy]), encoded, 'Canonical book policy encoding');
  return policy;
}

export function requestHash(chainId, factory, request) {
  return keccak256(encodeAbiParameters(
    [field('', 'bytes32'), field('', 'uint256'), field('', 'address'), REQUEST_PARAMETER],
    [keccak256(stringToHex('SOOTH_FACTORY_NODE_REQUEST_V3')), unsigned(chainId, 'chainId'), factory, request],
  ));
}

export function predictNode(chainId, factory, registry, request, deployerCreationCode) {
  hexBytes(deployerCreationCode, 'NodeDeployer creation code');
  const hash = requestHash(chainId, factory, request);
  const id = keccak256(encodeAbiParameters(
    [field('', 'uint256'), field('', 'address'), field('', 'address'), field('', 'bytes32'), field('', 'bytes32')],
    [unsigned(chainId, 'chainId'), factory, request.requester, request.userSalt, request.releaseId],
  ));
  const initCode = concatHex([deployerCreationCode, encodeAbiParameters(
    [field('', 'address'), field('', 'address'), field('', 'bytes32'), field('', 'bytes32')],
    [factory, registry, request.releaseId, hash],
  )]);
  const deployer = getCreate2Address({ from: factory, salt: id, bytecodeHash: keccak256(initCode) });
  const names = ['roles', 'book', 'amm', 'ammVault', 'bookVault', 'marketFactory'];
  const addresses = Object.fromEntries(names.map((name, i) => [name,
    getCreateAddress({ from: deployer, nonce: BigInt(i + 1) }),
  ]));
  addresses.positionManager = getCreateAddress({ from: addresses.amm, nonce: 1n });
  return { id, hash, deployer, addresses };
}

// Solidity immutableReferences keys are compiler AST declaration IDs. Resolve
// them through source-qualified declarations, not guessed bytecode offsets.
export function indexImmutableDeclarations(artifacts) {
  const declarations = new Map();
  for (const [artifactName, artifact] of Object.entries(artifacts)) {
    if (!artifact.ast?.absolutePath) throw new Error(`${artifactName}: AST missing; rebuild with ast=true`);
    const source = artifact.ast.absolutePath;
    function visit(node, owner = '') {
      if (!node || typeof node !== 'object') return;
      if (Array.isArray(node)) { for (const child of node) visit(child, owner); return; }
      if (node.nodeType === 'ContractDefinition') owner = node.name;
      if (node.nodeType === 'VariableDeclaration' && node.stateVariable && node.mutability === 'immutable') {
        const declaration = { key: `${source}:${owner}.${node.name}`, type: node.typeDescriptions?.typeString };
        const previous = declarations.get(String(node.id));
        if (previous && JSON.stringify(previous) !== JSON.stringify(declaration)) {
          throw new Error(`Conflicting AST ID ${node.id}; artifacts must come from one clean build`);
        }
        declarations.set(String(node.id), declaration);
      }
      for (const value of Object.values(node)) if (value && typeof value === 'object') visit(value, owner);
    }
    visit(artifact.ast);
  }
  return declarations;
}

export function reconstructRuntime(artifact, values, declarations) {
  const bytes = hexBytes(artifact.deployedBytecode?.object, 'Runtime template');
  if (bytes.length === 0) throw new Error('Runtime template is empty');
  const covered = new Set();
  for (const [id, references] of Object.entries(artifact.deployedBytecode.immutableReferences ?? {})) {
    const declaration = declarations.get(id);
    if (!declaration || !Object.hasOwn(values, declaration.key)) {
      throw new Error(`Unsupported immutable declaration ${id} (${declaration?.key ?? 'unknown'})`);
    }
    const type = declaration.type?.startsWith('contract ') ? 'address' : declaration.type;
    if (!/^(address|bool|bytes32|uint(?:8|16|32|48|64|128|256))$/.test(type ?? '')) {
      throw new Error(`Unsupported immutable type ${declaration.type}`);
    }
    const word = hexBytes(encodeAbiParameters([{ type }], [values[declaration.key]]), 'Immutable word');
    for (const { start, length } of references) {
      if (!Number.isSafeInteger(start) || start < 0 || length !== 32 || start + length > bytes.length) {
        throw new Error(`Invalid immutable range ${id}`);
      }
      for (let i = start; i < start + length; i++) {
        if (covered.has(i)) throw new Error(`Overlapping immutable ranges ${id}`);
        covered.add(i);
        if (bytes[i] !== 0) throw new Error(`Nonzero immutable placeholder ${id}`);
      }
      word.copy(bytes, start);
    }
  }
  return `0x${bytes.toString('hex')}`;
}

function qualified(source, contract, values) {
  return Object.fromEntries(Object.entries(values).map(([name, value]) => [`${source}:${contract}.${name}`, value]));
}

// A node may name its own book token; both per-node fields must then be present.
// Without them the node uses the manifest-wide stable token, as single-token manifests do.
export function nodeBookToken(manifest, suffix) {
  const token = suffix === undefined ? undefined : manifest[`node${suffix}_bookToken`];
  const decimals = suffix === undefined ? undefined : manifest[`node${suffix}_bookTokenDecimals`];
  if (token === undefined && decimals === undefined) {
    return { token: manifest.stable, decimals: unsigned(manifest.stableDecimals, 'stableDecimals') };
  }
  if (token === undefined || decimals === undefined) {
    throw new Error(`Node ${suffix} book token and decimals must be given together`);
  }
  return { token, decimals: unsigned(decimals, `Node ${suffix} book token decimals`) };
}

export function nodeRuntimePlan(manifest, request, predicted, bookPolicy, suffix) {
  const a = predicted.addresses;
  const { token, decimals } = nodeBookToken(manifest, suffix);
  if (decimals > 18n) throw new Error('Unsupported book decimals');
  equalHex(request.bookToken, token, 'Request book token');
  equalHex(keccak256(encodeAbiParameters([BOOK_POLICY_PARAMETER], [bookPolicy])),
    request.expectedBookPolicyHash, 'Committed book policy');
  const vault = (engine, surplusRecipient, maxFeeBps, venue) => qualified('src/fees/VenueFeeVault.sol', 'VenueFeeVault', {
    engine, marketFactory: a.marketFactory, roles: a.roles, surplusRecipient, maxFeeBps, venue,
  });
  const component = (artifact, address, values = {}) => ({ artifact, address, values });
  return [
    component('NodeRoles', a.roles, qualified('src/policy/NodeRoles.sol', 'NodeRoles', {
      activationGate: predicted.deployer,
    })),
    component('OrderEngine', a.book, qualified('src/OrderEngine.sol', 'OrderEngine', {
      baseToken: request.bookToken, baseTokenDecimals: decimals,
      shareUnit: 10n ** (18n - decimals),
      marketFactory: a.marketFactory, feeVault: a.bookVault,
    })),
    component('AMMEngine', a.amm, qualified('src/AMMEngine.sol', 'AMMEngine', {
      marketFactory: a.marketFactory, feeVault: a.ammVault,
      positionManager: a.positionManager,
    })),
    component('AmmFeeVault', a.ammVault,
      vault(a.amm, request.ammSurplusRecipient, 10000, 0)),
    component('BookFeeVault', a.bookVault, {
      ...vault(a.book, bookPolicy.bookSurplusRecipient, bookPolicy.maxBookFeeBps, 1),
      ...qualified('src/BookFeeVault.sol', 'BookFeeVault', {
        baseToken: request.bookToken, baseTokenDecimals: decimals,
      }),
    }),
    component('MarketFactory', a.marketFactory, qualified('src/MarketFactory.sol', 'MarketFactory', {
      truthMarketImpl: manifest.truthImplementation, ammEngine: a.amm, ammFeeVault: a.ammVault,
      bookFeeVault: a.bookVault, orderEngine: a.book, nodeRoles: a.roles,
    })),
    component('LPPositionManager', a.positionManager, qualified('src/LPPositionManager.sol', 'LPPositionManager', {
      engine: a.amm, vault: a.ammVault,
    })),
    component('NodeDeployer', predicted.deployer, qualified('src/factory/NodeDeployer.sol', 'NodeDeployer', {
      factory: manifest.factory, registry: manifest.registry,
      releaseId: request.releaseId, committedRequestHash: predicted.hash,
    })),
  ];
}

export function releaseManifestHash(manifest) {
  return keccak256(encodeAbiParameters(
    [{ type: 'bytes20' }, { type: 'bytes32[12]' }, { type: 'string' }, { type: 'bytes32' }],
    [SOURCE_REVISION, manifest.artifactHashes, manifest.interfaceVersion, manifest.sdkAbiHash],
  ));
}

export async function loadCommittedArtifacts(manifest, directory,
  sdkAbiPath = new URL('../sdk/abi.json', import.meta.url)) {
  if (manifest.interfaceVersion !== INTERFACE_VERSION) throw new Error('Unsupported manifest interface version');
  const sdkBytes = await readFile(sdkAbiPath);
  equalHex(keccak256(sdkBytes), manifest.sdkAbiHash, 'SDK ABI hash');
  if (JSON.parse(sdkBytes.toString('utf8')).interfaceVersion !== manifest.interfaceVersion)
    throw new Error('SDK ABI interface version mismatch');
  if (manifest.artifactHashes?.length !== ARTIFACT_NAMES.length) throw new Error('Expected twelve committed artifact hashes');
  const artifacts = {};
  for (const [i, name] of ARTIFACT_NAMES.entries()) {
    const raw = await readFile(resolve(directory, `${name}.json`));
    equalHex(keccak256(raw), manifest.artifactHashes[i], `${name} artifact hash`);
    artifacts[name] = JSON.parse(raw.toString('utf8'));
  }
  const commitment = releaseManifestHash(manifest);
  equalHex(commitment, manifest.releaseManifestHash, 'Release artifact commitment');
  if (manifest.creationHashes?.length !== 6) throw new Error('Expected six child creation hashes');
  for (let i = 0; i < 6; i++) {
    equalHex(keccak256(artifacts[ARTIFACT_NAMES[i]].bytecode.object), manifest.creationHashes[i], `${ARTIFACT_NAMES[i]} creation hash`);
  }
  return artifacts;
}

const RELEASE_ABI = [{ type: 'function', name: 'release', stateMutability: 'view',
  inputs: [field('releaseId', 'bytes32')], outputs: [{ type: 'tuple', components: [
    field('exists', 'bool'), field('revoked', 'bool'), field('sourceRevision', 'bytes20'),
    field('manifestHash', 'bytes32'), field('truthImplementation', 'address'),
    field('truthCodeHash', 'bytes32'), field('deployerCreationHash', 'bytes32'),
  ] }],
}, { type: 'function', name: 'creationCodeHash', stateMutability: 'view',
  inputs: [field('releaseId', 'bytes32'), field('child', 'uint8')], outputs: [field('', 'bytes32')],
}, { type: 'function', name: 'bookPolicy', stateMutability: 'view',
  inputs: [field('token', 'address'), field('version', 'uint32')], outputs: [BOOK_POLICY_PARAMETER],
}, { type: 'function', name: 'activeBookPolicyVersion', stateMutability: 'view',
  inputs: [field('token', 'address')], outputs: [field('', 'uint32')],
}];

/// Artifacts supplied to this lower-level function must first pass
/// loadCommittedArtifacts(); the CLI always performs that authentication step.
export async function verifyRuntime({ manifest, artifacts, client }) {
  equalHex(getAddress(manifest.truthImplementation), manifest.truthImplementation, 'Truth address');
  const chainId = unsigned(await client.getChainId(), 'RPC chain ID');
  if (chainId !== unsigned(manifest.chainId, 'Manifest chain ID')) throw new Error('RPC chain ID mismatch');
  const blockNumber = await client.getBlockNumber();
  const declarations = indexImmutableDeclarations(artifacts);
  const plan = [
    { artifact: 'TruthMarket', address: manifest.truthImplementation, values: {}, node: 'shared' },
    { artifact: 'ReleaseRegistry', address: manifest.registry, values: {}, node: 'shared' },
    { artifact: 'NodeFactory', address: manifest.factory, node: 'shared',
      values: qualified('src/factory/NodeFactory.sol', 'NodeFactory', { registry: manifest.registry }) },
  ];
  const nodeIds = new Set();
  const bookPolicies = [];
  for (const suffix of ['A', 'B']) {
    const request = decodeRequest(manifest[`request${suffix}`]);
    const bookPolicy = decodeBookPolicy(manifest[`bookPolicy${suffix}`]);
    equalHex(keccak256(manifest[`bookPolicy${suffix}`]), request.expectedBookPolicyHash,
      `Node ${suffix} committed book policy`);
    const predicted = predictNode(chainId, manifest.factory, manifest.registry, request, artifacts.NodeDeployer.bytecode.object);
    if (nodeIds.has(predicted.id.toLowerCase())) throw new Error('Duplicate node identity in manifest');
    nodeIds.add(predicted.id.toLowerCase());
    equalHex(predicted.hash, manifest[`request${suffix}Hash`], `Node ${suffix} request hash`);
    equalHex(predicted.deployer, manifest[`node${suffix}_deployer`], `Node ${suffix} CREATE2 deployer`);
    for (const [name, address] of Object.entries(predicted.addresses)) {
      equalHex(address, manifest[`node${suffix}_${name}`], `Node ${suffix} ${name} CREATE address`);
    }
    const release = await client.readContract({ address: manifest.registry, abi: RELEASE_ABI,
      functionName: 'release', args: [request.releaseId], blockNumber });
    if (!release.exists) throw new Error('Missing on-chain release');
    equalHex(release.sourceRevision, SOURCE_REVISION, 'Release source revision');
    equalHex(release.manifestHash, manifest.releaseManifestHash, 'On-chain artifact commitment');
    equalHex(release.truthImplementation, manifest.truthImplementation, 'Release Truth implementation');
    equalHex(release.truthCodeHash, keccak256(artifacts.TruthMarket.deployedBytecode.object), 'Release Truth code hash');
    equalHex(release.deployerCreationHash, keccak256(artifacts.NodeDeployer.bytecode.object), 'Release deployer creation hash');
    const registeredPolicy = await client.readContract({ address: manifest.registry, abi: RELEASE_ABI,
      functionName: 'bookPolicy', args: [request.bookToken, request.expectedBookPolicyVersion], blockNumber });
    equalHex(encodeAbiParameters([BOOK_POLICY_PARAMETER], [registeredPolicy]),
      manifest[`bookPolicy${suffix}`], `Node ${suffix} historical book policy`);
    // Informational only: a later publication cannot invalidate committed terms.
    const activeVersion = await client.readContract({ address: manifest.registry, abi: RELEASE_ABI,
      functionName: 'activeBookPolicyVersion', args: [request.bookToken], blockNumber });
    bookPolicies.push({ node: suffix, token: request.bookToken,
      pinnedVersion: Number(request.expectedBookPolicyVersion), activeVersion: Number(activeVersion),
      policyHash: request.expectedBookPolicyHash, maxBookFeeBps: bookPolicy.maxBookFeeBps });
    for (let child = 0; child < 6; child++) {
      const creationHash = await client.readContract({ address: manifest.registry, abi: RELEASE_ABI,
        functionName: 'creationCodeHash', args: [request.releaseId, child], blockNumber });
      equalHex(creationHash, keccak256(artifacts[ARTIFACT_NAMES[child]].bytecode.object),
        `On-chain ${ARTIFACT_NAMES[child]} creation hash`);
    }
    plan.push(...nodeRuntimePlan(manifest, request, predicted, bookPolicy, suffix).map(item => ({ ...item, node: suffix })));
  }
  const uniqueAddresses = new Set();
  for (const item of plan) {
    const address = getAddress(item.address).toLowerCase();
    if (uniqueAddresses.has(address)) throw new Error(`Duplicate contract address in verification plan: ${address}`);
    uniqueAddresses.add(address);
  }
  const results = [];
  for (const item of plan) {
    const expected = reconstructRuntime(artifacts[item.artifact], item.values, declarations);
    const actual = await client.getBytecode({ address: item.address, blockNumber });
    if (actual?.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`Runtime mismatch: node ${item.node} ${item.artifact} at ${item.address}`);
    }
    results.push({ node: item.node, contract: item.artifact, address: item.address,
      bytes: (expected.length - 2) / 2, codeHash: keccak256(expected), verified: true });
  }
  return { chainId: chainId.toString(), blockNumber: blockNumber.toString(),
    artifactCommitment: manifest.releaseManifestHash, sourceRevision: SOURCE_REVISION,
    interfaceVersion: manifest.interfaceVersion, sdkAbiHash: manifest.sdkAbiHash,
    method: 'Full artifact runtime with independently reconstructed immutable words',
    scope: 'Registry, factory, two nodes, their deployers, LP managers and shared Truth implementation; excludes resolver, token and market-clone code',
    bookPolicies, contracts: results };
}

async function main(args) {
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--manifest', '--artifacts', '--sdk-abi', '--rpc-url', '--out'].includes(args[i]) || !args[i + 1]) {
      throw new Error('Usage: verify-runtime.mjs [--manifest path] [--artifacts dir] [--sdk-abi path] [--rpc-url URL] [--out path]');
    }
    options[args[i]] = args[i + 1];
  }
  const path = resolve(options['--manifest'] ?? 'deployments/local/factory-smoke.json');
  const manifest = JSON.parse(await readFile(path, 'utf8'));
  const artifacts = await loadCommittedArtifacts(manifest, options['--artifacts'] ?? resolve(dirname(path), 'artifacts'), options['--sdk-abi']);
  const client = createPublicClient({ transport: http(options['--rpc-url'] ?? 'http://127.0.0.1:8545') });
  const report = await verifyRuntime({ manifest, artifacts, client });
  const json = `${JSON.stringify(report, null, 2)}\n`;
  if (options['--out']) await writeFile(resolve(options['--out']), json);
  process.stdout.write(json);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
