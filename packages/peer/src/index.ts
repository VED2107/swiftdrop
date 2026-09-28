import { MOBILE_CONTROLLER, type ControllerConfig } from "@swiftdrop/transfer-engine";

export * from "./channel.ts";
export * from "./peer-transport.ts";
export * from "./receiver.ts";
export * from "./signal.ts";
export * from "./path.ts";
export * from "./webrtc.ts";
export * from "./memory-link.ts";

/**
 * Phone-to-phone: one DataChannel, so "streams" are pipelined requests on it. Both ends
 * are phones, so the in-flight budget (sender reads + receiver reassembly) stays small.
 */
export const PEER_CONTROLLER: ControllerConfig = {
  ...MOBILE_CONTROLLER,
  initialStreams: 2,
  maxStreams: 4,
  initialBlocks: 1,
  maxBlocks: 4,
  memoryBudget: 16 << 20,
  targetLatencyMs: [150, 900],
};
