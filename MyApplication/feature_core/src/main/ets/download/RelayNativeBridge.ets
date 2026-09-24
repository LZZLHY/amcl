export interface RelayStatsNative {
  requests: number;
  failures: number;
  fallbacks: number;
  authRejects: number;
  tripped: boolean;
  usable: boolean;
}

export interface RelayNativeBridge {
  configure(base: string, ticket: string, sessionKey: string, requireProof: boolean, expiresAtMs: number): void;
  clear(): void;
  stats(): RelayStatsNative;
}

let bridge: RelayNativeBridge | undefined = undefined;
export function setRelayNativeBridge(value: RelayNativeBridge | undefined): void { bridge = value; }
export function getRelayNativeBridge(): RelayNativeBridge {
  if (bridge === undefined) throw new Error('Relay native bridge is not initialized');
  return bridge;
}
