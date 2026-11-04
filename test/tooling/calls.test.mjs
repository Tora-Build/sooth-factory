import assert from 'node:assert/strict';
import test from 'node:test';
import { encodeFunctionData, keccak256, toBytes } from 'viem';
import { abi } from '../../sdk/index.mjs';
import {
  SET_TOKEN_ALLOWED_ACK, SET_TOKEN_ALLOWED_LEGACY, TOKEN_RISK_ACKNOWLEDGEMENT,
  readTokenRiskAcknowledgement, tokenAdmissionCall,
} from '../../sdk/calls.mjs';

const token = '0x0000000000000000000000000000000000000001';
const selector = signature => keccak256(toBytes(signature)).slice(0, 10);

test('token admission follows the on-chain acknowledgement probe', async () => {
  assert.equal(TOKEN_RISK_ACKNOWLEDGEMENT, keccak256(toBytes(
    'SOOTH_TOKEN_ADMISSION_V1:hooks,pause,blacklist-not-fully-detectable')));
  const current = tokenAdmissionCall({
    token, allowed: true, acknowledgement: TOKEN_RISK_ACKNOWLEDGEMENT, abi: abi.MarketFactory,
  });
  assert.equal(current.signature, SET_TOKEN_ALLOWED_ACK);
  assert.equal(current.functionName, 'setTokenAllowed');
  assert.deepEqual(current.args, [token, true, TOKEN_RISK_ACKNOWLEDGEMENT]);
  const admitted = encodeFunctionData({ abi: current.abi, functionName: current.functionName, args: current.args });
  assert.equal(admitted.slice(0, 10), selector(SET_TOKEN_ALLOWED_ACK));
  assert.throws(() => encodeFunctionData({
    abi: abi.MarketFactory, functionName: SET_TOKEN_ALLOWED_ACK, args: current.args,
  }), /not found/);

  const calls = [];
  const reader = {
    readContract: async (request) => {
      calls.push(request);
      return TOKEN_RISK_ACKNOWLEDGEMENT;
    },
  };
  const fromChain = await readTokenRiskAcknowledgement(reader, token);
  assert.equal(fromChain, TOKEN_RISK_ACKNOWLEDGEMENT);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].address, token);
  assert.equal(calls[0].functionName, 'TOKEN_RISK_ACKNOWLEDGEMENT');
  assert.equal(calls[0].abi.some(item => item.name === 'TOKEN_RISK_ACKNOWLEDGEMENT'
    && item.inputs.length === 0), true);
  const chosen = tokenAdmissionCall({
    token, allowed: true, acknowledgement: fromChain, abi: abi.MarketFactory,
  });
  assert.equal(chosen.signature, SET_TOKEN_ALLOWED_ACK);

  const reverted = { readContract: async () => { throw new Error('execution reverted'); } };
  assert.equal(await readTokenRiskAcknowledgement(reverted, token), null);
  const empty = { readContract: async () => '0x' };
  assert.equal(await readTokenRiskAcknowledgement(empty, token), null);
  const legacyCall = tokenAdmissionCall({
    token, allowed: true, acknowledgement: null, abi: abi.MarketFactory,
  });
  assert.equal(legacyCall.signature, SET_TOKEN_ALLOWED_LEGACY);
  const legacy = encodeFunctionData({
    abi: legacyCall.abi, functionName: legacyCall.functionName, args: legacyCall.args,
  });
  assert.equal(legacy.slice(0, 10), selector(SET_TOKEN_ALLOWED_LEGACY));
  assert.notEqual(legacy.slice(0, 10), admitted.slice(0, 10));
});

test('a revert or missing constant is v7.1, and transport errors propagate', async () => {
  const clientFor = error => ({ readContract: async () => { throw error; } });

  const callException = new Error('missing revert data');
  callException.code = 'CALL_EXCEPTION';
  callException.data = '0x';
  assert.equal(await readTokenRiskAcknowledgement(clientFor(callException), token), null);

  const zeroData = new Error('The contract function "TOKEN_RISK_ACKNOWLEDGEMENT" returned no data ("0x").');
  zeroData.name = 'ContractFunctionZeroDataError';
  const wrappedMissing = new Error('contract read failed');
  wrappedMissing.name = 'ContractFunctionExecutionError';
  wrappedMissing.cause = zeroData;
  assert.equal(await readTokenRiskAcknowledgement(clientFor(wrappedMissing), token), null);
  assert.equal(await readTokenRiskAcknowledgement({ readContract: async () => '0xabcd' }, token), null);
  const legacy = tokenAdmissionCall({
    token, allowed: true, acknowledgement: null, abi: abi.MarketFactory,
  });
  assert.equal(legacy.signature, SET_TOKEN_ALLOWED_LEGACY);

  const timeout = new Error('The request timed out.');
  timeout.name = 'TimeoutError';
  const wrappedTimeout = new Error('contract read failed');
  wrappedTimeout.name = 'ContractFunctionExecutionError';
  wrappedTimeout.cause = timeout;
  await assert.rejects(
    () => readTokenRiskAcknowledgement(clientFor(wrappedTimeout), token),
    error => error === wrappedTimeout,
  );

  const network = new Error('HTTP request failed.');
  network.name = 'HttpRequestError';
  await assert.rejects(
    () => readTokenRiskAcknowledgement(clientFor(network), token),
    error => error === network,
  );
});
