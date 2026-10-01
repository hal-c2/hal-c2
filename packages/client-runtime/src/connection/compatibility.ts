import {
  ORCHESTRATION_PROTOCOL_QUERY_PARAM,
  ORCHESTRATION_PROTOCOL_VERSION,
  type ExecutionEnvironmentDescriptor,
} from "@hal-c2/contracts";

import { ConnectionBlockedError } from "./model.ts";

/** Protocol 3 is the shape-sync protocol served by clustered MCs. */
export const SHAPE_PROTOCOL_VERSION = 3;

/**
 * Whether a server with this descriptor serves `environmentId`: its own, or on a
 * protocol-3 MC, any environment of its cluster, which it reaches for the client.
 */
export function descriptorServesEnvironment(
  descriptor: ExecutionEnvironmentDescriptor,
  environmentId: string,
): boolean {
  if (descriptor.environmentId === environmentId) return true;
  return (
    descriptor.orchestrationProtocolVersion === SHAPE_PROTOCOL_VERSION &&
    (descriptor.cluster ?? []).some((member) => member.environmentId === environmentId)
  );
}

export function orchestrationProtocolCompatibilityError(
  descriptor: ExecutionEnvironmentDescriptor,
): ConnectionBlockedError | null {
  // Servers shipped before negotiation use the original wire protocol.
  const serverProtocolVersion = descriptor.orchestrationProtocolVersion ?? 1;
  if (
    serverProtocolVersion === ORCHESTRATION_PROTOCOL_VERSION ||
    serverProtocolVersion === SHAPE_PROTOCOL_VERSION
  ) {
    return null;
  }
  return new ConnectionBlockedError({
    reason: "unsupported",
    detail:
      serverProtocolVersion > ORCHESTRATION_PROTOCOL_VERSION
        ? `This client is not supported by this server. Update your app or use a compatible release to connect to ${descriptor.label}.`
        : `This client requires a newer server. Update HAL-C2 on ${descriptor.label} to connect.`,
  });
}

export function appendOrchestrationProtocol(socketUrl: string): string {
  const url = new URL(socketUrl);
  url.searchParams.set(ORCHESTRATION_PROTOCOL_QUERY_PARAM, String(ORCHESTRATION_PROTOCOL_VERSION));
  return url.toString();
}
