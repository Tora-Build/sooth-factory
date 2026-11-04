import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, decodeAbiParameters,
  decodeEventLog, encodeFunctionData, erc20Abi, parseAbi } from 'viem';
import { mnemonicToAccount } from 'viem/accounts';
import { anvil } from 'viem/chains';
import { abi, verifyNode, prepareSponsorAddition, prepareBookOrder,
  validatePrepared, approvalTransaction, instrumentKey, prepareSplit, prepareMerge,
  simulatePreparedOrder, prepareCancelById, prepareHeadMaintenance,
  presentAmmSellProceeds } from '../../sdk/index.mjs';
import { NodeReplay } from '../../sdk/replay.mjs';

const url = new URL(process.env.SOOTH_LOCAL_RPC || 'http://127.0.0.1:18545');
assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), 'Loopback RPC only');
assert.equal(url.username + url.password, '', 'No credential-bearing endpoints');
const client = createPublicClient({ chain: anvil, transport: http(url.href) });
assert.equal(await client.getChainId(), 31337, 'Local chain only');
assert.match(await client.request({ method: 'web3_clientVersion' }), /anvil/i);
const path = 'deployments/local/client-workflow.json';
const manifest = JSON.parse(readFileSync('deployments/local/factory-smoke.json', 'utf8'));
const stringify = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
const accounts = [10, 11].map(addressIndex => mnemonicToAccount(
  'test test test test test test test test test test test junk', { addressIndex }));
const wallets = accounts.map(account => createWalletClient({ account, chain: anvil, transport: http(url.href) }));
const balances = async () => Promise.all(accounts.map(a => client.readContract({
  address: manifest.stable, abi: erc20Abi, functionName: 'balanceOf', args: [a.address] })));
const requestType = abi.NodeFactory.find(x => x.name === 'beginNode').inputs[0];
const [request] = decodeAbiParameters([requestType], manifest.requestA);
const nodeId = await client.readContract({ address: manifest.factory, abi: abi.NodeFactory,
  functionName: 'nodeId', args: [request] });
const node = await verifyNode(client, { chainId: 31337, factory: manifest.factory,
  nodeId, releaseId: request.releaseId });
const market = manifest.markets[0];
const transactions = [];
async function send(index, transaction, label, source = 'SDK_PREPARED') {
  assert.ok(['SDK_PREPARED', 'DIRECT_CONTRACT'].includes(source));
  const estimate = await client.estimateGas({ account: accounts[index], ...transaction });
  const gas = estimate * 3n / 2n + 50000n;
  assert.ok(gas <= 16777216n, 'Transaction exceeds EIP-7825 cap');
  const hash = await wallets[index].sendTransaction({ ...transaction, gas });
  const receipt = await client.waitForTransactionReceipt({ hash });
  assert.equal(receipt.status, 'success', label);
  transactions.push({ label, source, hash, gas, gasUsed: receipt.gasUsed, blockNumber: receipt.blockNumber });
  return receipt;
}
function transactionCounts(rows) {
  assert.ok(rows.every(row => ['SDK_PREPARED', 'DIRECT_CONTRACT'].includes(row.source)));
  return { total: rows.length,
    sdkPrepared: rows.filter(row => row.source === 'SDK_PREPARED').length,
    directContract: rows.filter(row => row.source === 'DIRECT_CONTRACT').length };
}
async function executeOrder(index, params, targetMarket = market) {
  const prepared = await prepareBookOrder(client, node, targetMarket, { account: accounts[index].address, ...params });
  if (prepared.approval?.amount > 0n) await send(index, approvalTransaction(prepared), 'bounded book approval');
  const preview = await simulatePreparedOrder(client, prepared);
  const before = await balances();
  const receipt = await send(index, await validatePrepared(client, prepared), 'SDK book order');
  const after = await balances();
  assert.equal(before[index] - after[index], preview.tokenIn - preview.tokenOut, 'Native settlement matches SDK simulation');
  return { prepared, receipt, debitNative: before[index] - after[index], preview };
}

async function convert(index, kind, amount, targetMarket = market) {
  const prepare = kind === 'split' ? prepareSplit : prepareMerge;
  const prepared = await prepare(client, node, targetMarket, accounts[index].address, amount);
  if (prepared.approval?.amount > 0n) await send(index, approvalTransaction(prepared), 'bounded split approval');
  const before = await balances();
  const receipt = await send(index, await validatePrepared(client, prepared), `SDK complete-set ${kind}`);
  const after = await balances();
  assert.equal(before[index] - after[index], (kind === 'split' ? amount : -amount) / 10n ** 12n);
  return { receipt, debitNative: before[index] - after[index] };
}

async function inventory(index) {
  const [yesOwned, noOwned, yesReserved, noReserved, cashReserved] = await client.readContract({
    address: node.book, abi: abi.OrderEngine, functionName: 'getInventory', args: [market, accounts[index].address] });
  return { yesOwned, noOwned, yesReserved, noReserved, cashReserved };
}

async function recoverQuotes() {
  const ids = [];
  const headProbe = steps => client.simulateContract({ account: accounts[0], address: node.book,
    abi: abi.OrderEngine, functionName: 'advanceHead', args: [market, 1, 600, steps] });
  assert.equal((await headProbe(1n)).result, 0n, 'Fixture starts with an empty head');
  const terms = { account: accounts[1].address, action: 'BUY', outcome: 'NO', priceTick: 400, amount: 10n ** 18n };
  const first = await prepareBookOrder(client, node, market, terms);
  await send(1, approvalTransaction({ ...first,
    approval: { ...first.approval, amount: 40n * first.approval.amount } }), 'bounded queue fixture approval');
  for (let i = 0; i < 40; i++) {
    const prepared = await prepareBookOrder(client, node, market, terms);
    const receipt = await send(1, await validatePrepared(client, prepared), 'rest queue fixture');
    const placed = receipt.logs.map(log => {
      try { return decodeEventLog({ abi: abi.OrderEngine, ...log }); } catch { return null; }
    }).find(event => event?.eventName === 'OrderPlaced');
    ids.push(placed.args.orderId);
  }
  for (const id of ids.reverse()) await send(1, { to: node.book,
    data: encodeFunctionData({ abi: abi.OrderEngine, functionName: 'cancelById', args: [id] }) },
  'cancel queue fixture', 'DIRECT_CONTRACT');
  // All 40 entries are dead. Simulating one step observes current head + 1;
  // this eth_call does not persist its advance. Automatic cancellation cleanup
  // has already consumed 32 entries before the measured maintenance transaction.
  const simulatedOneStepHead = (await headProbe(1n)).result;
  assert.equal(simulatedOneStepHead, 33n);
  const headBefore = simulatedOneStepHead - 1n;
  const quote = { address: node.book, abi: abi.OrderEngine, functionName: 'getBestTick', args: [market, 1] };
  const beforeGas = await client.estimateContractGas({ ...quote, account: accounts[0] });
  assert.equal(await client.readContract(quote), 1000);
  await send(0, await prepareHeadMaintenance(client, node, market, 1, 600, 16), 'SDK permissionless head maintenance');
  const headAfter = (await headProbe(1n)).result;
  assert.equal(headAfter, 40n);
  const afterGas = await client.estimateContractGas({ ...quote, account: accounts[0] });
  assert.equal(await client.readContract(quote), 1000);
  assert.ok(afterGas < beforeGas, 'Maintenance must reduce quote gas');
  return { beforeGas, afterGas, createdOrders: ids.length, cancelledOrders: ids.length,
    automaticallyAdvancedEntries: Number(headBefore),
    residualSpentEntriesBefore: ids.length - Number(headBefore), residualSpentEntriesAfter: 0,
    headBefore, headAfter, simulatedOneStepHead, maxSteps: 16,
    headObservation: 'One-step eth_call returns 33 before cleanup; all entries are dead, so persistent head is 32. Post-maintenance eth_call returns terminal head 40.' };
}

if (process.argv[2] === 'before') {
  for (let i = 0; i < accounts.length; i++) {
    await client.request({ method: 'anvil_setBalance', params: [accounts[i].address, '0x56bc75e2d63100000'] });
    await send(i, { to: manifest.stable, data: encodeFunctionData({
      abi: parseAbi(['function mint(address to,uint256 amount)']), functionName: 'mint',
      args: [accounts[i].address, 1000n * 10n ** 6n] }) }, 'local test-token funding', 'DIRECT_CONTRACT');
  }
  const sponsor = await prepareSponsorAddition(client, node, market, 5n * 10n ** 18n);
  await send(0, approvalTransaction(sponsor), 'bounded sponsor approval');
  const sponsorBefore = await balances();
  const receipt = await send(0, await validatePrepared(client, sponsor), 'SDK sponsor addition');
  const sponsorAfter = await balances();
  assert.equal(sponsorBefore[0] - sponsorAfter[0], sponsor.limits.maxTokenIn);
  const added = receipt.logs.map(log => {
    try { return decodeEventLog({ abi: abi.AMMEngine, ...log }); } catch { return null; }
  }).find(event => event?.eventName === 'LiquidityPositionAdded');
  assert.ok(added, 'Sponsor position event');
  const makerBefore = await balances();
  await convert(1, 'split', 100n * 10n ** 18n);
  const yesOffer = await executeOrder(1, { action: 'SELL', outcome: 'YES', priceTick: 520,
    amount: 100n * 10n ** 18n, postOnly: true });
  const noOffer = await executeOrder(1, { action: 'SELL', outcome: 'NO', priceTick: 520,
    amount: 100n * 10n ** 18n, postOnly: true });
  assert.equal(yesOffer.debitNative, 0n);
  assert.equal(noOffer.debitNative, 0n);
  assert.deepEqual(await inventory(1), { yesOwned: 100n * 10n ** 18n, noOwned: 100n * 10n ** 18n,
    yesReserved: 100n * 10n ** 18n, noReserved: 100n * 10n ** 18n, cashReserved: 0n });
  assert.equal((await balances())[1] - makerBefore[1], -100n * 10n ** 6n);
  const firstFill = await executeOrder(0, { action: 'BUY', outcome: 'YES', priceTick: 520,
    amount: 40n * 10n ** 18n, rest: false });
  assert.equal(firstFill.preview.fee, 192000n);
  const afterFirstFill = { inventory: await inventory(1), freeCashChangeNative: (await balances())[1] - makerBefore[1] };
  assert.deepEqual(afterFirstFill.inventory, { yesOwned: 60n * 10n ** 18n, noOwned: 100n * 10n ** 18n,
    yesReserved: 60n * 10n ** 18n, noReserved: 100n * 10n ** 18n, cashReserved: 0n });
  assert.equal(afterFirstFill.freeCashChangeNative, -79200000n);
  const secondFill = await executeOrder(0, { action: 'BUY', outcome: 'NO', priceTick: 520,
    amount: 40n * 10n ** 18n, rest: false });
  assert.equal(secondFill.preview.fee, 192000n);
  const beforeCancels = await balances();
  for (const placed of [yesOffer, noOffer]) await send(1,
    await prepareCancelById(client, node, market, placed.preview.orderId), 'release unfilled inventory reservation');
  assert.deepEqual(await balances(), beforeCancels, 'Inventory cancellation transfers no cash');
  await convert(1, 'merge', 60n * 10n ** 18n);
  await convert(0, 'merge', 40n * 10n ** 18n);
  for (let i = 0; i < accounts.length; i++) assert.deepEqual(await inventory(i),
    { yesOwned: 0n, noOwned: 0n, yesReserved: 0n, noReserved: 0n, cashReserved: 0n });
  const makerAfter = await balances();
  assert.deepEqual(makerAfter.map((v, i) => v - makerBefore[i]), [-1984000n, 1600000n]);
  const quoteRecovery = await recoverQuotes();
  // An independent resting order survives listing changes and terminal settlement.
  const exitOrder = await executeOrder(1, { action: 'BUY', outcome: 'YES', priceTick: 100, amount: 2n * 10n ** 18n });
  // Odd native-unit claims must preserve their half-unit through cancellation
  // and an intervening merge, instead of losing it at each claim boundary.
  const carryMarket = manifest.markets[2];
  await convert(1, 'split', 5n * 10n ** 12n, carryMarket);
  const carryYes = await executeOrder(1, { action: 'SELL', outcome: 'YES', priceTick: 600,
    amount: 5n * 10n ** 12n, postOnly: true }, carryMarket);
  const carryNo = await executeOrder(1, { action: 'SELL', outcome: 'NO', priceTick: 600,
    amount: 2n * 10n ** 12n, postOnly: true }, carryMarket);
  writeFileSync(path, `${stringify({ schemaVersion: 2, node, market, accounts: accounts.map(a => a.address),
    sponsorPositionId: added.args.positionId, sponsorUnits: sponsor.limits.minLpOut,
    sponsorContributionNative: sponsor.limits.maxTokenIn,
    makerSessionCashDeltaNative: makerAfter.map((v, i) => v - makerBefore[i]),
    inventorySession: { splitWad: 100n * 10n ** 18n, filledEachOutcomeWad: 40n * 10n ** 18n,
      makerMergedWad: 60n * 10n ** 18n, takerMergedWad: 40n * 10n ** 18n,
      afterFirstFill, firstFill: firstFill.preview, secondFill: secondFill.preview }, quoteRecovery,
    invalidCarry: { market: carryMarket, orderIds: [carryYes.preview.orderId, carryNo.preview.orderId], principalNative: 5n },
    exitOrderId: exitOrder.preview.orderId,
    transactions, transactionCounts: transactionCounts(transactions), status: 'funded-and-traded' })}\n`);
} else if (process.argv[2] === 'after') {
  const saved = JSON.parse(readFileSync(path, 'utf8'));
  assert.equal(saved.market.toLowerCase(), market.toLowerCase());
  // Delisting is local discovery state, never a loss of direct contract access.
  const excluded = new Set([node.nodeId.toLowerCase()]);
  const before = await balances();
  await send(1, await prepareCancelById(client, node, market, BigInt(saved.exitOrderId)),
    'SDK cancellation by ID after delisting/settlement');
  const receipt = await send(0, { to: node.amm, data: encodeFunctionData({ abi: abi.AMMEngine,
    functionName: 'claimAvailable', args: [market, BigInt(saved.sponsorPositionId), BigInt(saved.sponsorUnits)] }) },
  'direct sponsor claim after delisting', 'DIRECT_CONTRACT');
  const after = await balances();
  const lpClaim = receipt.logs.map(log => {
    try { return decodeEventLog({ abi: abi.AMMEngine, ...log }); } catch { return null; }
  }).find(event => event?.eventName === 'LPProceedsClaimed');
  assert.ok(lpClaim);
  assert.equal(after[0] - before[0], lpClaim.args.floorPaid / 10n ** 12n + lpClaim.args.feesPaid);
  const carryBefore = (await balances())[1];
  const settleInventory = { to: node.book, data: encodeFunctionData({ abi: abi.OrderEngine,
    functionName: 'settlePosition', args: [saved.invalidCarry.market] }) };
  const readCarry = async () => BigInt(await client.readContract({ address: node.book, abi: abi.OrderEngine,
    functionName: 'invalidRemainderOf', args: [saved.invalidCarry.market, accounts[1].address] }));
  await send(1, settleInventory, 'settle odd available INVALID inventory', 'DIRECT_CONTRACT');
  assert.equal((await balances())[1] - carryBefore, 1n);
  assert.equal(await readCarry(), 1n);
  for (const id of saved.invalidCarry.orderIds) await send(1,
    await prepareCancelById(client, node, saved.invalidCarry.market, BigInt(id)), 'release settled inventory reservation');
  await convert(1, 'merge', 2n * 10n ** 12n, saved.invalidCarry.market);
  assert.equal(await readCarry(), 1n, 'Complete-set merge preserves prior half-native entitlement');
  const finalReceipt = await send(1, settleInventory,
    'settle remaining INVALID inventory with carry', 'DIRECT_CONTRACT');
  assert.equal(await readCarry(), 0n);
  assert.equal((await balances())[1] - carryBefore, 5n);
  // Receipt waiting can leave viem's block-number cache behind the last mined
  // transaction. Replay and reconciliation must use the same confirmed state.
  const lastBlock = finalReceipt.blockNumber;
  const readAtReplayTip = params => client.readContract({ ...params, blockNumber: lastBlock });
  const replay = new NodeReplay(31337, [manifest.factory], { releaseIds: [request.releaseId] });
  // Include empty blocks so the canonical parent chain is independently checked.
  for (let number = 0n; number <= lastBlock; number++) {
    const block = await client.getBlock({ blockNumber: number });
    const logs = await client.getLogs({ fromBlock: number, toBlock: number });
    replay.applyBlock({ chainId: 31337, number, hash: block.hash, parentHash: block.parentHash, logs });
  }
  assert.equal(replay.blocks.at(-1).hash.toLowerCase(), finalReceipt.blockHash.toLowerCase(),
    'Replay includes the canonical final settlement receipt');
  assert.equal(replay.nodes.size, 2);
  assert.equal(replay.markets.size, 6);
  assert.ok(replay.listedMarkets(excluded).length < replay.markets.size);
  const ammSells = replay.events.filter(row => row.contract === 'AMMEngine'
    && row.eventName === 'PositionTraded' && row.args.deltaShares < 0n);
  assert.equal(ammSells.length, 2, 'Six- and eighteen-decimal direct AMM sells');
  const directPayouts = [];
  for (const sell of ammSells) {
    const row = [...replay.markets.values()].find(entry => entry.market.toLowerCase() === sell.args.market.toLowerCase());
    const payout = presentAmmSellProceeds(sell.args.cost, Number(row.tokenADecimals));
    const receipt = await client.getTransactionReceipt({ hash: sell.transactionHash });
    const paidNative = receipt.logs.reduce((sum, log) => {
      if (log.address.toLowerCase() !== row.tokenA.toLowerCase()) return sum;
      try {
        const decoded = decodeEventLog({ abi: erc20Abi, data: log.data, topics: log.topics, strict: true });
        return decoded.eventName === 'Transfer'
          && decoded.args.from.toLowerCase() === row.node.amm.toLowerCase()
          && decoded.args.to.toLowerCase() === sell.args.user.toLowerCase()
          ? sum + decoded.args.value : sum;
      } catch { return sum; }
    }, 0n);
    assert.equal(paidNative, payout.payoutNative, 'AMM sell receipt pays the seller in its trade transaction');
    const key = `${instrumentKey(row.node, row.market, 'AMM')}:${row.tokenA.toLowerCase()}:${sell.args.user.toLowerCase()}`;
    assert.equal(replay.ammSellPaidNative.get(key), paidNative, 'Replayed direct payout matches token transfer');
    const fixtureIndex = manifest.markets.findIndex(target => target.toLowerCase() === row.market.toLowerCase());
    assert.equal(paidNative, BigInt(manifest.ammSellPayoutsNative[fixtureIndex]), 'Replay matches harness balance delta');
    directPayouts.push({ market: row.market, token: row.tokenA, decimals: Number(row.tokenADecimals),
      transactionHash: sell.transactionHash, ...payout });
  }
  for (const row of replay.markets.values()) {
    for (const [venue, vault, token] of [['AMM', row.node.ammVault, row.tokenA], ['BOOK', row.node.bookVault, row.node.bookToken]]) {
      const key = `${instrumentKey(row.node, row.market, venue)}:${token.toLowerCase()}`;
      const actual = await readAtReplayTip({ address: vault,
        abi: venue === 'AMM' ? abi.AmmFeeVault : abi.BookFeeVault,
        functionName: 'marketLiabilitiesOf', args: [row.market, token] });
      assert.equal(replay.feeLiabilities.get(key) ?? 0n, actual, `replayed liability ${key}`);
    }
  }
  for (const [key, expected] of replay.lpBalances) {
    const [manager, id, holder] = key.split(':');
    const actual = await readAtReplayTip({ address: manager, abi: abi.LPPositionManager,
      functionName: 'balanceOf', args: [holder, BigInt(id)] });
    assert.equal(actual, expected, `replayed LP balance ${key}`);
  }
  for (const [key, expected] of replay.positions) {
    const [, factory, id, target, venue, holder] = key.split(':');
    assert.equal(venue, 'BOOK');
    const book = replay.nodes.get(`${factory}:${id}`).book;
    const actual = await readAtReplayTip({ address: book, abi: abi.OrderEngine,
      functionName: 'getNet', args: [target, holder] });
    assert.equal(actual, expected, `replayed signed inventory ${key}`);
  }
  for (const [key, expected] of replay.inventories) {
    const [, factory, id, target, venue, holder] = key.split(':');
    assert.equal(venue, 'BOOK');
    const book = replay.nodes.get(`${factory}:${id}`).book;
    const actual = await readAtReplayTip({ address: book, abi: abi.OrderEngine,
      functionName: 'getInventory', args: [target, holder] });
    assert.deepEqual(actual, [expected.yesOwned, expected.noOwned, expected.yesReserved,
      expected.noReserved, expected.cashReserved], `replayed owned/reserved inventory ${key}`);
  }
  for (const [key, expected] of replay.invalidRemainders) {
    const [, factory, id, target, , holder] = key.split(':');
    const book = replay.nodes.get(`${factory}:${id}`).book;
    const actual = await readAtReplayTip({ address: book, abi: abi.OrderEngine,
      functionName: 'invalidRemainderOf', args: [target, holder] });
    assert.equal(actual, expected, `replayed INVALID half-native remainder ${key}`);
  }
  for (const key of replay.bookRefunds.keys()) {
    const [, factory, id, target, , , payer] = key.split(':');
    const replayNode = replay.nodes.get(`${factory}:${id}`);
    const expected = replay.bookRefundState(replayNode, target, payer);
    const actual = await readAtReplayTip({ address: replayNode.bookVault, abi: abi.BookFeeVault,
      functionName: 'refundableResolutionOf', args: [target, payer] });
    assert.equal(actual, expected.refundableNative, `replayed fee-payer refund ${key}`);
  }
  const allTransactions = [...saved.transactions, ...transactions];
  const report = { ...saved, status: 'complete', sponsorReturnNative: after[0] - before[0],
    sponsorNetSpendNative: BigInt(saved.sponsorContributionNative) - (after[0] - before[0]),
    sponsorFloorPaidWad: lpClaim.args.floorPaid, sponsorFeePaidNative: lpClaim.args.feesPaid,
    cancellationRefundNative: after[1] - before[1],
    invalidCarry: { ...saved.invalidCarry, returnedNative: (await balances())[1] - carryBefore, finalRemainder: 0n },
    transactions: allTransactions, transactionCounts: transactionCounts(allTransactions),
    replay: { canonicalBlocks: replay.blocks.length, blockNumber: lastBlock.toString(), blockHash: finalReceipt.blockHash,
      nodes: replay.nodes.size, markets: replay.markets.size,
      decodedEvents: replay.events.length, feeLedgerRows: replay.feeLiabilities.size,
      lpBalanceRows: replay.lpBalances.size, signedPositionRows: replay.positions.size,
      grossInventoryRows: replay.inventories.size, invalidRemainderRows: replay.invalidRemainders.size,
      bookFeePayerRows: replay.bookRefunds.size, reconciledBookExecutionRows: replay.bookExecutionFees.size,
      surplusRows: replay.surplusSwept.size, ammSellPayoutRows: replay.ammSellPaidNative.size,
      directAmmSellPayouts: directPayouts },
    limitations: ['Synthetic local flow; no commercial profitability or sponsor renewal claim.',
      'Sponsor exact-state guards can require refresh after intervening trades.',
      'Inventory-funded sells reserve owned shares; gas and outside strategy costs are excluded from the example.'] };
  writeFileSync(path, `${stringify(report)}\n`);
  console.log(JSON.stringify({ clientWorkflow: 'passed', ...report.replay },
    (_, value) => typeof value === 'bigint' ? value.toString() : value));
} else throw new Error('Use before or after');
