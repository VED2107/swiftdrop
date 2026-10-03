import { MOBILE_CONTROLLER, type ControllerConfig } from "@swiftdrop/transfer-engine";

export * from "./channel.ts";
export * from "./peer-transport.ts";
export * from "./receiver.ts";
export * from "./signal.ts";
export * from "./rendezvous.ts";
export * from "./path.ts";
export * from "./webrtc.ts";
export * from "./memory-link.ts";

/**
 * Phone-to-phone: one DataChannel, so "streams" are pipelined requests on it: while one
 * body is on the wire the next is read and hashed, and earlier ones are verified and
 * written by the receiver. Both ends are phones: the in-flight budget (sender reads +
 * receiver reassembly) is 32 MiB, plus the channel's 8 MiB send buffer. The first request
 * is a single 1 MiB block so the first bytes move as soon as the receiver accepts.
 */
export const PEER_CONTROLLER: ControllerConfig = {
  ...MOBILE_CONTROLLER,
  initialStreams: 2,
  maxStreams: 4,
  initialBlocks: 1,
  maxBlocks: 4,
  memoryBudget: 32 << 20,
  targetLatencyMs: [150, 900],
};
