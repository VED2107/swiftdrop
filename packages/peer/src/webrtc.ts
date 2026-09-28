import { DataChannelTransport, type FramingOptions } from "./channel.ts";
import { decodeSignal, encodeSignal, type SignalPayload } from "./signal.ts";

/**
 * One phone-to-phone connection. Signaling is whatever carries the two strings this class
 * produces and consumes (a QR today); it only ever holds SDP and ICE — never file data.
 *
 * Non-trickle ICE: we wait for candidate gathering to finish so one offer and one answer
 * are the entire exchange. No STUN/TURN servers are configured, so only local candidates
 * exist and the data path cannot leave the local network.
 */

export interface PeerSessionOptions {
  /** Shown to the other phone ("Sending from …"). */
  name: string;
  /** ICE gathering budget; host candidates normally finish well inside it. */
  gatherTimeoutMs?: number;
  iceServers?: RTCIceServer[];
  framing?: FramingOptions;
}

export class PeerSession {
  readonly pc: RTCPeerConnection;
  private channel: RTCDataChannel | null = null;
  private readonly channelReady: Promise<RTCDataChannel>;
  private resolveChannel!: (ch: RTCDataChannel) => void;
  /** Name the other phone sent in its offer/answer. */
  remoteName = "";
  readonly sessionId: string;

  private constructor(
    private readonly opts: PeerSessionOptions,
    sessionId: string,
  ) {
    this.sessionId = sessionId;
    this.pc = new RTCPeerConnection({ iceServers: opts.iceServers ?? [] });
    this.channelReady = new Promise((r) => (this.resolveChannel = r));
    this.pc.addEventListener("datachannel", (ev) => this.adopt(ev.channel));
  }

  /** Sender side: creates the channel and an offer string to show as a QR. */
  static async offer(opts: PeerSessionOptions): Promise<{ session: PeerSession; offer: string }> {
    const s = new PeerSession(opts, randomId());
    s.adopt(s.pc.createDataChannel("swiftdrop", { ordered: true }));
    await s.pc.setLocalDescription(await s.pc.createOffer());
    await s.gathered();
    return { session: s, offer: await s.localSignal() };
  }

  /** Receiver side: takes the scanned offer, returns the answer string to show back. */
  static async answer(offer: string, opts: PeerSessionOptions): Promise<{ session: PeerSession; answer: string }> {
    const remote = await decodeSignal(offer);
    if (remote.type !== "offer") throw new Error("That code isn't a SwiftDrop offer.");
    const s = new PeerSession(opts, remote.sid);
    s.remoteName = remote.name;
    await s.pc.setRemoteDescription({ type: "offer", sdp: remote.sdp });
    await s.pc.setLocalDescription(await s.pc.createAnswer());
    await s.gathered();
    return { session: s, answer: await s.localSignal() };
  }

  /** Sender side: completes the handshake with the scanned answer. */
  async accept(answer: string): Promise<void> {
    const remote = await decodeSignal(answer);
    if (remote.type !== "answer") throw new Error("That code isn't a SwiftDrop reply.");
    if (remote.sid !== this.sessionId) throw new Error("That reply belongs to a different connection. Scan the newest one.");
    this.remoteName = remote.name;
    await this.pc.setRemoteDescription({ type: "answer", sdp: remote.sdp });
  }

  /** Resolves with the data-plane transport once the DataChannel is open. */
  async transport(): Promise<DataChannelTransport> {
    const ch = await this.channelReady;
    const t = new DataChannelTransport(ch, { maxMessageSize: this.pc.sctp?.maxMessageSize, ...this.opts.framing });
    await t.connect();
    return t;
  }

  close() {
    this.channel?.close();
    this.pc.close();
  }

  private adopt(ch: RTCDataChannel) {
    this.channel = ch;
    this.resolveChannel(ch);
    // A failed ICE connection doesn't always close the channel promptly; make it.
    this.pc.addEventListener("connectionstatechange", () => {
      if (this.pc.connectionState === "failed" || this.pc.connectionState === "closed") ch.close();
    });
  }

  private gathered(): Promise<void> {
    if (this.pc.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.pc.removeEventListener("icegatheringstatechange", check);
        resolve();
      };
      const check = () => this.pc.iceGatheringState === "complete" && done();
      const timer = setTimeout(done, this.opts.gatherTimeoutMs ?? 3000);
      this.pc.addEventListener("icegatheringstatechange", check);
    });
  }

  private localSignal(): Promise<string> {
    const d = this.pc.localDescription;
    if (!d) throw new Error("no local description");
    const payload: SignalPayload = { v: 1, type: d.type as "offer" | "answer", sdp: d.sdp, sid: this.sessionId, name: this.opts.name.slice(0, 40) };
    return encodeSignal(payload);
  }
}

function randomId(): string {
  const b = new Uint8Array(9);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}
