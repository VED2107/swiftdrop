/**
 * Cheap, allocation-free-in-steady-state performance counters for one transfer.
 *
 * Stage times are summed across parallel requests, so they add up to more than wall time;
 * compare them to each other (where does a request spend its life?), not to the clock.
 */

export { Reservoir } from "@swiftdrop/shared";

export interface StageTimes {
  /** File -> ArrayBuffer (disk/IPC read into JS memory) */
  readMs: number;
  /** per-block digests on the sender */
  hashMs: number;
  /** building the request body (Blob / batch frame) */
  frameMs: number;
  /** request sent -> response received (wire + receiver verify + receiver disk write) */
  networkMs: number;
  /** per-file completion round trips (root digest check + rename on the receiver) */
  completeMs: number;
}

export interface Telemetry {
  stages: StageTimes;
  /** start() -> first byte may move: manifest negotiation (and conflict checks on the receiver) */
  prepareMs: number;
  /** start() -> first request body handed to the transport (includes the receiver's Accept) */
  startToFirstSendMs: number | null;
  /** start() -> first body acknowledged by the receiver */
  startToFirstAckMs: number | null;
  /** start() -> first whole file confirmed */
  startToFirstFileMs: number | null;
  requests: number;
  /** payload bytes acknowledged by the receiver */
  payloadBytes: number;
  /** payload + protocol overhead (batch headers, hash headers) actually put on the wire */
  wireBytes: number;
  inflightBytes: number;
  peakInflightBytes: number;
  /** 1-second throughput samples, bytes/s */
  throughputP50: number;
  throughputP95: number;
  /** request round-trip time, ms */
  latencyP50: number;
  latencyP95: number;
}

export function emptyStages(): StageTimes {
  return { readMs: 0, hashMs: 0, frameMs: 0, networkMs: 0, completeMs: 0 };
}
