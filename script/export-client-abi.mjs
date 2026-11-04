import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const INTERFACE_VERSION = 'sooth-factory-v0.1.0';
export const contracts = [
  'NodeFactory', 'NodeDeployer', 'ReleaseRegistry', 'NodeRoles', 'MarketFactory',
  'AMMEngine', 'OrderEngine', 'AmmFeeVault', 'BookFeeVault', 'TruthMarket',
  'LPPositionManager', 'LPPositionToken', 'ManualAdjudicator',
];
export function exportClientAbi() {
  const artifacts = contracts.map(name => [name,
    JSON.parse(readFileSync(resolve(root, 'out', `${name}.sol`, `${name}.json`), 'utf8'))]);
  const contractAbis = Object.fromEntries(artifacts.map(([name, artifact]) => [name, artifact.abi]));
  const digest = data => `sha256:${createHash('sha256').update(JSON.stringify(data)).digest('hex')}`;
  return {
    schemaVersion: 1,
    interfaceVersion: INTERFACE_VERSION,
    abiDigest: digest(contractAbis),
    buildDigest: digest(artifacts.map(([name, artifact]) => [name, artifact.metadata,
      artifact.deployedBytecode.object])),
    capabilities: { grossInventory: true, reservedInventory: true, splitMerge: true,
      explicitOrderActions: true, nativeAlignedShares: true, separateVenueVaults: true,
      standingBookPolicy: true, boundedMakerCancellation: true, fullCapital: true,
      directAmmSellPayout: true },
    contracts: contractAbis,
  };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mkdirSync(resolve(root, 'sdk'), { recursive: true });
  writeFileSync(resolve(root, 'sdk/abi.json'), `${JSON.stringify(exportClientAbi(), null, 2)}\n`);
  console.log(`Exported ${contracts.length} contract ABIs from the current build.`);
}
