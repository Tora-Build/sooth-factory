import assert from 'node:assert/strict';
import test from 'node:test';
import { createPublicClient, custom, encodeAbiParameters, encodeEventTopics } from 'viem';
import { abi, instrumentKey } from '../../sdk/index.mjs';
import { NodeReplay } from '../../sdk/replay.mjs';

const address = n => `0x${n.toString(16).padStart(40, '0')}`;
const hash = n => `0x${n.toString(16).padStart(64, '0')}`;
const trader = address(900);
const token = address(901);
const node = (factory, offset) => ({ chainId: 31337, factory: address(factory),
  nodeId: hash(1), releaseId: hash(9), nodeAdmin: address(offset + 10),
  protocolAuthority: address(902), bookToken: token, deployer: address(offset + 20),
  roles: address(offset + 30), book: address(offset + 40), amm: address(offset + 50),
  ammVault: address(offset + 60), bookVault: address(offset + 70),
  marketFactory: address(offset + 80) });
const first = node(1, 100);
const second = node(2, 200);
const marketA = address(501);
const marketB = address(502);

function event(contract, name, args, emitter, blockHash, logIndex) {
  const item = abi[contract].find(entry => entry.type === 'event' && entry.name === name);
  assert.ok(item, `${contract}.${name} is in the canonical ABI`);
  const plain = item.inputs.filter(input => !input.indexed);
  return { address: emitter, blockHash, transactionHash: hash(1000 + logIndex), logIndex,
    topics: encodeEventTopics({ abi: [item], eventName: name, args }),
    data: encodeAbiParameters(plain, plain.map(input => args[input.name])) };
}

function block(number, blockId, parentId, specifications) {
  const blockHash = hash(blockId);
  return { chainId: 31337, number: BigInt(number), hash: blockHash, parentHash: hash(parentId),
    logs: specifications.map(([contract, name, args, emitter, transactionHash], index) =>
      ({ ...event(contract, name, args, emitter, blockHash, index),
        ...(transactionHash ? { transactionHash } : {}) })) };
}

function fixture() {
  const replay = new NodeReplay(31337, [first.factory, second.factory], { releaseIds: [hash(9)] });
  replay.applyBlock(block(1, 1, 0, [first, second].map(n =>
    ['NodeFactory', 'NodeCreated', n, n.factory])));
  return replay;
}

const bookEvent = (name, args, n = first, market = marketA) =>
  ['OrderEngine', name, { market, ...args }, n.book];
const accountKey = (n = first, market = marketA) => `${instrumentKey(n, market, 'BOOK')}:${trader}`;
const WAD = 10n ** 18n;
const bookFee = (n, market, payer, amount, resolution = 0n, tx = hash(800)) => [
  ['BookFeeVault', 'RevenueDeposited', { market, venue: 1, token, feePayer: payer, amount }, n.bookVault, tx],
  ...(resolution > 0n ? [['BookFeeVault', 'FeeDistributed', { market, venue: 1, token,
    bucket: 0, amount: resolution }, n.bookVault, tx]] : []),
  ...(amount > resolution ? [['BookFeeVault', 'FeeDistributed', { market, venue: 1, token,
    bucket: 1, amount: amount - resolution }, n.bookVault, tx]] : []),
  ['OrderEngine', 'OrderExecuted', { market, user: payer, action: 0, outcome: 1,
    filled: WAD, orderId: 0n, tokenIn: amount + 1n, tokenOut: 0n, fee: amount }, n.book, tx],
];
const taker = address(903);
const inventory = (values = {}, n = first, market = marketA) => bookEvent('InventoryChanged', {
  user: trader, yesOwned: 0n, noOwned: 0n, yesReserved: 0n, noReserved: 0n,
  cashReserved: 0n, ...values,
}, n, market);
const placed = (values = {}, n = first, market = marketA) => bookEvent('OrderPlaced', {
  maker: trader, orderId: 1n, action: 1, outcome: 1, yesTick: 520,
  amount: 100n * WAD, expiry: 1000n, cashReserved: 0n, ...values,
}, n, market);
const filled = values => bookEvent('OrderFilled', { orderId: 1n, taker,
  amount: 40n * WAD, yesTick: 520, settlementType: 0, remaining: 60n * WAD,
  cashReserved: 0n, ...values });
const cancelled = (values = {}) => bookEvent('OrderCancelled', {
  maker: trader, orderId: 1n, amount: 60n * WAD, cashRefund: 0n, ...values,
});

test('the v7 replay requires an explicit approved release and rejects another release atomically', () => {
  assert.throws(() => new NodeReplay(31337, [first.factory]), /Approved replay release IDs required/);
  assert.throws(() => new NodeReplay(31337, [first.factory], { releaseIds: [] }), /release IDs required/);
  const replay = fixture();
  const unknown = { ...node(1, 300), nodeId: hash(3), releaseId: hash(10) };
  assert.throws(() => replay.applyBlock(block(2, 2, 1, [
    ['NodeFactory', 'NodeCreated', unknown, first.factory],
  ])), /Unapproved replay release/);
  assert.equal(replay.blocks.length, 1);
  assert.equal(replay.nodes.size, 2);
});

test('equal collateral and colliding node IDs retain independent factory and venue identities', () => {
  const replay = fixture();
  assert.equal(replay.nodes.size, 2);
  replay.applyBlock(block(2, 2, 1, [
    ['AmmFeeVault', 'RevenueDeposited', { market: marketA, venue: 0, token,
      feePayer: trader, amount: 3n }, first.ammVault],
    ...bookFee(first, marketA, trader, 5n),
    ...bookFee(second, marketB, trader, 7n),
  ]));
  assert.equal(replay.feeLiabilities.get(`${instrumentKey(first, marketA, 'AMM')}:${token}`), 3n);
  assert.equal(replay.feeLiabilities.get(`${instrumentKey(first, marketA, 'BOOK')}:${token}`), 5n);
  assert.equal(replay.feeLiabilities.get(`${instrumentKey(second, marketB, 'BOOK')}:${token}`), 7n);
  assert.deepEqual(replay.events.filter(entry => entry.eventName === 'RevenueDeposited')
    .map(entry => [entry.factory, entry.nodeId]),
    [[first.factory, first.nodeId], [first.factory, first.nodeId], [second.factory, second.nodeId]]);
});

test('fee reconciliation binds transaction, market and actual payer and fails atomically on omissions', () => {
  for (const mutate of [
    rows => { rows.at(-1)[2].fee += 1n; },
    rows => { rows.at(-1)[2].user = taker; },
    rows => { rows.at(-1)[2].market = marketB; },
    rows => { rows.at(-1)[4] = hash(801); },
    rows => { rows.pop(); },
    rows => { rows.splice(1, 1); },
  ]) {
    const replay = fixture();
    const rows = bookFee(first, marketA, trader, 7n, 2n);
    mutate(rows);
    assert.throws(() => replay.applyBlock(block(2, 2, 1, rows)), /fee|distribution/);
    assert.equal(replay.blocks.length, 1);
    assert.equal(replay.bookRefunds.size, 0);
  }
  const replay = fixture();
  const rows = bookFee(first, marketA, trader, 7n, 2n);
  rows.at(-1)[2].action = 1; // Fee paid from sale proceeds has the same payer attribution.
  replay.applyBlock(block(2, 2, 1, [...rows,
    ...bookFee(first, marketA, trader, 3n, 1n),
    ...bookFee(first, marketA, taker, 5n, 1n),
  ]));
  assert.equal(replay.bookExecutionFees.get(`${hash(800)}:${instrumentKey(first, marketA, 'BOOK')}:${token}:${trader}`), 10n);
  assert.deepEqual(replay.bookRefundState(first, marketA, trader),
    { mode: 'CONTINGENT', refundableNative: 3n, claimableNative: 0n });
  assert.equal(replay.bookRefundState(first, marketA, taker).refundableNative, 1n);
});

test('timeout payer refunds, adjudicated INVALID exclusion and reorgs preserve conditional ownership', () => {
  const replay = fixture();
  replay.applyBlock(block(2, 2, 1, [
    ...bookFee(first, marketA, trader, 7n, 2n), ...bookFee(first, marketB, trader, 5n, 3n),
  ]));
  const finalized = (market, kind) => ['BookFeeVault', 'MarketFinalized',
    { market, venue: 1, settlementKind: kind }, first.bookVault];
  const claim = (market, recipient, amount) => ['BookFeeVault', 'Claimed',
    { market, venue: 1, token, bucket: 0, recipient, amount }, first.bookVault];
  assert.throws(() => replay.applyBlock(block(3, 30, 2, [claim(marketA, trader, 2n)])),
    /before vault finalization/);
  replay.applyBlock(block(3, 3, 2, [finalized(marketA, 2), finalized(marketB, 1)]));
  assert.deepEqual(replay.bookRefundState(first, marketA, trader),
    { mode: 'TIMEOUT', refundableNative: 2n, claimableNative: 2n });
  assert.deepEqual(replay.bookRefundState(first, marketB, trader),
    { mode: 'ADJUDICATED', refundableNative: 0n, claimableNative: 0n });
  assert.throws(() => replay.applyBlock(block(4, 40, 3, [claim(marketA, taker, 2n)])),
    /original payer entitlement/);
  replay.applyBlock(block(4, 4, 3, [claim(marketA, trader, 2n), claim(marketB, address(950), 3n)]));
  assert.equal(replay.bookRefundState(first, marketA, trader).claimableNative, 0n);
  assert.equal(replay.bookRefundState(first, marketB, trader).refundableNative, 0n);
  replay.applyBlock(block(3, 33, 2, []));
  assert.deepEqual(replay.bookRefundState(first, marketA, trader),
    { mode: 'CONTINGENT', refundableNative: 2n, claimableNative: 0n });
  assert.equal(replay.bookRefundState(first, marketB, trader).refundableNative, 3n);
});

test('surplus replay requires the emitter venue and does not create or consume fee liabilities', () => {
  const replay = fixture();
  const sweep = venue => ['AmmFeeVault', 'SurplusSwept',
    { venue, token, recipient: trader, amount: 9n }, first.ammVault];
  assert.throws(() => replay.applyBlock(block(2, 2, 1, [sweep(1)])), /Vault venue mismatch/);
  replay.applyBlock(block(2, 3, 1, [sweep(0)]));
  assert.equal([...replay.surplusSwept.values()][0], 9n);
  assert.equal(replay.feeLiabilities.size, 0);
  replay.applyBlock(block(2, 4, 1, []));
  assert.equal(replay.surplusSwept.size, 0);
});

test('conflicting emitter ownership rejects the whole block without damaging the canonical projection', () => {
  const replay = fixture();
  const conflicting = { ...node(1, 300), nodeId: hash(3), book: first.book };
  assert.throws(() => replay.applyBlock(block(2, 2, 1, [
    ['NodeFactory', 'NodeCreated', conflicting, first.factory],
  ])), /Emitter already assigned/);
  assert.equal(replay.blocks.length, 1);
  assert.equal(replay.nodes.size, 2);
  assert.equal(replay.emitters.get(first.book).node.marketFactory.toLowerCase(), first.marketFactory);
});

test('split inventory funds two sell quotes, partial fills and merges replay exactly across a reorg', () => {
  const replay = fixture();
  replay.applyBlock(block(2, 2, 1, [
    bookEvent('Split', { user: trader, amount: 100n * WAD, collateral: 100_000_000n }),
    inventory({ yesOwned: 100n * WAD, noOwned: 100n * WAD }),
    placed(),
    placed({ orderId: 2n, outcome: 0, yesTick: 480 }),
    inventory({ yesOwned: 100n * WAD, noOwned: 100n * WAD,
      yesReserved: 100n * WAD, noReserved: 100n * WAD }),
  ]));
  assert.equal(replay.positions.get(accountKey()), 0n);
  assert.equal(replay.inventories.get(accountKey()).yesOwned, 100n * WAD);
  assert.equal(replay.inventories.get(accountKey()).yesAvailable, 0n);
  assert.equal(replay.inventories.get(accountKey()).noAvailable, 0n);

  const fills = block(3, 3, 2, [filled(),
    filled({ orderId: 2n, yesTick: 480, settlementType: 1 }),
    inventory({ yesOwned: 60n * WAD, noOwned: 60n * WAD,
      yesReserved: 60n * WAD, noReserved: 60n * WAD }),
    inventory({ user: taker, yesOwned: 40n * WAD, noOwned: 40n * WAD }),
  ]);
  replay.applyBlock(fills);
  replay.applyBlock(fills);
  assert.equal(replay.orders.get(`${instrumentKey(first, marketA, 'BOOK')}:1`).remaining, 60n * WAD);
  assert.equal(replay.inventories.get(`${instrumentKey(first, marketA, 'BOOK')}:${taker}`).yesOwned, 40n * WAD);
  assert.equal(replay.events.filter(entry => entry.eventName === 'OrderFilled').length, 2);

  replay.applyBlock(block(4, 4, 3, [cancelled(), cancelled({ orderId: 2n }),
    bookEvent('Merged', { user: trader, amount: 60n * WAD, collateral: 60_000_000n }),
    inventory(),
    bookEvent('Merged', { user: taker, amount: 40n * WAD, collateral: 40_000_000n }),
    inventory({ user: taker }),
  ]));
  assert.equal(replay.inventories.get(accountKey()).yesOwned, 0n);
  assert.ok([...replay.orders.values()].every(order => order.status === 'CANCELLED'));

  replay.applyBlock(block(4, 40, 3, []));
  assert.equal(replay.inventories.get(accountKey()).yesOwned, 60n * WAD);
  assert.equal(replay.inventories.get(accountKey()).yesReserved, 60n * WAD);
  assert.ok([...replay.orders.values()].every(order => order.status === 'OPEN'));
  assert.equal(replay.events.filter(entry => entry.eventName === 'Merged').length, 0);
  assert.throws(() => replay.applyBlock(block(5, 5, 40, [
    inventory({ yesOwned: 60n * WAD, yesReserved: 61n * WAD }),
  ])), /Reserved inventory exceeds ownership/);
  assert.equal(replay.blocks.at(-1).hash, hash(40));
  assert.equal(replay.inventories.get(accountKey()).yesReserved, 60n * WAD);
});

test('buy reservations use exact native post-state and deferred payouts stay isolated by node and book', () => {
  const replay = fixture();
  replay.applyBlock(block(2, 2, 1, [
    placed({ action: 0, amount: 10n * WAD, yesTick: 400, cashReserved: 4_000_000n }),
    inventory({ cashReserved: 4_000_000n }),
    placed({ action: 0, amount: 10n * WAD, yesTick: 400, cashReserved: 4_000_000n }, second, marketB),
    inventory({ cashReserved: 4_000_000n }, second, marketB),
  ]));
  assert.equal(replay.orders.size, 2); // Both nodes issue order ID 1 to the same maker.
  replay.applyBlock(block(3, 3, 2, [
    filled({ amount: 3n * WAD, remaining: 7n * WAD, yesTick: 400,
      cashReserved: 2_800_000n, settlementType: 2 }),
    inventory({ yesOwned: 3n * WAD, cashReserved: 2_800_000n }),
  ]));
  assert.equal(replay.inventories.get(accountKey()).cashReserved, 2_800_000n);
  assert.equal(replay.inventories.get(accountKey(second, marketB)).cashReserved, 4_000_000n);
  replay.applyBlock(block(4, 4, 3, [
    cancelled({ amount: 7n * WAD, cashRefund: 2_800_000n }),
    inventory({ yesOwned: 3n * WAD }),
    bookEvent('PayoutDeferred', { recipient: trader, amount: 2_800_000n }),
    bookEvent('PayoutDeferred', { recipient: trader, amount: 7n }, second, marketB),
  ]));
  const deferredKey = n => `${n.chainId}:${n.factory}:${n.nodeId}:${n.book}:${trader}`;
  assert.equal(replay.deferred.get(deferredKey(first)), 2_800_000n);
  assert.equal(replay.deferred.get(deferredKey(second)), 7n);
  replay.applyBlock(block(5, 5, 4, [bookEvent('DeferredClaimed', { recipient: trader, amount: 2_800_000n })]));
  assert.equal(replay.deferred.get(deferredKey(first)), 0n);
  assert.equal(replay.deferred.get(deferredKey(second)), 7n);
  assert.throws(() => replay.applyBlock(block(6, 6, 5, [
    bookEvent('DeferredClaimed', { recipient: trader, amount: 1n }),
  ])), /Claim exceeds replayed deferred collateral/);
  replay.applyBlock(block(5, 50, 4, []));
  assert.equal(replay.deferred.get(deferredKey(first)), 2_800_000n);
});

test('settling free holdings leaves a live sell reservation and its net exposure until cancellation', () => {
  const replay = fixture();
  replay.applyBlock(block(2, 2, 1, [
    placed({ amount: 1n * WAD }),
    inventory({ yesOwned: 3n * WAD, yesReserved: 1n * WAD }),
  ]));
  replay.applyBlock(block(3, 3, 2, [
    bookEvent('PositionSettled', { user: trader, payout: 2_000_000n }),
    inventory({ yesOwned: 1n * WAD, yesReserved: 1n * WAD }),
  ]));
  assert.equal(replay.positions.get(accountKey()), WAD);
  assert.equal(replay.inventories.get(accountKey()).yesAvailable, 0n);
  replay.applyBlock(block(4, 4, 3, [
    cancelled({ amount: WAD }),
    bookEvent('PositionSettled', { user: trader, payout: 1_000_000n }),
    inventory(),
  ]));
  assert.equal(replay.positions.get(accountKey()), 0n);
  assert.equal(replay.events.filter(entry => entry.eventName === 'PositionSettled').length, 2);
});

test('a complementary sell fill burns gross inventory and closes the order without phantom signed positions', () => {
  const replay = fixture();
  replay.applyBlock(block(2, 2, 1, [
    placed({ outcome: 0, amount: 10n * WAD, yesTick: 480 }),
    inventory({ noOwned: 10n * WAD, noReserved: 10n * WAD }),
    inventory({ user: taker, yesOwned: 10n * WAD }),
  ]));
  assert.equal(replay.positions.get(accountKey()), -10n * WAD);
  replay.applyBlock(block(3, 3, 2, [
    filled({ amount: 10n * WAD, remaining: 0n, yesTick: 480, settlementType: 3 }),
    inventory(), inventory({ user: taker }),
  ]));
  assert.equal(replay.positions.get(accountKey()), 0n);
  assert.equal(replay.positions.get(`${instrumentKey(first, marketA, 'BOOK')}:${taker}`), 0n);
  assert.equal(replay.orders.get(`${instrumentKey(first, marketA, 'BOOK')}:1`).status, 'FILLED');
  assert.equal(replay.events.find(entry => entry.eventName === 'OrderFilled').args.settlementType, 3);
});

test('partial INVALID claims retain half-native entitlement across reservation release and reorg', () => {
  const replay = fixture();
  const threeNativeShares = 3n * 10n ** 12n;
  replay.applyBlock(block(2, 2, 1, [
    placed({ outcome: 0, amount: threeNativeShares, yesTick: 500 }),
    inventory({ yesOwned: threeNativeShares, noOwned: threeNativeShares,
      noReserved: threeNativeShares }),
  ]));
  replay.applyBlock(block(3, 3, 2, [
    bookEvent('InvalidRemainderChanged', { user: trader, halfNativeUnit: 1 }),
    inventory({ noOwned: threeNativeShares, noReserved: threeNativeShares }),
    bookEvent('PositionSettled', { user: trader, payout: 1n }),
  ]));
  assert.equal(replay.invalidRemainders.get(accountKey()), 1);
  assert.equal(replay.deferred.size, 0);
  replay.applyBlock(block(4, 4, 3, [
    cancelled({ amount: threeNativeShares }),
    bookEvent('InvalidRemainderChanged', { user: trader, halfNativeUnit: 0 }),
    inventory(), bookEvent('PositionSettled', { user: trader, payout: 2n }),
  ]));
  assert.equal(replay.invalidRemainders.get(accountKey()), 0);
  assert.equal(replay.positions.get(accountKey()), 0n);
  assert.equal(replay.events.filter(entry => entry.eventName === 'PositionSettled')
    .reduce((total, entry) => total + entry.args.payout, 0n), 3n);
  replay.applyBlock(block(4, 40, 3, []));
  assert.equal(replay.invalidRemainders.get(accountKey()), 1);
  assert.equal(replay.inventories.get(accountKey()).noReserved, threeNativeShares);
});

test('confirmed INVALID settlement receipt anchors replay despite a stale cached block number', async () => {
  const replay = fixture();
  const unit = 10n ** 12n;
  const history = [
    block(2, 2, 1, [
      bookEvent('Split', { user: trader, amount: 5n * unit, collateral: 5n }),
      inventory({ yesOwned: 5n * unit, noOwned: 5n * unit }),
      placed({ amount: 5n * unit, yesTick: 600 }),
      placed({ orderId: 2n, outcome: 0, amount: 2n * unit, yesTick: 400 }),
      inventory({ yesOwned: 5n * unit, noOwned: 5n * unit,
        yesReserved: 5n * unit, noReserved: 2n * unit }),
    ]),
    block(3, 3, 2, [
      bookEvent('InvalidRemainderChanged', { user: trader, halfNativeUnit: 1 }),
      inventory({ yesOwned: 5n * unit, noOwned: 2n * unit,
        yesReserved: 5n * unit, noReserved: 2n * unit }),
      bookEvent('PositionSettled', { user: trader, payout: 1n }),
    ]),
    block(4, 4, 3, [cancelled({ amount: 5n * unit }),
      inventory({ yesOwned: 5n * unit, noOwned: 2n * unit, noReserved: 2n * unit }),
    ]),
    block(5, 5, 4, [cancelled({ orderId: 2n, amount: 2n * unit }),
      inventory({ yesOwned: 5n * unit, noOwned: 2n * unit }),
    ]),
    block(6, 6, 5, [
      bookEvent('Merged', { user: trader, amount: 2n * unit, collateral: 2n }),
      inventory({ yesOwned: 3n * unit }),
    ]),
    block(7, 7, 6, [
      bookEvent('InvalidRemainderChanged', { user: trader, halfNativeUnit: 0 }),
      inventory(), bookEvent('PositionSettled', { user: trader, payout: 2n }),
    ]),
  ];
  let liveHead = 6n;
  const readHeights = [];
  // Use the installed client's actual cache and receipt behavior. Confirming
  // the final transaction does not invalidate an earlier cached block number.
  const client = createPublicClient({ cacheTime: 60_000, transport: custom({
    async request({ method, params }) {
      if (method === 'eth_blockNumber') return `0x${liveHead.toString(16)}`;
      if (method === 'eth_getTransactionReceipt') return {
        blockNumber: '0x7', blockHash: hash(7), transactionHash: hash(1007),
        transactionIndex: '0x0', status: '0x1', type: '0x2', from: trader, to: first.book,
        cumulativeGasUsed: '0x1', gasUsed: '0x1', effectiveGasPrice: '0x1',
        logs: [], logsBloom: `0x${'00'.repeat(256)}`, contractAddress: null,
      };
      if (method === 'eth_call') {
        const height = params[1] === 'latest' ? liveHead : BigInt(params[1]);
        readHeights.push(height);
        return encodeAbiParameters([{ type: 'int256' }], [height < 7n ? 3n * unit : 0n]);
      }
      throw new Error(`Unexpected RPC method ${method}`);
    },
  }) });
  assert.equal(await client.getBlockNumber(), 6n);
  liveHead = 7n;
  const receipt = await client.waitForTransactionReceipt({ hash: hash(1007) });
  assert.equal(receipt.blockNumber, 7n);
  const cachedTip = await client.getBlockNumber();
  assert.equal(cachedTip, 6n);
  for (const entry of history.filter(entry => entry.number <= cachedTip)) replay.applyBlock(entry);
  const query = { address: first.book, abi: abi.OrderEngine, functionName: 'getNet', args: [marketA, trader] };
  assert.equal(replay.positions.get(accountKey()), 3n * unit);
  assert.equal(await client.readContract(query), 0n); // The original mismatch.
  for (const entry of history.filter(entry => entry.number > cachedTip
    && entry.number <= receipt.blockNumber)) replay.applyBlock(entry);
  assert.equal(replay.blocks.at(-1).hash, receipt.blockHash);
  assert.equal(replay.positions.get(accountKey()),
    await client.readContract({ ...query, blockNumber: receipt.blockNumber }));
  assert.deepEqual(readHeights, [7n, 7n]);
  assert.equal(replay.inventories.get(accountKey()).yesOwned, 0n);
  assert.equal(replay.inventories.get(accountKey()).noOwned, 0n);
  assert.equal(replay.invalidRemainders.get(accountKey()), 0);
  assert.equal(replay.events.filter(entry => entry.eventName === 'PositionSettled')
    .reduce((total, entry) => total + entry.args.payout, 0n)
    + replay.events.find(entry => entry.eventName === 'Merged').args.collateral, 5n);
});

test('incomplete order or reservation history fails atomically instead of exposing false available inventory', () => {
  const replay = fixture();
  assert.throws(() => replay.applyBlock(block(2, 2, 1, [filled()])), /unknown or inactive order/);
  assert.throws(() => replay.applyBlock(block(2, 3, 1, [placed(),
    inventory({ yesOwned: 100n * WAD }),
  ])), /reservations disagree/);
  assert.throws(() => replay.applyBlock(block(2, 4, 1, [placed()])), /Missing inventory snapshot/);
  assert.equal(replay.blocks.length, 1);
  assert.equal(replay.orders.size, 0);
  assert.equal(replay.inventories.size, 0);
});
