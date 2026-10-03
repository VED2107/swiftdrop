import { Mailbox, pairLink, parsePairCode, PeerSession, type DataChannelTransport, type FramingOptions } from "@swiftdrop/peer";

/**
 * One QR, one scan. The sender (host) shows a QR carrying its WebRTC offer and a mailbox
 * secret; the receiver (guest) scans it, answers, and drops the sealed answer in the
 * rendezvous mailbox. Nobody scans back.
 *
 * SIGNALING ONLY: the mailbox and the QR carry SDP (connection details). File bytes only
 * ever move over the DataChannel between the two phones.
 *
 * After a drop, the host re-dials on its own: a fresh offer goes to the guest's mailbox
 * box, the guest answers into the host's, and the new channel is handed to the same
 * transfer, which resumes from the receiver's bitmaps. Without internet the mailbox is
 * unreachable and both sides fall back to showing/scanning one more QR (the reply).
 */

export interface Linked {
  session: PeerSession;
  link: DataChannelTransport;
}

interface Common {
  name: string;
  /** Rendezvous base URL; null = offline pairing (reply QR). */
  signal: string | null;
  framing?: FramingOptions;
  onLinked(l: Linked): void;
  onError?(message: string): void;
  /** Whether the rendezvous answered (false: offer the reply-QR fallback). */
  onMailbox?(online: boolean): void;
}

const POST_TIMEOUT_MS = 5000;
const base = () => `${location.origin}${location.pathname}`;

/** The phone that shows the QR (the sender). */
export class HostPairing {
  session: PeerSession | null = null;
  private mailbox: Mailbox | null = null;
  private stopListening: (() => void) | null = null;
  private stopped = false;

  constructor(private readonly o: Common) {}

  /** Creates the offer (ICE gathered) and returns the link the QR encodes. */
  async start(): Promise<string> {
    const { session, offer } = await PeerSession.offer({ name: this.o.name, ...(this.o.framing ? { framing: this.o.framing } : {}) });
    this.replace(session);
    if (this.o.signal) {
      this.mailbox ??= Mailbox.create(this.o.signal);
      this.stopListening ??= this.mailbox.listen(
        "host",
        (m) => {
          if (m.kind === "answer") void this.takeAnswer(m.signal).catch(() => undefined);
        },
        (online) => this.o.onMailbox?.(online),
      );
    }
    return pairLink(base(), { offer, key: this.mailbox?.key ?? null });
  }

  /** Offline fallback: the receiver's reply QR, scanned or pasted. */
  takeReply(text: string): Promise<void> {
    return this.takeAnswer(text);
  }

  /** After a drop: a fresh offer through the mailbox. Resolves once posted. */
  async redial(): Promise<boolean> {
    if (!this.mailbox || this.stopped) return false;
    const { session, offer } = await PeerSession.offer({ name: this.o.name, ...(this.o.framing ? { framing: this.o.framing } : {}) });
    this.replace(session);
    try {
      await withTimeout((s) => this.mailbox!.post("guest", { kind: "offer", signal: offer }, s), POST_TIMEOUT_MS);
      return true;
    } catch {
      return false;
    }
  }

  stop() {
    this.stopped = true;
    this.stopListening?.();
    this.session?.close();
  }

  private async takeAnswer(text: string) {
    const s = this.session;
    if (!s || this.stopped || s.pc.signalingState !== "have-local-offer") return;
    await s.accept(text); // throws on a stale session id: that answer belongs to an older offer
    const link = await s.transport();
    if (this.session === s && !this.stopped) this.o.onLinked({ session: s, link });
  }

  private replace(s: PeerSession) {
    const old = this.session;
    this.session = s;
    // An old session that still carries a live channel stays up until it dies on its own.
    if (old && old.pc.connectionState !== "connected") old.close();
  }
}

/** The phone that scans (the receiver). */
export class GuestPairing {
  session: PeerSession | null = null;
  private mailbox: Mailbox | null = null;
  private stopListening: (() => void) | null = null;
  private stopped = false;
  private readonly answered = new Set<string>();

  constructor(private readonly o: Common) {}

  /**
   * Answer a scanned code. Returns null when the answer went through the mailbox (the
   * phones connect on their own), or a reply link to show as a QR when it couldn't.
   */
  async scan(text: string): Promise<string | null> {
    const code = parsePairCode(text);
    if (!code) throw new Error("That isn't a SwiftDrop code. Scan the code on the sending phone.");
    if (code.key && this.o.signal) {
      this.mailbox = Mailbox.fromKey(this.o.signal, code.key);
      this.stopListening?.();
      this.stopListening = this.mailbox.listen("guest", (m) => {
        if (m.kind === "offer") void this.answer(m.signal, true).catch(() => undefined);
      });
    }
    return this.answer(code.offer, false);
  }

  stop() {
    this.stopped = true;
    this.stopListening?.();
    this.session?.close();
  }

  private async answer(offer: string, redial: boolean): Promise<string | null> {
    if (this.stopped || this.answered.has(offer)) return null;
    this.answered.add(offer);
    const { session, answer } = await PeerSession.answer(offer, { name: this.o.name, ...(this.o.framing ? { framing: this.o.framing } : {}) });
    const old = this.session;
    this.session = session;
    if (old && old.pc.connectionState !== "connected") old.close();
    void session.transport().then((link) => {
      if (this.session === session && !this.stopped) this.o.onLinked({ session, link });
    }, () => undefined);
    if (this.mailbox) {
      try {
        await withTimeout((s) => this.mailbox!.post("host", { kind: "answer", signal: answer }, s), POST_TIMEOUT_MS);
        return null;
      } catch {
        if (redial) return null; // nothing to show for a re-dial; the next one may get through
      }
    }
    return `${base()}#a=${answer}`;
  }
}

async function withTimeout(fn: (signal: AbortSignal) => Promise<void>, ms: number) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), ms);
  try {
    await fn(ac.signal);
  } finally {
    clearTimeout(t);
  }
}
