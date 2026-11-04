import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { decodeFunctionData, encodeAbiParameters, encodeEventTopics, getContractAddress } from 'viem';
import { abi, interfaceVersion, bookDebitBound, prepareBookOrder, prepareSponsorAddition, validatePrepared,
  instrumentKey, approvalTransaction, prepareCancel, prepareCancelById, prepareMarketCreation,
  prepareSplit, prepareMerge, getBookInventory, simulatePreparedOrder, prepareHeadMaintenance,
  presentAmmConfig, getAmmFeePresentation, presentAmmSellProceeds } from '../../sdk/index.mjs';
import { NodeReplay } from '../../sdk/replay.mjs';
import { exportClientAbi } from '../../script/export-client-abi.mjs';

const address = n => `0x${n.toString(16).padStart(40, '0')}`;
const hash = n => `0x${n.toString(16).padStart(64, '0')}`;
const node = { chainId: 31337, factory: address(1), nodeId: hash(1),
  marketFactory: address(2), amm: address(3), book: address(4), ammVault: address(5),
  bookVault: address(6), bookToken: address(7), bookDecimals: 6 };
const market = address(8);
function clientFixture() {
  const state = { chainId: 31337, timestamp: 100n, blockHash: hash(100),
    stateHash: hash(50), open: true, liquidityOpen: true, marketFactory: node.marketFactory };
  return { state,
    getChainId: async () => state.chainId,
    getBlock: async () => ({ timestamp: state.timestamp, number: 10n, hash: state.blockHash }),
    readContract: async ({ functionName }) => {
      const values = { marketFactory: state.marketFactory, isMarketRegistered: true,
        tokenAOf: node.bookToken, tokenADecimalsOf: 6, deadline: 1000n,
        isTradingOpen: state.open, isLiquidityOpen: state.liquidityOpen, feeBpsOf: 100,
        quoteLiquidityWithState: [12n, 12n * 10n ** 12n, 500000000000000000n, state.stateHash],
        liquidityStateHash: state.stateHash,
        getInventory: [100n * 10n ** 18n, 100n * 10n ** 18n, 0n, 0n, 0n], invalidRemainderOf: 0 };
      assert.ok(functionName in values, functionName);
      return values[functionName];
    },
  };
}

test('generated ABI matches the current build and exposes separate vaults and bounded terms', () => {
  assert.deepEqual(JSON.parse(readFileSync(new URL('../../sdk/abi.json', import.meta.url))), exportClientAbi());
  assert.equal(abi.FeeVault, undefined);
  assert.equal(interfaceVersion, 'sooth-factory-v0.1.0');
  const requestFields = abi.NodeFactory.find(x => x.name === 'beginNode').inputs[0].components.map(x => x.name);
  for (const removed of ['protocolAuthority', 'bookConfig', 'bookSurplusRecipient', 'maxBookFeeBps', 'maxAmmFeeBps', 'allowFeeGrowth', 'allowFullCapital', 'policyEpoch', 'lockDuration'])
    assert.ok(!requestFields.includes(removed), removed);
  for (const removed of ['allowFeeGrowth', 'allowFullCapital'])
    assert.ok(!abi.AmmFeeVault.some(entry => entry.name === removed), removed);
  const ammInit = abi.AmmFeeVault.find(entry => entry.type === 'constructor').inputs[0];
  assert.ok(!ammInit.components.some(entry => entry.name === 'maxFeeBps'));
  assert.equal(exportClientAbi().capabilities.fullCapital, true);
  assert.equal(exportClientAbi().capabilities.directAmmSellPayout, true);
  for (const removed of ['lockDuration', 'claimUnlocked', 'getPendingLocks', 'getClaimableAmount',
    'getLockQueue', 'getMarketLockedLiability', 'ProceedsLocked', 'LockEntryRemoved', 'LocksProcessed',
    'InvalidLockDuration', 'NoUnlockedProceeds'])
    assert.ok(!abi.AMMEngine.some(entry => entry.name === removed), removed);
  assert.deepEqual(abi.AMMEngine.find(entry => entry.type === 'constructor').inputs.map(x => x.type),
    ['address', 'address']);
  assert.ok(requestFields.includes('expectedBookPolicyHash'));
  assert.equal(abi.OrderEngine.find(x => x.name === 'cancel').outputs[0].type, 'uint64');
  assert.ok(abi.OrderEngine.some(x => x.name === 'MakerCancelProgress'));
  assert.ok(abi.AmmFeeVault.find(x => x.name === 'SurplusSwept').inputs.some(x => x.name === 'venue'));
  for (const name of ['buyYes', 'buyNo', 'closePosition', 'isCloseOrder'])
    assert.equal(abi.OrderEngine.some(entry => entry.name === name), false, name);
  for (const name of ['placeOrder', 'split', 'merge', 'getInventory', 'InventoryChanged'])
    assert.ok(abi.OrderEngine.some(entry => entry.name === name), name);
  for (const name of ['bookAdmissionClosed', 'setBookAdmissionClosed', 'BookAdmissionSet'])
    assert.equal(abi.MarketFactory.some(entry => entry.name === name), false, name);
  const creation = abi.MarketFactory.find(x => x.name === 'createMarket');
  assert.ok(creation.inputs[0].components.some(x => x.name === 'expectedInvalidationBuffer'));
  const add = abi.AMMEngine.find(x => x.name === 'increaseLiquidity');
  assert.equal(add.inputs[2].components.at(-1).name, 'expectedStateHash');
});

test('book bound covers native cumulative rounding and rejects sub-native share quantities', () => {
  assert.ok(bookDebitBound(6n * 10n ** 12n, 500, 100, 6, 2).maxGrossDebitNative >= 5n);
  assert.ok(bookDebitBound(6n, 500, 100, 18, 2).maxGrossDebitNative >= 5n);
  for (const decimals of [2, 6, 18]) {
    const scale = 10n ** BigInt(18 - decimals);
    for (let tick = 1; tick <= 999; tick += 7) {
      for (const units of [1n, 3n, 6n, 1000001n]) {
        const amount = units * scale;
        const result = bookDebitBound(amount, tick, 100, decimals, 64);
        const feeExactNumerator = amount * BigInt(Math.min(tick, 500)) * 100n;
        assert.ok(result.maxFeeNative * 10000000n * scale >= feeExactNumerator);
        assert.ok(result.maxGrossDebitNative >= result.maxFeeNative);
      }
    }
  }
  assert.throws(() => bookDebitBound(0n, 500, 100, 6));
  assert.throws(() => bookDebitBound(1n, 500, 100, 6, 0));
  assert.throws(() => bookDebitBound(1n, 500, 100, 6, 64), /native collateral precision/);
});

test('same-token approval targets remain venue-specific', async () => {
  const client = clientFixture();
  const sponsor = await prepareSponsorAddition(client, node, market, 10n ** 18n);
  const book = await prepareBookOrder(client, node, market, {
    account: address(9), action: 'BUY', outcome: 'YES', priceTick: 600, amount: 10n ** 18n });
  assert.equal(sponsor.approval.token, book.approval.token);
  assert.equal(sponsor.approval.spender, node.amm);
  assert.equal(book.approval.spender, node.book);
  const approval = decodeFunctionData({ abi: [{ type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] }], data: approvalTransaction(book).data });
  assert.equal(approval.args[0].toLowerCase(), node.book);
  assert.equal(approval.args[1], book.maxGrossDebitNative);
  assert.notEqual(instrumentKey(node, market, 'AMM'), instrumentKey(node, market, 'BOOK'));
  assert.equal(book.expiryEnforcedOnChain, true);
});

test('client rejects wrong chain, wrong node, expired/reorganized/stale quote and closed lifecycle', async () => {
  const c = clientFixture();
  const sponsor = await prepareSponsorAddition(c, node, market, 1n);
  c.state.stateHash = hash(51);
  await assert.rejects(validatePrepared(c, sponsor), /state changed/);
  c.state.stateHash = hash(50);
  c.state.liquidityOpen = false;
  await assert.rejects(validatePrepared(c, sponsor), /additions closed/);
  c.state.liquidityOpen = true;
  c.state.blockHash = hash(101);
  await assert.rejects(validatePrepared(c, sponsor), /reorganized/);
  c.state.blockHash = hash(100);
  c.state.timestamp = 221n;
  await assert.rejects(validatePrepared(c, sponsor), /expired/);
  c.state.timestamp = 100n;
  c.state.chainId = 1;
  await assert.rejects(prepareSponsorAddition(c, node, market, 1n), /Wrong chain/);
  c.state.chainId = 31337;
  c.state.marketFactory = address(99);
  await assert.rejects(prepareBookOrder(c, node, market, {
    account: address(9), action: 'BUY', outcome: 'YES', priceTick: 500, amount: 10n ** 12n }), /another node/);
  c.state.marketFactory = node.marketFactory;
  const book = await prepareBookOrder(c, node, market, {
    account: address(9), action: 'BUY', outcome: 'NO', priceTick: 500, amount: 10n ** 12n });
  c.state.open = false;
  await assert.rejects(validatePrepared(c, book), /Trading closed/);
  assert.equal((await prepareCancel(c, node, market, 1, 500)).to, node.book);
});

test('order freshness rejects the exact resting-expiry boundary for BUY and SELL', async () => {
  for (const action of ['BUY', 'SELL']) {
    for (const rest of [true, false]) {
      const c = clientFixture();
      const order = await prepareBookOrder(c, node, market, {
        account: address(9), action, outcome: 'YES', priceTick: 500,
        amount: 10n ** 18n, expiry: 110n, rest });
      c.state.timestamp = 109n;
      assert.deepEqual(await validatePrepared(c, order), order.transaction);
      c.state.timestamp = 110n;
      await assert.rejects(validatePrepared(c, order), /Resting expiry passed/);
    }
  }
});

test('cancelById rejects another market and inventory exposes half-native settlement carry', async () => {
  const c = clientFixture();
  const inheritedRead = c.readContract;
  let orderMarket = market;
  c.readContract = args => args.functionName === 'getOrder' ? { market: orderMarket }
    : args.functionName === 'invalidRemainderOf' ? 1 : inheritedRead(args);
  const tx = await prepareCancelById(c, node, market, 1n);
  const decoded = decodeFunctionData({ abi: abi.OrderEngine, data: tx.data });
  assert.equal(decoded.functionName, 'cancelById');
  assert.deepEqual(decoded.args, [1n]);
  orderMarket = address(99);
  await assert.rejects(prepareCancelById(c, node, market, 1n), /another market/);
  const inventory = await getBookInventory(c, node, market, address(9));
  assert.equal(inventory.invalidHalfNativeUnit, 1);
  assert.equal(inventory.cashReserved, 0n);
});

test('market creation pins the fee versions, resolver, buffer and creator nonce', async () => {
  const c = clientFixture();
  const inheritedRead = c.readContract;
  const state = { version: 1n, buffer: 604800n, nonce: 0n, frozen: true };
  c.readContract = async args => {
    const values = { activeConfigVersion: state.version, invalidationBuffer: state.buffer,
      profileHash: hash(11), profileFrozen: state.frozen, creatorNonce: state.nonce,
      configHash: hash(12), predictMarketAddress: market };
    return args.functionName in values ? values[args.functionName] : inheritedRead(args);
  };
  const terms = { question: 'local test', startTime: 200n, deadline: 1000n,
    adjudicator: address(99), tokenA: node.bookToken, bBase: 10n ** 18n,
    initialProbabilityWad: 500000000000000000n, adjudicatorConfig: '0x',
    maxInputNative: 1000000n, resolutionTermsHash: hash(13) };
  const prepared = await prepareMarketCreation(c, node, address(9), terms);
  assert.equal(prepared.approval.spender, node.marketFactory);
  assert.equal(prepared.approval.amount, terms.maxInputNative);
  const decoded = decodeFunctionData({ abi: abi.MarketFactory, data: prepared.transaction.data });
  assert.equal(decoded.args[0].expectedInvalidationBuffer, 604800n);
  assert.equal(decoded.args[0].resolutionTermsHash, terms.resolutionTermsHash);
  assert.deepEqual(await validatePrepared(c, prepared), prepared.transaction);
  c.state.timestamp = 201n;
  await assert.rejects(validatePrepared(c, prepared), /Market start passed/);
  c.state.timestamp = 100n;
  for (const key of ['version', 'buffer', 'nonce']) {
    state[key]++;
    await assert.rejects(validatePrepared(c, prepared), /Creation terms changed/);
    state[key]--;
  }
  state.frozen = false;
  await assert.rejects(prepareMarketCreation(c, node, address(9), terms), /Unbound resolution/);
  await assert.rejects(prepareMarketCreation(c, node, address(9), {
    ...terms, maxInputNative: 2n ** 256n - 1n }), /Explicit budget/);
});

function event(contract, name, args, emitter, blockHash, index) {
  const item = abi[contract].find(x => x.type === 'event' && x.name === name);
  const plain = item.inputs.filter(x => !x.indexed);
  return { address: emitter, blockHash, transactionHash: hash(index + 200), logIndex: index,
    topics: encodeEventTopics({ abi: [item], eventName: name, args }),
    data: encodeAbiParameters(plain, plain.map(x => args[x.name])) };
}
function nodeEvent(offset, blockHash, index) {
  return event('NodeFactory', 'NodeCreated', { nodeId: hash(offset), releaseId: hash(9),
    nodeAdmin: address(offset + 10), protocolAuthority: address(19), bookToken: address(7),
    deployer: address(offset + 20), roles: address(offset + 30), book: address(offset + 40),
    amm: address(offset + 50), ammVault: address(offset + 60), bookVault: address(offset + 70),
    marketFactory: address(offset + 80) }, address(1), blockHash, index);
}

test('AMM sell presentation separates immediate native cash from retained market rounding', () => {
  for (const decimals of [6, 18]) {
    const unit = 10n ** BigInt(18 - decimals);
    for (const proceedsWad of [0n, unit - 1n, unit, 7n * unit + unit / 3n]) {
      const result = presentAmmSellProceeds(proceedsWad, decimals);
      assert.equal(result.payoutNative, proceedsWad / unit);
      assert.equal(result.paidWad + result.retainedInMarketWad, proceedsWad);
      assert.ok(result.retainedInMarketWad < unit);
      assert.match(result.disclosure, /same transaction/);
      assert.match(result.disclosure, /not a seller claim/);
    }
  }
  for (const [proceeds, decimals] of [[-1n, 6], [2n ** 256n, 6], [1, 6], [1n, 19], [1n, -1]])
    assert.throws(() => presentAmmSellProceeds(proceeds, decimals), /Invalid AMM sell proceeds/);
});

test('AMM replay rounds each sell independently at 6 and 18 decimals and rolls payouts back on reorg', () => {
  const replay = new NodeReplay(31337, [address(1)], { releaseIds: [hash(9)] });
  replay.applyBlock({ chainId: 31337, number: 1n, hash: hash(1), parentHash: hash(0),
    logs: [nodeEvent(1, hash(1), 0)] });
  const registered = { chainId: 31337, number: 2n, hash: hash(2), parentHash: hash(1), logs: [] };
  for (const [offset, decimals] of [[1, 6], [2, 18]]) {
    registered.logs.push(event('MarketFactory', 'MarketCreated', { market: address(100 + offset),
      creator: address(9), question: 'direct sell payout', startTime: 10n, deadline: 100n,
      tokenA: address(6 + offset), tokenADecimals: decimals, bBase: 10n ** 18n,
      adjudicator: address(99), lpPositionId: BigInt(offset), nonce: BigInt(offset - 1) },
    address(81), hash(2), offset));
  }
  replay.applyBlock(registered);
  const sold = { chainId: 31337, number: 3n, hash: hash(3), parentHash: hash(2), logs: [] };
  const replayNode = replay.nodes.get(`${address(1)}:${hash(1)}`);
  for (const [offset, decimals] of [[1, 6], [2, 18]]) {
    const unit = 10n ** BigInt(18 - decimals);
    const cost = 2n * unit - 1n;
    for (let i = 0; i < 3; i++) sold.logs.push(event('AMMEngine', 'PositionTraded', {
      user: address(9), market: address(100 + offset), outcome: 1,
      deltaShares: i === 0 ? 3n * 10n ** 18n : -(10n ** 18n),
      cost, newQYes: BigInt(3 - i) * 10n ** 18n, newQNo: 0n,
    }, address(51), hash(3), sold.logs.length));
  }
  // A zero-proceeds sell creates no token movement but is still a valid event.
  sold.logs.push(event('AMMEngine', 'PositionTraded', { user: address(9), market: address(101),
    outcome: 1, deltaShares: -1n, cost: 0n, newQYes: 0n, newQNo: 0n }, address(51), hash(3), sold.logs.length));
  replay.applyBlock(sold);
  replay.applyBlock(sold);
  for (const [offset, decimals] of [[1, 6], [2, 18]]) {
    const unit = 10n ** BigInt(18 - decimals);
    const asset = `${instrumentKey(replayNode, address(100 + offset), 'AMM')}:${address(6 + offset)}`;
    assert.equal(replay.ammSellPaidNative.get(`${asset}:${address(9)}`), 2n);
    assert.equal(replay.ammSellRetainedWad.get(asset), 2n * (unit - 1n));
  }
  replay.applyBlock({ chainId: 31337, number: 3n, hash: hash(4), parentHash: hash(2), logs: [] });
  assert.equal(replay.ammSellPaidNative.size, 0);
  assert.equal(replay.ammSellRetainedWad.size, 0);
  const unknown = event('AMMEngine', 'PositionTraded', { user: address(9), market: address(999),
    outcome: 1, deltaShares: -1n, cost: 1n, newQYes: 0n, newQNo: 0n }, address(51), hash(5), 0);
  assert.throws(() => replay.applyBlock({ chainId: 31337, number: 4n, hash: hash(5), parentHash: hash(4),
    logs: [unknown] }), /unknown market collateral/);
  assert.equal(replay.ammSellPaidNative.size, 0);
});

test('canonical replay keeps identical-token nodes separate, rolls back forks and survives delisting', () => {
  const replay = new NodeReplay(31337, [address(1)], { releaseIds: [hash(9)] });
  const first = { chainId: 31337, number: 1n, hash: hash(1), parentHash: hash(0),
    logs: [nodeEvent(1, hash(1), 0), nodeEvent(2, hash(1), 1)] };
  replay.applyBlock(first);
  const second = { chainId: 31337, number: 2n, hash: hash(2), parentHash: hash(1), logs: [] };
  for (const offset of [1, 2]) {
    second.logs.push(event('MarketFactory', 'MarketCreated', { market: address(100 + offset),
      creator: address(9), question: 'same topic', startTime: 10n, deadline: 100n,
      tokenA: address(7), tokenADecimals: 6, bBase: 10n ** 18n, adjudicator: address(99),
      lpPositionId: 1n, nonce: 0n }, address(80 + offset), hash(2), offset));
  }
  replay.applyBlock(second);
  const feeLog = event('BookFeeVault', 'RevenueDeposited', { market: address(101), venue: 1,
    token: address(7), feePayer: address(8), amount: 5n }, address(71), hash(3), 0);
  const floorLog = event('AMMEngine', 'FloorClaimed', { user: address(8),
    market: address(101), amount: 20n }, address(51), hash(3), 1);
  const distribution = event('BookFeeVault', 'FeeDistributed', { market: address(101), venue: 1,
    token: address(7), bucket: 1, amount: 5n }, address(71), hash(3), 2);
  const execution = event('OrderEngine', 'OrderExecuted', { market: address(101), user: address(8),
    action: 0, outcome: 1, filled: 10n ** 18n, orderId: 0n, tokenIn: 10n, tokenOut: 0n, fee: 5n },
  address(41), hash(3), 3);
  distribution.transactionHash = execution.transactionHash = feeLog.transactionHash;
  const third = { chainId: 31337, number: 3n, hash: hash(3), parentHash: hash(2), logs: [feeLog, floorLog, distribution, execution] };
  replay.applyBlock(third);
  replay.applyBlock(third);
  assert.deepEqual([...replay.feeLiabilities.values()], [5n]);
  assert.deepEqual([...replay.sponsorFloorPaidWad.values()], [20n]);
  assert.equal(replay.markets.size, 2);
  assert.equal(replay.listedMarkets(new Set([hash(1)])).length, 1);
  assert.equal(replay.markets.size, 2); // Historical and direct exit identity survives.
  replay.applyBlock({ chainId: 31337, number: 3n, hash: hash(4), parentHash: hash(2), logs: [] });
  assert.equal(replay.feeLiabilities.size, 0);
  assert.equal(replay.sponsorFloorPaidWad.size, 0);
  const bad = { chainId: 31337, number: 4n, hash: hash(5), parentHash: hash(4), logs: [feeLog] };
  assert.throws(() => replay.applyBlock(bad), /block mismatch/);
  assert.equal(replay.blocks.length, 3); // Rejected block cannot corrupt the prior projection.
  assert.throws(() => replay.applyBlock({ ...bad, chainId: 1 }), /Wrong replay chain/);
  const excluded = new Set([hash(1)]);
  const laterMarket = event('MarketFactory', 'MarketCreated', { market: address(103),
    creator: address(9), question: 'created after local delisting', startTime: 20n,
    deadline: 100n, tokenA: address(7), tokenADecimals: 6, bBase: 10n ** 18n,
    adjudicator: address(99), lpPositionId: 2n, nonce: 1n }, address(81), hash(6), 0);
  replay.applyBlock({ chainId: 31337, number: 4n, hash: hash(6), parentHash: hash(4),
    logs: [laterMarket] });
  assert.equal(replay.markets.size, 3); // Canonical history still records the excluded node.
  assert.equal(replay.listedMarkets(excluded).length, 1);
  assert.ok([...replay.markets.values()].some(entry => entry.market === address(103)));
});

test('AMM presentation allocates native split dust to OPERATOR even at zero weight', async () => {
  const config = { feeBps: 100, capitalBps: 0, lpBps: 5000, resolutionBps: 5000,
    operatorBps: 0, operatorRecipient: address(9) };
  for (const decimals of [6, 18]) {
    const unit = 10n ** BigInt(18 - decimals);
    const presented = presentAmmConfig(config, { decimals, feeWad: 3n * unit });
    assert.equal(presented.lpNative, 1n);
    assert.equal(presented.resolutionNative, 1n);
    assert.equal(presented.operatorNative, 1n);
    assert.equal(presented.operatorSplitRemainderNative, 1n);
    assert.equal(presented.nominalOperatorNative, 0n);
    assert.match(presented.disclosure, /even when its nominal weight is zero/);
  }
  const growth = { ...config, capitalBps: 2500, lpBps: 4000, resolutionBps: 3500 };
  const result = presentAmmConfig(growth, { decimals: 6, feeWad: 8_000_000_000_003n });
  assert.equal(result.capitalWad, 2_000_000_000_000n);
  assert.equal(result.conversionRemainderWad, 3n);
  assert.equal(result.vaultRevenueNative, 6n);
  assert.equal(result.lpNative + result.resolutionNative + result.operatorNative, 6n);
  assert.equal(result.capitalWad + result.vaultRevenueNative * 10n ** 12n + result.conversionRemainderWad,
    result.feeWad);
  assert.throws(() => presentAmmConfig({ ...config, lpBps: 4999 }, { decimals: 6 }), /Invalid AMM allocation/);
  const c = clientFixture();
  const originalRead = c.readContract;
  c.readContract = args => {
    assert.equal(args.blockNumber, 10n);
    return args.functionName === 'configOf' ? config : originalRead(args);
  };
  const live = await getAmmFeePresentation(c, node, market, 3n * 10n ** 12n);
  assert.equal(live.token, node.bookToken);
  assert.equal(live.operatorNative, 1n);
  assert.equal(live.instrument, instrumentKey(node, market, 'AMM'));
});

test('full CAPITAL allocates the entire fee to AMM capital without a denominator or native remainder', () => {
  const config = { feeBps: 100, capitalBps: 10000, lpBps: 0, resolutionBps: 0,
    operatorBps: 0, operatorRecipient: address(9) };
  for (const decimals of [6, 18]) {
    for (const feeWad of [0n, 1n, 8_000_000_000_003n, 10n ** 18n]) {
      const result = presentAmmConfig(config, { decimals, feeWad });
      assert.equal(result.capitalWad, feeWad);
      for (const field of ['vaultRevenueNative', 'conversionRemainderWad', 'lpNative',
        'resolutionNative', 'operatorNative', 'nominalOperatorNative', 'operatorSplitRemainderNative'])
        assert.equal(result[field], 0n, field);
      assert.match(result.disclosure, /100% CAPITAL retains the entire fee/);
    }
  }
  assert.throws(() => presentAmmConfig({ ...config, lpBps: 1 }, { decimals: 6 }), /Invalid AMM allocation/);
});

test('100% trading-fee presentation discloses doubled buys and zero-proceeds sells for both allocations', () => {
  for (const capitalBps of [0, 10000]) {
    const config = { feeBps: 10000, capitalBps, lpBps: 10000 - capitalBps,
      resolutionBps: 0, operatorBps: 0, operatorRecipient: address(9) };
    for (const decimals of [6, 18]) {
      const result = presentAmmConfig(config, { decimals, feeWad: 10n ** 18n });
      assert.match(result.disclosure, /buys cost twice the pre-fee base amount before native rounding/);
      assert.match(result.disclosure, /sells return zero net proceeds/);
      assert.match(result.disclosure, /positive minimum output rejects those sells/);
      assert.equal(result.capitalWad, capitalBps === 10000 ? 10n ** 18n : 0n);
    }
  }
});


test('covered SELL binds inventory, cash and both expiries; simulation exposes native result', async () => {
  const c = clientFixture();
  const request = { account: address(9), action: 'SELL', outcome: 'YES', priceTick: 800,
    amount: 100n * 10n ** 18n, rest: true, postOnly: true, expiry: 900n };
  const prepared = await prepareBookOrder(c, node, market, request);
  const decoded = decodeFunctionData({ abi: abi.OrderEngine, data: prepared.transaction.data });
  assert.equal(decoded.functionName, 'placeOrder');
  assert.equal(decoded.args[1].outcome, 1);
  assert.equal(decoded.args[1].action, 1);
  assert.equal(decoded.args[1].validUntil, 220n);
  assert.equal(decoded.args[1].expiry, 900n);
  assert.equal(decoded.args[1].rest, true);
  assert.equal(decoded.args[1].postOnly, true);
  assert.equal(decoded.args[1].maxTokenIn, 0n);
  assert.equal(prepared.approval.amount, 0n);
  assert.equal(prepared.expiryEnforcedOnChain, true);
  c.simulateContract = async args => {
    assert.equal(args.account, address(9));
    assert.equal(args.functionName, 'placeOrder');
    return { result: { filled: 100n, orderId: 0n, tokenIn: 0n, tokenOut: 79n, fee: 1n } };
  };
  assert.equal((await simulatePreparedOrder(c, prepared)).tokenOut, 79n);
  for (const invalid of [{ action: 'ESCROW' }, { matchLimit: 0 }, { minTokenOut: -1n },
    { priceTick: 1000 }, { postOnly: true, rest: false }, { expiry: 1001n },
    { maxTokenIn: 2n ** 256n - 1n }, { amount: 101n * 10n ** 18n }])
    await assert.rejects(prepareBookOrder(c, node, market, { ...request, ...invalid }));
  c.state.timestamp = 221n;
  await assert.rejects(simulatePreparedOrder(c, prepared), /expired/);
});

test('native split/merge prepares exact cash and preserves post-cutoff exits', async () => {
  const c = clientFixture();
  const amount = 100n * 10n ** 18n;
  const split = await prepareSplit(c, node, market, address(9), amount);
  assert.equal(split.approval.amount, 100000000n);
  const decoded = decodeFunctionData({ abi: abi.OrderEngine, data: split.transaction.data });
  assert.equal(decoded.functionName, 'split');
  assert.deepEqual(decoded.args, [market, amount, 100000000n, 220n]);
  const inventory = await getBookInventory(c, node, market, address(9));
  assert.equal(inventory.yesAvailable, amount);
  assert.equal(inventory.noAvailable, amount);
  assert.equal(inventory.net, 0n); // Gross holdings survive zero exposure.
  assert.equal(inventory.invalidHalfNativeUnit, 0);
  c.state.open = false;
  c.state.timestamp = 1100n;
  const merge = await prepareMerge(c, node, market, address(9), amount);
  assert.equal(merge.deadline, 1220n);
  assert.equal(merge.approval.amount, 0n);
  assert.deepEqual(await validatePrepared(c, merge), merge.transaction);
  await assert.rejects(prepareSplit(c, node, market, address(9), amount), /Trading closed/);
  const readBefore = c.readContract;
  c.readContract = args => args.functionName === 'getInventory'
    ? [amount, amount, 1n, 0n, 0n] : readBefore(args);
  await assert.rejects(prepareMerge(c, node, market, address(9), amount), /available complete sets/);
});

test('maintenance is bounded, identity-checked and remains available after settlement', async () => {
  const c = clientFixture();
  c.state.open = false;
  const tx = await prepareHeadMaintenance(c, node, market, 1, 600, 128);
  const decoded = decodeFunctionData({ abi: abi.OrderEngine, data: tx.data });
  assert.equal(decoded.functionName, 'advanceHead');
  assert.deepEqual(decoded.args.slice(1), [1, 600, 128n]);
  await assert.rejects(prepareHeadMaintenance(c, node, market, 1, 600, 0), /Invalid maintenance/);
  await assert.rejects(prepareHeadMaintenance(c, node, market, 1, 600, 1025), /Invalid maintenance/);
  c.state.marketFactory = address(99);
  await assert.rejects(prepareHeadMaintenance(c, node, market, 1, 600), /another node/);
});
