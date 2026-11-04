// Caller helpers for token admission and guardian vetoes.
// Ethers v6 collapses both setTokenAllowed overloads onto one property.
// Admit with factory["setTokenAllowed(address,bool,bytes32)"](token, true, acknowledgement).
// viem 2.45 selects the overload from the argument list and rejects that
// signature string as functionName. `signature` is the ethers key.

export const SET_TOKEN_ALLOWED_LEGACY = 'setTokenAllowed(address,bool)';
export const SET_TOKEN_ALLOWED_ACK = 'setTokenAllowed(address,bool,bytes32)';
export const TOKEN_RISK_ACKNOWLEDGEMENT =
  '0xf8f74989d1e3db808e2762b9c880b181276a4b17f2738fc91bb4529fa0a04aff';

const bytes32 = /^0x[0-9a-fA-F]{64}$/;

/** Probe ABI. The local artifact must not decide whether the call is made. */
const TOKEN_RISK_PROBE_ABI = [{
  type: 'function',
  name: 'TOKEN_RISK_ACKNOWLEDGEMENT',
  stateMutability: 'view',
  inputs: [],
  outputs: [{ name: '', type: 'bytes32' }],
}];

function overload(abi, arity) {
  if (!Array.isArray(abi)) return undefined;
  const matches = abi.filter(item => item.type === 'function' && item.name === 'setTokenAllowed'
    && item.inputs?.length === arity);
  if (matches.length !== 1) throw new Error(`setTokenAllowed arity ${arity} is missing from the ABI`);
  return matches;
}

/**
 * Choose the admission call from the on-chain probe result.
 * A bytes32 acknowledgement is the three-argument call. Null, from a reverted
 * probe, is the two-argument call. A manifest label or environment variable
 * is not an input.
 */
export function tokenAdmissionCall({ token, allowed = true, acknowledgement, abi } = {}) {
  if (typeof acknowledgement === 'string' && bytes32.test(acknowledgement)) {
    return {
      signature: SET_TOKEN_ALLOWED_ACK,
      functionName: 'setTokenAllowed',
      args: [token, allowed, acknowledgement],
      abi: overload(abi, 3),
    };
  }
  return {
    signature: SET_TOKEN_ALLOWED_LEGACY,
    functionName: 'setTokenAllowed',
    args: [token, allowed],
    abi: overload(abi, 2),
  };
}

const LEGACY_PROBE_ERRORS = new Set([
  'AbiDecodingDataSizeInvalidError',
  'AbiDecodingDataSizeTooSmallError',
  'AbiDecodingZeroDataError',
  'ContractFunctionRevertedError',
  'ContractFunctionZeroDataError',
  'ExecutionRevertedError',
]);

const TRANSPORT_PROBE_ERRORS = new Set([
  'HttpRequestError',
  'RpcRequestError',
  'SocketClosedError',
  'TimeoutError',
  'WaitForTransactionReceiptTimeoutError',
  'WebSocketRequestError',
]);

const TRANSPORT_CODES = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ETIMEDOUT',
  'NETWORK_ERROR',
  'TIMEOUT',
  'UND_ERR_CONNECT_TIMEOUT',
]);

function probeChain(error) {
  const chain = [];
  const seen = new Set();
  const pending = [error];
  while (pending.length > 0 && chain.length < 8) {
    const current = pending.shift();
    if (!current || typeof current !== 'object' || seen.has(current)) continue;
    seen.add(current);
    chain.push(current);
    pending.push(current.cause, current.error);
  }
  return chain;
}

function probeText(item) {
  return [item.shortMessage, item.message, item.details].filter(part => typeof part === 'string').join('\n');
}

/** A missing constant or a revert. Transport failures are not this. */
function isLegacyFactoryProbeError(error) {
  const chain = probeChain(error);
  for (const item of chain) {
    if (TRANSPORT_PROBE_ERRORS.has(item.name) || TRANSPORT_CODES.has(item.code)) return false;
    if (/timed out|timeout|network|fetch failed|ECONNRESET|ECONNREFUSED|socket hang up|getaddrinfo/i.test(probeText(item))
      && item.code !== 'CALL_EXCEPTION') return false;
  }
  for (const item of chain) {
    if (item.code === 'CALL_EXCEPTION' || LEGACY_PROBE_ERRORS.has(item.name)) return true;
    if (isEmptyOrUndecodableData(item.data) || isEmptyOrUndecodableData(item.raw)) return true;
    if (/returned no data|could not decode|execution reverted/i.test(probeText(item))) return true;
  }
  return false;
}

function isEmptyOrUndecodableData(value) {
  if (typeof value !== 'string') return false;
  return !bytes32.test(value) && /^0x[0-9a-fA-F]*$/.test(value);
}

/**
 * Read TOKEN_RISK_ACKNOWLEDGEMENT() on the factory.
 * MarketFactory has no on-chain interface-version string; this constant is the
 * version signal. A bytes32 means v7.3. A contract revert, CALL_EXCEPTION, or
 * empty or undecodable return is an older factory. Network, timeout, and any
 * other error propagate. The probe ABI is fixed, so a local artifact that
 * omits the function still results in an eth_call.
 */
export async function readTokenRiskAcknowledgement(client, factory) {
  let value;
  try {
    value = await client.readContract({
      address: factory,
      abi: TOKEN_RISK_PROBE_ABI,
      functionName: 'TOKEN_RISK_ACKNOWLEDGEMENT',
    });
  } catch (error) {
    if (isLegacyFactoryProbeError(error)) return null;
    throw error;
  }
  return typeof value === 'string' && bytes32.test(value) ? value : null;
}
