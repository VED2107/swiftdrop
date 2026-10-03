import jsQR from "jsqr";
import { CameraOff } from "lucide-react";
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
  const [live, setLive] = useState(false);
  const [manual, setManual] = useState("");
  const done = useRef(false);
  // The page repaints on a clock; a fresh callback each render must not restart the camera.
  const result = useRef(onResult);
  result.current = onResult;

  useEffect(() => {
    let stream: MediaStream | null = null;
    let raf = 0;
    let last = 0;
    let stopped = false;
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
        result.current(code.data);
        // A code that turns out wrong leaves this scanner up: look again after a beat.
        setTimeout(() => (done.current = false), 2000);
      }
    };
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
        if (stopped) return stream.getTracks().forEach((t) => t.stop());
        if (video.current) {
          video.current.srcObject = stream;
          await video.current.play().catch(() => undefined);
          setLive(true);
        }
        raf = requestAnimationFrame(tick);
      } catch {
        setError(isSecureContext ? "Camera unavailable. Allow camera access in your browser settings, or paste the code below." : "The camera needs a secure (https) page. Paste the code below instead.");
      }
    })();
    return () => {
      stopped = true;
      cancelAnimationFrame(raf);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  return (
    <div className="flex flex-col gap-5">
      <div className="p2p-viewfinder" data-live={live}>
        {error ? (
          <div className="p2p-viewfinder-empty">
            <CameraOff size={24} strokeWidth={1.5} />
            <p className="t-small">{error}</p>
          </div>
        ) : (
          <video ref={video} playsInline muted aria-label="Camera view for scanning the code" />
        )}
        <span className="vf-c vf-tl" aria-hidden />
        <span className="vf-c vf-tr" aria-hidden />
        <span className="vf-c vf-bl" aria-hidden />
        <span className="vf-c vf-br" aria-hidden />
      </div>
      {!error && <p className="t-small text-center">{hint}</p>}
      <form
        className="p2p-manual"
        onSubmit={(e) => {
          e.preventDefault();
          if (manual.trim()) onResult(manual.trim());
        }}
      >
        <input aria-label="Paste code" className="field p2p-paste flex-1 min-w-0" placeholder="Paste a code" autoComplete="off" autoCapitalize="off" spellCheck={false} value={manual} onChange={(e) => setManual(e.target.value)} />
        <button className="btn btn-secondary" type="submit" disabled={!manual.trim()}>
          Use code
        </button>
      </form>
    </div>
  );
}
