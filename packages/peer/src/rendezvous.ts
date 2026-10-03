import { base64UrlToBytes, bytesToBase64Url, randomBytes } from "@swiftdrop/crypto";

/**
 * Rendezvous mailbox: how the scanning phone's answer reaches the phone that only *showed*
 * a QR. One QR, one scan; nobody scans back.
 *
 * SIGNALING ONLY. The mailbox carries one sealed SDP offer or answer per message (~1 KB).
 * It never sees file bytes: those move only over the WebRTC DataChannel between the two
 * phones, and no TURN relay is configured, so the data path cannot go through any server.
 *
 * Privacy: the QR holds a random 128-bit secret. Both mailbox topic names and
 * the AES-GCM key are derived from it, so the rendezvous server sees two random topic
 * names and ciphertext: not the SDP (local IPs, ICE credentials, DTLS fingerprints), not
 * device names. Without the QR nobody can read or forge a message; a forged or replayed
 * message fails decryption or doesn't match the live session id.
 *
 * Protocol: the publish/subscribe subset of ntfy (https://ntfy.sh, open source, self-
 * hostable): `POST <base>/<topic>` with a text body, and `GET <base>/<topic>/json?since=…`
 * streaming one JSON event per line. `apps/signal` is a small server speaking the same
 * subset, for self-hosting and tests.
 *
 *   box "host":  messages for the phone that showed the QR (answers)
 *   box "guest": messages for the phone that scanned it (re-dial offers after a drop)
 */

export type Box = "host" | "guest";

export interface MailMessage {
  kind: "offer" | "answer";
  /** an encoded signal (signal.ts) */
  signal: string;
}

export interface MailboxOptions {
  fetch?: typeof fetch;
}

const SECRET_BYTES = 16;
const MAX_MESSAGE = 3800; // ntfy turns bodies over 4096 bytes into attachments

export class Mailbox {
  private readonly fetchImpl: typeof fetch;
  private aes: Promise<CryptoKey> | null = null;
  private readonly topics = new Map<Box, Promise<string>>();

  private constructor(
    readonly base: string,
    private readonly secret: Uint8Array,
    opts: MailboxOptions,
  ) {
    this.fetchImpl = opts.fetch ?? globalThis.fetch.bind(globalThis);
  }

  static create(base: string, opts: MailboxOptions = {}): Mailbox {
    return new Mailbox(base.replace(/\/$/, ""), randomBytes(SECRET_BYTES), opts);
  }

  static fromKey(base: string, key: string, opts: MailboxOptions = {}): Mailbox {
    const secret = base64UrlToBytes(key);
    if (secret.byteLength < SECRET_BYTES) throw new Error("That code is incomplete. Scan it again.");
    return new Mailbox(base.replace(/\/$/, ""), secret, opts);
  }

  /** The secret, for the QR. */
  get key(): string {
    return bytesToBase64Url(this.secret);
  }

  async post(box: Box, msg: MailMessage, signal?: AbortSignal): Promise<void> {
    const body = await this.seal(JSON.stringify(msg));
    if (body.length > MAX_MESSAGE) throw new Error("signal too large for the mailbox");
    const res = await this.fetchImpl(`${this.base}/${await this.topic(box)}`, { method: "POST", body, signal: signal ?? null, cache: "no-store" });
    if (!res.ok) throw new Error(`mailbox ${res.status}`);
  }

  /**
   * Streams messages in `box` (including ones posted before listening) until stopped.
   * Reconnects on its own after network hiccups, resuming after the last message seen.
   */
  listen(box: Box, onMessage: (m: MailMessage) => void, onState?: (online: boolean) => void): () => void {
    const ac = new AbortController();
    let since = "all";
    const seen = new Set<string>();
    void (async () => {
      let delay = 500;
      while (!ac.signal.aborted) {
        try {
          const res = await this.fetchImpl(`${this.base}/${await this.topic(box)}/json?since=${since}`, { signal: ac.signal, cache: "no-store" });
          if (!res.ok || !res.body) throw new Error(`mailbox ${res.status}`);
          onState?.(true);
          delay = 500;
          const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
          let buf = "";
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += value;
            let nl: number;
            while ((nl = buf.indexOf("\n")) >= 0) {
              const line = buf.slice(0, nl).trim();
              buf = buf.slice(nl + 1);
              if (!line) continue;
              let ev: { id?: string; event?: string; message?: string };
              try {
                ev = JSON.parse(line) as typeof ev;
              } catch {
                continue;
              }
              if (ev.event !== "message" || !ev.id || !ev.message || seen.has(ev.id)) continue;
              seen.add(ev.id);
              since = ev.id;
              const m = await this.open(ev.message);
              if (m && !ac.signal.aborted) onMessage(m);
            }
          }
        } catch {
          if (ac.signal.aborted) return;
        }
        if (ac.signal.aborted) return;
        onState?.(false);
        await new Promise((r) => setTimeout(r, delay));
        delay = Math.min(delay * 2, 8000);
      }
    })();
    return () => ac.abort();
  }

  // ---------------------------------------------------------------------------

  private topic(box: Box): Promise<string> {
    let t = this.topics.get(box);
    if (!t) {
      t = this.derive(`topic:${box}`).then((d) => `sd${hex(d).slice(0, 40)}`);
      this.topics.set(box, t);
    }
    return t;
  }

  private cipher(): Promise<CryptoKey> {
    this.aes ??= this.derive("key").then((d) => crypto.subtle.importKey("raw", d as Uint8Array<ArrayBuffer>, "AES-GCM", false, ["encrypt", "decrypt"]));
    return this.aes;
  }

  private async derive(label: string): Promise<Uint8Array> {
    const info = new TextEncoder().encode(`swiftdrop-rendezvous-v1:${label}`);
    const input = new Uint8Array(this.secret.byteLength + info.byteLength);
    input.set(this.secret, 0);
    input.set(info, this.secret.byteLength);
    return new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  }

  private async seal(text: string): Promise<string> {
    const iv = randomBytes(12) as Uint8Array<ArrayBuffer>;
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await this.cipher(), new TextEncoder().encode(text)));
    const out = new Uint8Array(12 + ct.byteLength);
    out.set(iv, 0);
    out.set(ct, 12);
    return `1.${bytesToBase64Url(out)}`;
  }

  private async open(body: string): Promise<MailMessage | null> {
    if (!body.startsWith("1.")) return null;
    try {
      const raw = base64UrlToBytes(body.slice(2)) as Uint8Array<ArrayBuffer>;
      const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(0, 12) }, await this.cipher(), raw.subarray(12));
      const m = JSON.parse(new TextDecoder().decode(pt)) as MailMessage;
      if ((m.kind !== "offer" && m.kind !== "answer") || typeof m.signal !== "string") return null;
      return m;
    } catch {
      return null; // not ours, tampered, or garbage
    }
  }
}

function hex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}
