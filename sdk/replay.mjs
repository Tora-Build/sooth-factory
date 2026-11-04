import { decodeEventLog, getContractAddress, zeroAddress } from 'viem';
import { abi, instrumentKey, presentAmmSellProceeds } from './index.mjs';

const lower = value => value.toLowerCase();
const add = (map, key, amount) => map.set(key, (map.get(key) ?? 0n) + amount);
const must = (ok, message) => { if (!ok) throw new Error(message); };

/** Small reference indexer: canonical block replay with explicit rollback, not a hosted indexer. */
export class NodeReplay {
  constructor(chainId, factories, { releaseIds } = {}) {
    must(Array.isArray(releaseIds) && releaseIds.length > 0, 'Approved replay release IDs required');
    this.chainId = Number(chainId);
    this.factories = new Set(factories.map(lower));
    this.releaseIds = new Set(releaseIds.map(lower));
    this.blocks = [];
    this.rebuild();
  }

  applyBlock(block) {
    must(Number(block.chainId) === this.chainId, 'Wrong replay chain');
    const duplicate = this.blocks.find(b => lower(b.hash) === lower(block.hash));
    if (duplicate) return; // Idempotent receipt delivery.
    const previous = this.blocks;
    let next = previous;
    if (this.blocks.length) {
      const parent = this.blocks.findIndex(b => lower(b.hash) === lower(block.parentHash));
      must(parent >= 0, 'Unknown parent: resync from a known checkpoint');
      must(BigInt(block.number) === BigInt(this.blocks[parent].number) + 1n, 'Noncontiguous block');
      next = this.blocks.slice(0, parent + 1);
    }
    this.blocks = [...next, block];
    try { this.rebuild(); }
    catch (error) { this.blocks = previous; this.rebuild(); throw error; }
  }

  rebuild() {
    this.nodes = new Map();
    this.emitters = new Map();
    this.markets = new Map();
    this.inventories = new Map();
    this.orders = new Map();
    this.deferred = new Map();
    // Fractional INVALID entitlements are half-native units, never spendable cash.
    this.invalidRemainders = new Map();
    // Exposure is a projection of gross ownership, including reserved shares.
    this.positions = new Map();
    this.feeLiabilities = new Map();
    this.feeReceipts = new Map();
    this.feePaid = new Map();
    this.bookRefunds = new Map();
    this.bookSettlementModes = new Map();
    this.surplusSwept = new Map();
    this.bookExecutionFees = new Map();
    this.bookDepositedFees = new Map();
    this.pendingBookDistributions = new Map();
    this.sponsorContributionsWad = new Map();
    this.sponsorFloorPaidWad = new Map();
    this.ammSellPaidNative = new Map();
    // Cumulative amounts retained at execution, not outstanding seller claims
    // or the current LP residual after subsequent trades and redemptions.
    this.ammSellRetainedWad = new Map();
    this.lpBalances = new Map();
    this.lpSupply = new Map();
    this.lpEntries = new Map();
    this.events = [];
    for (const block of this.blocks) {
      const seen = new Set();
      const logs = [...block.logs].sort((a, b) => Number(a.logIndex) - Number(b.logIndex));
      for (const log of logs) {
        must(lower(log.blockHash) === lower(block.hash), 'Receipt block mismatch');
        const key = `${lower(log.transactionHash)}:${log.logIndex}`;
        must(!seen.has(key), 'Duplicate log in a block');
        seen.add(key);
        this.consume(log);
      }
      this.validateBookFees();
      this.validateBookReservations();
    }
  }

  validateBookFees() {
    must(this.pendingBookDistributions.size === 0, 'Incomplete book fee distribution');
    const keys = new Set([...this.bookExecutionFees.keys(), ...this.bookDepositedFees.keys()]);
    for (const key of keys) must((this.bookExecutionFees.get(key) ?? 0n)
      === (this.bookDepositedFees.get(key) ?? 0n), 'Book execution fee and vault receipt disagree');
  }

  /** Mirrors the vault view; only timeout finalization makes the payer amount claimable. */
  bookRefundState(node, market, payer) {
    const asset = `${instrumentKey(node, market, 'BOOK')}:${lower(node.bookToken)}`;
    const mode = this.bookSettlementModes.get(asset) ?? 'CONTINGENT';
    const remaining = this.bookRefunds.get(`${asset}:${lower(payer)}`) ?? 0n;
    return { mode, refundableNative: mode === 'ADJUDICATED' ? 0n : remaining,
      claimableNative: mode === 'TIMEOUT' ? remaining : 0n };
  }

  registerEmitter(address, context) {
    const key = lower(address);
    must(key !== zeroAddress && !this.factories.has(key) && !this.emitters.has(key),
      'Emitter already assigned or invalid');
    this.emitters.set(key, context);
  }

  validateBookReservations() {
    const totals = new Map();
    for (const order of this.orders.values()) {
      if (order.status !== 'OPEN') continue;
      const key = `${order.instrument}:${lower(order.maker)}`;
      const reserved = totals.get(key) ?? { yes: 0n, no: 0n, cash: 0n };
      if (order.action === 1) {
        if (order.outcome === 1) reserved.yes += order.remaining;
        else reserved.no += order.remaining;
      }
      reserved.cash += order.cashReserved;
      totals.set(key, reserved);
    }
    for (const [key, inventory] of this.inventories) {
      const reserved = totals.get(key) ?? { yes: 0n, no: 0n, cash: 0n };
      must(inventory.yesReserved === reserved.yes && inventory.noReserved === reserved.no
        && inventory.cashReserved === reserved.cash, 'Order and inventory reservations disagree');
      totals.delete(key);
    }
    must(totals.size === 0, 'Missing inventory snapshot for resting order');
  }

  consumeBook(node, marketKey, eventName, a) {
    if (eventName === 'InvalidRemainderChanged') {
      must(a.halfNativeUnit === 0 || a.halfNativeUnit === 1, 'Invalid settlement remainder');
      this.invalidRemainders.set(`${marketKey}:${lower(a.user)}`, a.halfNativeUnit);
    } else if (eventName === 'InventoryChanged') {
      must(a.yesReserved <= a.yesOwned && a.noReserved <= a.noOwned,
        'Reserved inventory exceeds ownership');
      const key = `${marketKey}:${lower(a.user)}`;
      const inventory = { ...a, yesAvailable: a.yesOwned - a.yesReserved,
        noAvailable: a.noOwned - a.noReserved, net: a.yesOwned - a.noOwned };
      this.inventories.set(key, inventory);
      this.positions.set(key, inventory.net);
    } else if (eventName === 'OrderPlaced') {
      const key = `${marketKey}:${a.orderId}`;
      must(!this.orders.has(key), 'Duplicate book order identity');
      must((a.action === 0 || a.action === 1) && (a.outcome === 0 || a.outcome === 1)
        && a.amount > 0n && a.yesTick > 0 && a.yesTick < 1000,
      'Invalid resting order');
      this.orders.set(key, { ...a, instrument: marketKey, remaining: a.amount, status: 'OPEN' });
    } else if (eventName === 'OrderFilled') {
      const order = this.orders.get(`${marketKey}:${a.orderId}`);
      must(order?.status === 'OPEN', 'Fill references unknown or inactive order');
      must(a.amount > 0n && order.remaining === a.amount + a.remaining
        && order.yesTick === a.yesTick && a.settlementType >= 0 && a.settlementType <= 3,
      'Fill does not match resting order');
      order.remaining = a.remaining;
      order.cashReserved = a.cashReserved;
      order.status = a.remaining === 0n ? 'FILLED' : 'OPEN';
      must(order.status === 'OPEN' || order.cashReserved === 0n,
        'Filled order retains cash reservation');
    } else if (eventName === 'OrderCancelled') {
      const order = this.orders.get(`${marketKey}:${a.orderId}`);
      must(order?.status === 'OPEN' && lower(order.maker) === lower(a.maker)
        && order.remaining === a.amount && order.cashReserved === a.cashRefund,
      'Cancellation does not match resting order');
      order.remaining = 0n;
      order.cashReserved = 0n;
      order.status = 'CANCELLED';
    } else if (eventName === 'PayoutDeferred' || eventName === 'DeferredClaimed') {
      // Deferred collateral is owed by the node's book, not by an individual market.
      const key = `${node.chainId}:${lower(node.factory)}:${lower(node.nodeId)}:${lower(node.book)}:${lower(a.recipient)}`;
      add(this.deferred, key, eventName === 'PayoutDeferred' ? a.amount : -a.amount);
      must(this.deferred.get(key) >= 0n, 'Claim exceeds replayed deferred collateral');
    }
    // Split/Merged/PositionSettled remain in the canonical event history.
    // Only InventoryChanged sets ownership: settlement can leave reserved shares intact.
  }

  consume(log) {
    const emitter = lower(log.address);
    let contract;
    let context;
    if (this.factories.has(emitter)) contract = 'NodeFactory';
    else {
      context = this.emitters.get(emitter);
      if (!context) return;
      contract = context.contract;
    }
    let decoded;
    try { decoded = decodeEventLog({ abi: abi[contract], data: log.data, topics: log.topics, strict: true }); }
    catch { return; }
    const { eventName, args: a } = decoded;
    if (eventName === 'NodeCreated') {
      must(this.releaseIds.has(lower(a.releaseId)), 'Unapproved replay release');
      const node = { chainId: this.chainId, factory: log.address, ...a };
      const key = `${emitter}:${lower(a.nodeId)}`;
      must(!this.nodes.has(key), 'Duplicate node identity');
      this.nodes.set(key, node);
      for (const [field, name, venue] of [
        ['book', 'OrderEngine', 'BOOK'], ['amm', 'AMMEngine', 'AMM'],
        ['ammVault', 'AmmFeeVault', 'AMM'], ['bookVault', 'BookFeeVault', 'BOOK'],
        ['marketFactory', 'MarketFactory', undefined],
      ]) this.registerEmitter(a[field], { node, contract: name, venue });
      const manager = getContractAddress({ from: a.amm, nonce: 1n });
      this.registerEmitter(manager, { node, contract: 'LPPositionManager', venue: 'AMM' });
      return;
    }
    if (!context) return;
    const { node, venue } = context;
    const marketKey = a.market ? instrumentKey(node, a.market, venue ?? 'AMM') : undefined;
    this.events.push({ chainId: node.chainId, factory: node.factory, nodeId: node.nodeId,
      releaseId: node.releaseId, venue, contract, eventName, args: a,
      transactionHash: log.transactionHash, logIndex: log.logIndex });
    if (contract === 'OrderEngine') {
      if (eventName === 'OrderExecuted') {
        const key = `${lower(log.transactionHash)}:${marketKey}:${lower(node.bookToken)}:${lower(a.user)}`;
        add(this.bookExecutionFees, key, a.fee);
      }
      this.consumeBook(node, marketKey, eventName, a);
      return;
    }
    if (eventName === 'MarketCreated' && contract === 'MarketFactory') {
      const identity = `${node.chainId}:${lower(node.factory)}:${lower(node.nodeId)}:${lower(a.market)}`;
      this.markets.set(identity, { node, ...a });
      this.registerEmitter(a.market, { node, contract: 'TruthMarket' });
    } else if (eventName === 'PositionTraded' && contract === 'AMMEngine' && a.deltaShares < 0n) {
      const identity = `${node.chainId}:${lower(node.factory)}:${lower(node.nodeId)}:${lower(a.market)}`;
      const market = this.markets.get(identity);
      must(market, 'AMM sell references unknown market collateral');
      const payout = presentAmmSellProceeds(a.cost, Number(market.tokenADecimals));
      const asset = `${marketKey}:${lower(market.tokenA)}`;
      add(this.ammSellPaidNative, `${asset}:${lower(a.user)}`, payout.payoutNative);
      add(this.ammSellRetainedWad, asset, payout.retainedInMarketWad);
    } else if (eventName === 'RevenueDeposited') {
      must(Number(a.venue) === (venue === 'AMM' ? 0 : 1), 'Vault venue mismatch');
      const key = `${marketKey}:${lower(a.token)}`;
      add(this.feeLiabilities, key, a.amount);
      add(this.feeReceipts, key, a.amount);
      if (venue === 'BOOK') {
        must(lower(a.token) === lower(node.bookToken) && a.amount > 0n,
          'Invalid book revenue receipt');
        const txAsset = `${lower(log.transactionHash)}:${key}`;
        must(!this.pendingBookDistributions.has(txAsset), 'Incomplete book fee distribution');
        const payerKey = `${key}:${lower(a.feePayer)}`;
        this.pendingBookDistributions.set(txAsset, { payerKey, remaining: a.amount, buckets: new Set() });
        add(this.bookDepositedFees, `${lower(log.transactionHash)}:${payerKey}`, a.amount);
      }
    } else if (eventName === 'FeeDistributed' && venue === 'BOOK') {
      must(Number(a.venue) === 1 && lower(a.token) === lower(node.bookToken), 'Vault venue or token mismatch');
      const txAsset = `${lower(log.transactionHash)}:${marketKey}:${lower(a.token)}`;
      const receipt = this.pendingBookDistributions.get(txAsset);
      must(receipt && (a.bucket === 0 || a.bucket === 1) && a.amount > 0n
        && !receipt.buckets.has(a.bucket) && a.amount <= receipt.remaining,
      'Invalid book fee distribution');
      receipt.buckets.add(a.bucket);
      receipt.remaining -= a.amount;
      if (a.bucket === 0) add(this.bookRefunds, receipt.payerKey, a.amount);
      if (receipt.remaining === 0n) this.pendingBookDistributions.delete(txAsset);
    } else if (eventName === 'MarketFinalized') {
      must(Number(a.venue) === (venue === 'AMM' ? 0 : 1), 'Vault venue mismatch');
      if (venue === 'BOOK') {
        must(a.settlementKind === 1 || a.settlementKind === 2, 'Invalid fee settlement kind');
        const asset = `${marketKey}:${lower(node.bookToken)}`;
        const mode = a.settlementKind === 2 ? 'TIMEOUT' : 'ADJUDICATED';
        must(!this.bookSettlementModes.has(asset) || this.bookSettlementModes.get(asset) === mode,
          'Conflicting fee settlement kind');
        this.bookSettlementModes.set(asset, mode);
      }
    } else if (eventName === 'Claimed') {
      must(Number(a.venue) === (venue === 'AMM' ? 0 : 1), 'Vault venue mismatch');
      const key = `${marketKey}:${lower(a.token)}`;
      add(this.feeLiabilities, key, -a.amount);
      must(this.feeLiabilities.get(key) >= 0n, 'Payout exceeds replayed fee receipts');
      add(this.feePaid, `${key}:${lower(a.recipient)}:${a.bucket}`, a.amount);
      if (venue === 'BOOK' && a.bucket === 0) {
        const mode = this.bookSettlementModes.get(key);
        must(mode === 'TIMEOUT' || mode === 'ADJUDICATED', 'Resolution paid before vault finalization');
        if (mode === 'TIMEOUT') {
          const payerKey = `${key}:${lower(a.recipient)}`;
          add(this.bookRefunds, payerKey, -a.amount);
          must(this.bookRefunds.get(payerKey) >= 0n, 'Refund exceeds original payer entitlement');
        }
      }
    } else if (eventName === 'SurplusSwept') {
      must(Number(a.venue) === (venue === 'AMM' ? 0 : 1), 'Vault venue mismatch');
      const key = `${node.chainId}:${lower(node.factory)}:${lower(node.nodeId)}:${venue}:${emitter}:${lower(a.token)}:${lower(a.recipient)}`;
      add(this.surplusSwept, key, a.amount);
    } else if (eventName === 'PositionOpened') {
      const entryKey = `${emitter}:${a.positionId}`;
      this.lpEntries.set(entryKey, { node, ...a });
      add(this.sponsorContributionsWad, `${marketKey}:${lower(a.owner)}`, a.deposit);
    } else if (eventName === 'Transfer' && contract === 'LPPositionManager') {
      const entryKey = `${emitter}:${a.id}`;
      if (lower(a.sender) === zeroAddress) add(this.lpSupply, entryKey, a.amount);
      else add(this.lpBalances, `${entryKey}:${lower(a.sender)}`, -a.amount);
      if (lower(a.receiver) === zeroAddress) add(this.lpSupply, entryKey, -a.amount);
      else add(this.lpBalances, `${entryKey}:${lower(a.receiver)}`, a.amount);
    } else if (eventName === 'FloorClaimed') {
      add(this.sponsorFloorPaidWad, `${marketKey}:${lower(a.user)}`, a.amount);
    }
  }

  /** Listing state is off chain and never erases contract identity or exit data. */
  listedMarkets(excludedNodeIds = new Set()) {
    const excluded = new Set([...excludedNodeIds].map(lower));
    return [...this.markets.values()].filter(m => !excluded.has(lower(m.node.nodeId)));
  }
}
