import { encodeFunctionData, getContractAddress, erc20Abi, zeroAddress, isAddress } from 'viem';
import bundle from './abi.json' with { type: 'json' };

export const interfaceVersion = bundle.interfaceVersion;
export const abi = bundle.contracts;
export const BOOK_ACTION = Object.freeze({ BUY: 0, SELL: 1 });
export const BOOK_OUTCOME = Object.freeze({ NO: 0, YES: 1 });
export const BOOK_SIDE = Object.freeze({ BID: 0, ASK: 1 });
const lower = value => value.toLowerCase();
const same = (a, b) => lower(a) === lower(b);
const requireThat = (condition, message) => { if (!condition) throw new Error(message); };
const ceil = (n, d) => (n + d - 1n) / d;
const read = (client, address, contract, functionName, args = [], blockNumber) =>
  client.readContract({ address, abi: abi[contract], functionName, args, blockNumber });

/** Identity always includes chain, factory and node. A topic or token is not an instrument. */
export function instrumentKey(node, market, venue) {
  requireThat(venue === 'AMM' || venue === 'BOOK', 'Unknown venue');
  return `${node.chainId}:${lower(node.factory)}:${lower(node.nodeId)}:${lower(market)}:${venue}`;
}

/** Convert one AMM sell's WAD quote/event amount to its immediate native payout. */
export function presentAmmSellProceeds(proceedsWad, decimals) {
  requireThat(typeof proceedsWad === 'bigint' && proceedsWad >= 0n && proceedsWad < 2n ** 256n
    && Number.isInteger(decimals) && decimals >= 0 && decimals <= 18,
  'Invalid AMM sell proceeds');
  const unit = 10n ** BigInt(18 - decimals);
  const payoutNative = proceedsWad / unit;
  return { proceedsWad, payoutNative, paidWad: payoutNative * unit,
    retainedInMarketWad: proceedsWad % unit,
    disclosure: 'Sell proceeds are paid in the same transaction, rounded down separately for each sell. The sub-native remainder stays in market principal and LP accounting; it is not a seller claim. The minimum-proceeds bound remains in WAD.' };
}

/** Present the canonical AMM allocation in its actual WAD/native units. */
export function presentAmmConfig(config, { decimals, feeWad = 0n } = {}) {
  const weights = ['capitalBps', 'lpBps', 'resolutionBps', 'operatorBps'];
  requireThat([...weights, 'feeBps'].every(key => Number.isInteger(config[key])
    && config[key] >= 0 && config[key] <= 10000)
    && weights.reduce((sum, key) => sum + config[key], 0) === 10000,
  'Invalid AMM allocation');
  requireThat(Number.isInteger(decimals) && decimals >= 0 && decimals <= 18
    && typeof feeWad === 'bigint' && feeWad >= 0n && feeWad < 2n ** 256n,
  'Invalid AMM fee input');
  const unit = 10n ** BigInt(18 - decimals);
  const capitalWad = feeWad * BigInt(config.capitalBps) / 10000n;
  const revenueWad = feeWad - capitalWad;
  const vaultRevenueNative = revenueWad / unit;
  const denominator = BigInt(10000 - config.capitalBps);
  const lpNative = denominator === 0n ? 0n : vaultRevenueNative * BigInt(config.lpBps) / denominator;
  const resolutionNative = denominator === 0n ? 0n : vaultRevenueNative * BigInt(config.resolutionBps) / denominator;
  const operatorNative = vaultRevenueNative - lpNative - resolutionNative;
  const nominalOperatorNative = denominator === 0n ? 0n : vaultRevenueNative * BigInt(config.operatorBps) / denominator;
  const allocationDisclosure = denominator === 0n
    ? '100% CAPITAL retains the entire fee in the AMM. There is no vault revenue, LP fee, resolution fee, operator fee or conversion remainder.'
    : 'OPERATOR receives the integer split remainder even when its nominal weight is zero. Capital and conversion remainder stay in the AMM; they are not vault fee payouts.';
  const rateDisclosure = config.feeBps === 10000
    ? ' At a 100% trading fee, buys cost twice the pre-fee base amount before native rounding, and sells return zero net proceeds. A positive minimum output rejects those sells.'
    : '';
  return { config: { ...config }, decimals, feeWad, capitalWad, vaultRevenueNative,
    conversionRemainderWad: revenueWad % unit, lpNative, resolutionNative, operatorNative,
    nominalOperatorNative, operatorSplitRemainderNative: operatorNative - nominalOperatorNative,
    roundingRecipient: 'OPERATOR',
    disclosure: allocationDisclosure + rateDisclosure };
}

/** Pin the market config and collateral to one block before presenting allocations. */
export async function getAmmFeePresentation(client, node, market, feeWad = 0n) {
  const block = await client.getBlock();
  const info = await inspectMarket(client, node, market, block.number);
  const config = await read(client, node.ammVault, 'AmmFeeVault', 'configOf', [market], block.number);
  return { ...presentAmmConfig(config, { decimals: info.decimals, feeWad }),
    instrument: instrumentKey(node, market, 'AMM'), token: info.tokenA,
    blockNumber: block.number, blockHash: block.hash };
}

/** Verify a caller-selected factory/release against the live node and its immutable links. */
export async function verifyNode(client, { chainId, factory, nodeId, releaseId }) {
  requireThat(Number(await client.getChainId()) === Number(chainId), 'Wrong chain');
  const block = await client.getBlock();
  const deployer = await read(client, factory, 'NodeFactory', 'nodeDeployer', [nodeId], block.number);
  requireThat(!same(deployer, zeroAddress), 'Unknown node');
  const [actualRelease, wired, registry] = await Promise.all([
    read(client, deployer, 'NodeDeployer', 'releaseId', [], block.number),
    read(client, deployer, 'NodeDeployer', 'verifyWiring', [], block.number),
    read(client, factory, 'NodeFactory', 'registry', [], block.number),
  ]);
  requireThat(same(actualRelease, releaseId) && wired, 'Unapproved release or wiring');
  const names = ['roles', 'book', 'amm', 'ammVault', 'bookVault', 'marketFactory'];
  const addresses = Object.fromEntries(names.map((name, i) => [name,
    getContractAddress({ from: deployer, nonce: BigInt(i + 1) }),
  ]));
  addresses.positionManager = getContractAddress({ from: addresses.amm, nonce: 1n });
  const [bookToken, bookDecimals] = await Promise.all([
    read(client, addresses.bookVault, 'BookFeeVault', 'baseToken', [], block.number),
    read(client, addresses.bookVault, 'BookFeeVault', 'baseTokenDecimals', [], block.number),
  ]);
  return Object.freeze({ chainId: Number(chainId), factory, nodeId, releaseId, deployer,
    registry, ...addresses, bookToken, bookDecimals: Number(bookDecimals) });
}

export async function inspectMarket(client, node, market, blockNumber) {
  requireThat(Number(await client.getChainId()) === node.chainId, 'Wrong chain');
  // isLive() stays true after a veto returns the market to LIVE. Trading and
  // new liquidity follow isTradingOpen and isLiquidityOpen. The first successful
  // proposal leaves both false, including after a veto.
  const [marketFactory, registered, tokenA, decimals, deadline, open, liquidityOpen] = await Promise.all([
    read(client, market, 'TruthMarket', 'marketFactory', [], blockNumber),
    read(client, node.book, 'OrderEngine', 'isMarketRegistered', [market], blockNumber),
    read(client, node.amm, 'AMMEngine', 'tokenAOf', [market], blockNumber),
    read(client, node.amm, 'AMMEngine', 'tokenADecimalsOf', [market], blockNumber),
    read(client, market, 'TruthMarket', 'deadline', [], blockNumber),
    read(client, market, 'TruthMarket', 'isTradingOpen', [], blockNumber),
    read(client, market, 'TruthMarket', 'isLiquidityOpen', [], blockNumber),
  ]);
  requireThat(same(marketFactory, node.marketFactory) && registered && !same(tokenA, zeroAddress),
    'Market belongs to another node');
  return { tokenA, decimals: Number(decimals), deadline, open, liquidityOpen };
}

/** Creator supplies a finite native-token budget and explicit resolution terms. */
export async function prepareMarketCreation(client, node, creator, terms, { ttl = 120n } = {}) {
  requireThat(Number(await client.getChainId()) === node.chainId, 'Wrong chain');
  const block = await client.getBlock();
  requireThat(terms.maxInputNative > 0n && terms.maxInputNative < 2n ** 256n - 1n
    && terms.startTime > block.timestamp && terms.startTime < terms.deadline
    && ttl > 0n && ttl <= 3600n, 'Explicit budget and future schedule required');
  const [expectedAmmVersion, expectedBookVersion, expectedInvalidationBuffer,
    expectedProfileHash, frozen, profileMarketFactory, nonce] = await Promise.all([
    read(client, node.ammVault, 'AmmFeeVault', 'activeConfigVersion', [], block.number),
    read(client, node.bookVault, 'BookFeeVault', 'activeConfigVersion', [], block.number),
    read(client, node.marketFactory, 'MarketFactory', 'invalidationBuffer', [], block.number),
    read(client, terms.adjudicator, 'ManualAdjudicator', 'profileHash', [], block.number),
    read(client, terms.adjudicator, 'ManualAdjudicator', 'profileFrozen', [], block.number),
    read(client, terms.adjudicator, 'ManualAdjudicator', 'marketFactory', [], block.number),
    read(client, node.marketFactory, 'MarketFactory', 'creatorNonce', [creator], block.number),
  ]);
  requireThat(frozen && same(profileMarketFactory, node.marketFactory), 'Unbound resolution profile');
  const [expectedAmmHash, expectedBookHash] = await Promise.all([
    read(client, node.ammVault, 'AmmFeeVault', 'configHash', [expectedAmmVersion], block.number),
    read(client, node.bookVault, 'BookFeeVault', 'configHash', [expectedBookVersion], block.number),
  ]);
  const quoteDeadline = block.timestamp + ttl < terms.deadline ? block.timestamp + ttl : terms.deadline;
  const params = { ...terms, quoteDeadline, expectedAmmVersion, expectedBookVersion,
    expectedAmmHash, expectedBookHash, expectedProfileHash, expectedInvalidationBuffer };
  const market = await read(client, node.marketFactory, 'MarketFactory', 'predictMarketAddress',
    [creator, params, nonce], block.number);
  return { interfaceVersion, kind: 'market-create', node, market, creator, nonce, params,
    blockNumber: block.number, blockHash: block.hash, deadline: quoteDeadline,
    approval: { token: terms.tokenA, spender: node.marketFactory, amount: terms.maxInputNative },
    transaction: { chainId: node.chainId, to: node.marketFactory, value: 0n,
      data: encodeFunctionData({ abi: abi.MarketFactory, functionName: 'createMarket', args: [params] }) } };
}

/** Exact state protection is enforced on chain. A changed pricing state requires a new quote. */
export async function prepareSponsorAddition(client, node, market, additionalB, { ttl = 120n } = {}) {
  requireThat(additionalB > 0n && ttl > 0n && ttl <= 3600n, 'Invalid sponsor bounds');
  const block = await client.getBlock();
  const info = await inspectMarket(client, node, market, block.number);
  requireThat(info.liquidityOpen, 'Liquidity additions closed');
  const [maxTokenIn, minLpOut, price, expectedStateHash] = await read(client, node.amm,
    'AMMEngine', 'quoteLiquidityWithState', [market, additionalB], block.number);
  const deadline = block.timestamp + ttl < info.deadline ? block.timestamp + ttl : info.deadline;
  requireThat(deadline > block.timestamp && maxTokenIn > 0n && minLpOut > 0n
    && price > 0n && price < 10n ** 18n, 'No bounded sponsor quote');
  const limits = { maxTokenIn, minLpOut, minYesPrice: price, maxYesPrice: price,
    deadline, expectedStateHash };
  return { interfaceVersion, kind: 'sponsor-add', node, market, blockNumber: block.number,
    blockHash: block.hash, deadline, limits, tokenDecimals: info.decimals,
    approval: { token: info.tokenA, spender: node.amm, amount: maxTokenIn },
    transaction: { chainId: node.chainId, to: node.amm, value: 0n,
      data: encodeFunctionData({ abi: abi.AMMEngine, functionName: 'increaseLiquidity',
        args: [market, additionalB, limits] }) } };
}

const finiteCash = value => typeof value === 'bigint' && value >= 0n && value < 2n ** 256n - 1n;
function nativeShares(amount, decimals) {
  requireThat(typeof amount === 'bigint' && amount > 0n && amount < 2n ** 128n
    && Number.isInteger(decimals) && decimals >= 0 && decimals <= 18, 'Invalid share quantity');
  const unit = 10n ** BigInt(18 - decimals);
  requireThat(amount % unit === 0n, 'Shares must align with native collateral precision');
  return amount / unit;
}

/** A BUY limit bounds price; native cumulative rounding can add <1 unit per fill. */
export function bookDebitBound(amount, tick, feeBps, decimals, matchLimit = 64) {
  requireThat(Number.isInteger(tick) && tick >= 1 && tick <= 999
    && Number.isInteger(feeBps) && feeBps >= 0 && feeBps <= 10000
    && Number.isInteger(matchLimit) && matchLimit > 0 && matchLimit <= 256,
    'Invalid book quote inputs');
  const quantity = nativeShares(amount, decimals);
  const principal = ceil(quantity * BigInt(tick), 1000n) + BigInt(matchLimit) + 1n;
  // A better execution may be closer to 0.5 than the limit. Use the maximum min(p,1-p).
  const fee = ceil(quantity * BigInt(Math.min(tick, 500)) * BigInt(feeBps), 10_000_000n);
  return { maxFeeNative: fee, maxGrossDebitNative: principal + fee };
}

/** One canonical request for cash-funded BUYs and inventory-funded SELLs. */
export async function prepareBookOrder(client, node, market, { account, action, outcome,
  priceTick, amount, matchLimit = 64, ttl = 120n, rest = true, postOnly = false,
  expiry = 0n, maxTokenIn, minTokenOut = 0n }) {
  requireThat(isAddress(account ?? '') && Object.hasOwn(BOOK_ACTION, action)
    && Object.hasOwn(BOOK_OUTCOME, outcome) && Number.isInteger(priceTick)
    && priceTick >= 1 && priceTick <= 999 && Number.isInteger(matchLimit)
    && matchLimit > 0 && matchLimit <= 256 && typeof ttl === 'bigint' && ttl > 0n && ttl <= 3600n
    && typeof rest === 'boolean' && typeof postOnly === 'boolean' && (!postOnly || rest)
    && typeof expiry === 'bigint' && expiry >= 0n && expiry < 2n ** 64n
    && finiteCash(minTokenOut), 'Invalid order bounds');
  nativeShares(amount, node.bookDecimals);
  const block = await client.getBlock();
  const info = await inspectMarket(client, node, market, block.number);
  requireThat(info.open, 'Trading closed');
  requireThat(expiry === 0n || (expiry > block.timestamp && expiry <= info.deadline),
    'Invalid resting expiry');
  const feeBps = await read(client, node.bookVault, 'BookFeeVault', 'feeBpsOf', [market], block.number);
  const bound = bookDebitBound(amount, priceTick, Number(feeBps), node.bookDecimals, matchLimit);
  if (action === 'SELL') {
    const inventory = await readInventory(client, node, market, account, block.number);
    requireThat(amount <= inventory[outcome === 'YES' ? 'yesAvailable' : 'noAvailable'],
      'Insufficient available inventory');
    bound.maxFeeNative = ceil(nativeShares(amount, node.bookDecimals)
      * BigInt(Math.min(1000 - priceTick, 500)) * BigInt(feeBps), 10_000_000n);
    bound.maxGrossDebitNative = 0n;
  }
  maxTokenIn ??= bound.maxGrossDebitNative;
  requireThat(finiteCash(maxTokenIn), 'Explicit finite cash budget required');
  const deadline = block.timestamp + ttl < info.deadline ? block.timestamp + ttl : info.deadline;
  const params = { outcome: BOOK_OUTCOME[outcome], action: BOOK_ACTION[action], priceTick,
    amount, matchLimit, validUntil: deadline, expiry, rest, postOnly, maxTokenIn, minTokenOut };
  return { interfaceVersion, kind: 'book-order', node, market, account, params,
    blockNumber: block.number, blockHash: block.hash, deadline, ...bound,
    maxTokenIn, maxGrossDebitNative: maxTokenIn, expiryEnforcedOnChain: true,
    approval: { token: node.bookToken, spender: node.book, amount: maxTokenIn },
    transaction: { chainId: node.chainId, to: node.book, value: 0n,
      data: encodeFunctionData({ abi: abi.OrderEngine, functionName: 'placeOrder', args: [market, params] }) } };
}

async function readInventory(client, node, market, account, blockNumber) {
  const raw = await read(client, node.book, 'OrderEngine', 'getInventory', [market, account], blockNumber);
  const [yesOwned, noOwned, yesReserved, noReserved, cashReserved] = Array.isArray(raw)
    ? raw : [raw.yesOwned, raw.noOwned, raw.yesReserved, raw.noReserved, raw.cashReserved];
  requireThat([yesOwned, noOwned, yesReserved, noReserved, cashReserved]
    .every(x => typeof x === 'bigint' && x >= 0n)
    && yesOwned >= yesReserved && noOwned >= noReserved, 'Invalid inventory snapshot');
  return { yesOwned, noOwned, yesReserved, noReserved, cashReserved,
    yesAvailable: yesOwned - yesReserved, noAvailable: noOwned - noReserved,
    net: yesOwned - noOwned };
}

export async function getBookInventory(client, node, market, account) {
  requireThat(isAddress(account ?? ''), 'Invalid account');
  const block = await client.getBlock();
  await inspectMarket(client, node, market, block.number);
  const [inventory, invalidHalfNativeUnit] = await Promise.all([
    readInventory(client, node, market, account, block.number),
    read(client, node.book, 'OrderEngine', 'invalidRemainderOf', [market, account], block.number),
  ]);
  requireThat(Number(invalidHalfNativeUnit) === 0 || Number(invalidHalfNativeUnit) === 1,
    'Invalid settlement remainder');
  return { ...inventory, invalidHalfNativeUnit: Number(invalidHalfNativeUnit),
    blockNumber: block.number, blockHash: block.hash,
    instrument: instrumentKey(node, market, 'BOOK'), account };
}

async function prepareConversion(client, node, market, account, amount, kind, options) {
  requireThat(isAddress(account ?? ''), 'Invalid account');
  const quantity = nativeShares(amount, node.bookDecimals);
  const { ttl = 120n } = options;
  requireThat(typeof ttl === 'bigint' && ttl > 0n && ttl <= 3600n, 'Invalid conversion expiry');
  const block = await client.getBlock();
  const info = await inspectMarket(client, node, market, block.number);
  const split = kind === 'split';
  if (split) requireThat(info.open, 'Trading closed');
  else {
    const inventory = await readInventory(client, node, market, account, block.number);
    requireThat(inventory.yesAvailable >= amount && inventory.noAvailable >= amount,
      'Insufficient available complete sets');
  }
  const budget = split ? options.maxTokenIn ?? quantity : options.minTokenOut ?? quantity;
  requireThat(finiteCash(budget) && (split ? budget >= quantity : budget <= quantity),
    'Invalid conversion cash bound');
  const deadline = split && block.timestamp + ttl > info.deadline ? info.deadline : block.timestamp + ttl;
  const args = [market, amount, budget, deadline];
  return { interfaceVersion, kind: `book-${kind}`, node, market, account, amount, args,
    blockNumber: block.number, blockHash: block.hash, deadline, expiryEnforcedOnChain: true,
    approval: { token: node.bookToken, spender: node.book, amount: split ? quantity : 0n },
    transaction: { chainId: node.chainId, to: node.book, value: 0n,
      data: encodeFunctionData({ abi: abi.OrderEngine, functionName: kind, args }) } };
}

export const prepareSplit = (client, node, market, account, amount, options = {}) =>
  prepareConversion(client, node, market, account, amount, 'split', options);
export const prepareMerge = (client, node, market, account, amount, options = {}) =>
  prepareConversion(client, node, market, account, amount, 'merge', options);

/** Simulate after approval. Exact for this state; contract cash bounds remain authoritative. */
export async function simulatePreparedOrder(client, prepared) {
  requireThat(prepared.kind === 'book-order', 'Expected book order');
  await validatePrepared(client, prepared);
  const { result } = await client.simulateContract({ account: prepared.account,
    address: prepared.node.book, abi: abi.OrderEngine, functionName: 'placeOrder',
    args: [prepared.market, prepared.params] });
  return result;
}

/** Permissionless, bounded tombstone maintenance; does not broadcast or cancel live orders. */
export async function prepareHeadMaintenance(client, node, market, side, yesTick, maxSteps = 256) {
  requireThat((side === 0 || side === 1) && Number.isInteger(yesTick)
    && yesTick >= 1 && yesTick <= 999 && Number.isInteger(maxSteps)
    && maxSteps > 0 && maxSteps <= 1024, 'Invalid maintenance bounds');
  await inspectMarket(client, node, market);
  return { chainId: node.chainId, to: node.book, value: 0n,
    data: encodeFunctionData({ abi: abi.OrderEngine, functionName: 'advanceHead',
      args: [market, side, yesTick, BigInt(maxSteps)] }) };
}

/** Call immediately before signing; never silently substitute a fresh quote. */
export async function validatePrepared(client, prepared) {
  const { node, market, blockNumber, blockHash } = prepared;
  requireThat(Number(await client.getChainId()) === node.chainId, 'Wrong chain');
  const block = await client.getBlock();
  requireThat(block.timestamp <= prepared.deadline, 'Quote expired');
  const quotedBlock = await client.getBlock({ blockNumber });
  requireThat(same(quotedBlock.hash, blockHash), 'Quote block reorganized');
  if (prepared.kind === 'market-create') {
    requireThat(prepared.params.startTime >= block.timestamp, 'Market start passed');
    const [av, bv, buffer, nonce] = await Promise.all([
      read(client, node.ammVault, 'AmmFeeVault', 'activeConfigVersion'),
      read(client, node.bookVault, 'BookFeeVault', 'activeConfigVersion'),
      read(client, node.marketFactory, 'MarketFactory', 'invalidationBuffer'),
      read(client, node.marketFactory, 'MarketFactory', 'creatorNonce', [prepared.creator]),
    ]);
    requireThat(av === prepared.params.expectedAmmVersion && bv === prepared.params.expectedBookVersion
      && buffer === prepared.params.expectedInvalidationBuffer && nonce === prepared.nonce,
      'Creation terms changed');
    return prepared.transaction;
  }
  const info = await inspectMarket(client, node, market, block.number);
  if (prepared.kind === 'book-order') {
    const expiry = prepared.params.expiry || info.deadline;
    requireThat(expiry > block.timestamp && expiry <= info.deadline, 'Resting expiry passed');
  }
  if (prepared.kind === 'sponsor-add') {
    requireThat(info.liquidityOpen, 'Liquidity additions closed');
    const hash = await read(client, node.amm, 'AMMEngine', 'liquidityStateHash', [market], block.number);
    requireThat(same(hash, prepared.limits.expectedStateHash), 'Sponsor state changed');
  } else if (prepared.kind !== 'book-merge') requireThat(info.open, 'Trading closed');
  return prepared.transaction;
}

export function approvalTransaction(prepared) {
  const { token, spender, amount } = prepared.approval;
  return { chainId: prepared.node.chainId, to: token, value: 0n,
    data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [spender, amount] }) };
}

/** Cancellation remains available after delisting or quote expiry; identity is still verified. */
/** Legacy tick helper: a successful call can only advance its bounded maker cursor. */
export async function prepareCancel(client, node, market, side, yesTick) {
  requireThat((side === 0 || side === 1) && Number.isInteger(yesTick)
    && yesTick >= 1 && yesTick <= 999, 'Invalid cancel target');
  await inspectMarket(client, node, market);
  return { chainId: node.chainId, to: node.book, value: 0n,
    data: encodeFunctionData({ abi: abi.OrderEngine, functionName: 'cancel', args: [market, side, yesTick] }) };
}

/** Canonical cancellation route: identify the exact order without a maker-history scan. */
export async function prepareCancelById(client, node, market, orderId) {
  requireThat(typeof orderId === 'bigint' && orderId > 0n && orderId < 2n ** 64n,
    'Invalid order id');
  await inspectMarket(client, node, market);
  const order = await read(client, node.book, 'OrderEngine', 'getOrder', [orderId]);
  requireThat(same(order.market, market), 'Order belongs to another market');
  return { chainId: node.chainId, to: node.book, value: 0n,
    data: encodeFunctionData({ abi: abi.OrderEngine, functionName: 'cancelById', args: [orderId] }) };
}
