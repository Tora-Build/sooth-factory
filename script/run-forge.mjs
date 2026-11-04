import { spawnSync } from 'node:child_process';

const binary = process.env.FORGE_BIN || 'forge';
const version = spawnSync(binary, ['--version'], { encoding: 'utf8' });
if (version.error || version.status !== 0 || !/forge Version: 1\.8\.1/.test(version.stdout) || /zksync/i.test(version.stdout)) {
  console.error('Native Forge 1.8.1 is required. Set FORGE_BIN to that executable. No global toolchain is changed.');
  process.exit(1);
}
const result = spawnSync(binary, process.argv.slice(2), { stdio: 'inherit' });
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
