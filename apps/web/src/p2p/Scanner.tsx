import jsQR from "jsqr";
import { useEffect, useRef, useState } from "react";

/**
 * In-app QR scanner. Camera permission has a second job here: while a page holds it,
 * Safari and Chrome put the phone's real LAN address in its WebRTC candidates instead of
 * an mDNS name, which keeps the direct connection working on networks that block mDNS.
 * iOS Safari has no BarcodeDetector, so frames are decoded with jsQR.
 */
export function Scanner({ onResult, hint }: { onResult: (text: string) => void; hint: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [manual, setManual] = useState("");
  const done = useRef(false);

  useEffect(() => {
    let stream: MediaStream | null = null;
    let raf = 0;
    let last = 0;
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const tick = (t: number) => {
      raf = requestAnimationFrame(tick);
      const v = video.current;
      if (!v || !ctx || v.readyState < 2 || t - last < 120 || done.current) return;
      last = t;
      const w = Math.min(640, v.videoWidth);
      const h = Math.round((v.videoHeight / v.videoWidth) * w);
      canvas.width = w;
      canvas.height = h;
      ctx.drawImage(v, 0, 0, w, h);
      const code = jsQR(ctx.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: "dontInvert" });
      if (code?.data) {
        done.current = true;
        onResult(code.data);
      }
    };
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
        if (video.current) {
          video.current.srcObject = stream;
          await video.current.play().catch(() => undefined);
        }
        raf = requestAnimationFrame(tick);
      } catch {
        setError(isSecureContext ? "Camera unavailable. Allow camera access, or paste the code below." : "The camera needs a secure (https) page. Paste the code below instead.");
      }
    })();
    return () => {
      cancelAnimationFrame(raf);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, [onResult]);

  return (
    <div className="flex flex-col gap-4">
      {!error && (
        <div className="relative w-full overflow-hidden" style={{ aspectRatio: "1", borderRadius: 28, background: "var(--surface-2)" }}>
          <video ref={video} playsInline muted className="absolute inset-0 w-full h-full object-cover" />
          <div className="absolute inset-[18%] pointer-events-none" style={{ border: "2px solid rgba(255,255,255,0.85)", borderRadius: 20 }} />
        </div>
      )}
      <p className="t-small">{error ?? hint}</p>
      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (manual.trim()) onResult(manual.trim());
        }}
      >
        <input
          aria-label="Paste code"
          className="flex-1 min-w-0 mono"
          style={{ background: "var(--surface-2)", border: "1px solid var(--hairline-2)", borderRadius: 12, padding: "10px 12px", color: "var(--text)" }}
          placeholder="…or paste the code"
          value={manual}
          onChange={(e) => setManual(e.target.value)}
        />
        <button className="btn btn-secondary btn-sm" type="submit">
          Use code
        </button>
      </form>
    </div>
  );
}
