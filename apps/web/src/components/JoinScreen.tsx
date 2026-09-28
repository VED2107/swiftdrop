import { useEffect, useRef, useState } from "react";
import { Api, ApiError, setToken } from "../lib/api.ts";
import { deviceLabel, deviceName, installId, isMobile } from "../lib/env.ts";
import { Swap } from "../ui/Swap.tsx";
import { Connection } from "./Connection.tsx";

// Module-level: survives remounts, so each QR token makes exactly one request.
const usedTokens = new Set<string>();

type Phase = { kind: "idle" } | { kind: "requesting" } | { kind: "waiting"; requestId: string } | { kind: "error"; text: string };

/** Phone side of pairing. QR token arrives in the URL fragment; otherwise type the code. */
export function JoinScreen({ pairToken, reason, onPaired }: { pairToken: string | null; reason: string | null; onPaired: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [code, setCode] = useState<string[]>(Array(6).fill(""));
  const boxes = useRef<Array<HTMLInputElement | null>>([]);

  async function request(body: { token?: string; code?: string }) {
    setPhase({ kind: "requesting" });
    try {
      const { requestId } = await Api.join({ ...body, deviceName: deviceName(), installId: installId() });
      setPhase({ kind: "waiting", requestId });
    } catch (e) {
      setPhase({ kind: "error", text: e instanceof ApiError ? e.message : "Couldn't reach your PC." });
      setCode(Array(6).fill(""));
      setTimeout(() => boxes.current[0]?.focus(), 50);
    }
  }

  useEffect(() => {
    if (pairToken && !usedTokens.has(pairToken)) {
      usedTokens.add(pairToken);
      void request({ token: pairToken });
    }
  }, [pairToken]);

  useEffect(() => {
    if (phase.kind !== "waiting") return;
    let stop = false;
    void (async () => {
      while (!stop) {
        try {
          const r = await Api.pollJoin(phase.requestId);
          if (r.status === "approved" && r.token) {
            setToken(r.token);
            onPaired();
            return;
          }
          if (r.status === "denied") {
            setPhase({ kind: "error", text: "Your PC declined the connection." });
            return;
          }
        } catch (e) {
          if (e instanceof ApiError && e.code !== "NETWORK") {
            setPhase({ kind: "error", text: e.message });
            return;
          }
        }
        await new Promise((r) => setTimeout(r, 900));
      }
    })();
    return () => {
      stop = true;
    };
  }, [phase, onPaired]);

  const setAt = (i: number, v: string) => {
    const chars = v.toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!chars) {
      const next = [...code];
      next[i] = "";
      setCode(next);
      return;
    }
    const next = [...code];
    for (let k = 0; k < chars.length && i + k < 6; k++) next[i + k] = chars[k]!;
    setCode(next);
    const focus = Math.min(5, i + chars.length);
    boxes.current[focus]?.focus();
    if (next.every(Boolean)) void request({ code: next.join("") });
  };

  const waiting = phase.kind === "waiting" || phase.kind === "requesting";

  return (
    <div className="flex flex-col items-center text-center gap-12 pt-10 md:pt-20 max-w-[560px] mx-auto">
      <Swap k={waiting ? "waiting" : "code"} className="w-full">
        {waiting ? (
          <div className="flex flex-col items-center gap-4">
            <h1 className="t-display" style={{ fontSize: "clamp(2.25rem, 1.6rem + 3vw, 3.5rem)" }}>
              {phase.kind === "requesting" ? "Reaching your PC…" : "Tap Allow on your PC"}
            </h1>
            <p className="t-lead">
              Your PC shows a request from “{deviceName()}”. This continues on its own.
            </p>
          </div>
        ) : (
          <div className="flex flex-col items-center gap-8">
            <div className="flex flex-col items-center gap-4">
              <h1 className="t-display" style={{ fontSize: "clamp(2.25rem, 1.6rem + 3vw, 3.5rem)" }}>
                Connect to your PC
              </h1>
              <p className="t-lead">{reason ?? "Enter the code shown on your PC, or scan its QR code with the Camera."}</p>
            </div>
            <form
              className="flex flex-col items-center gap-5 w-full"
              onSubmit={(e) => {
                e.preventDefault();
                if (code.every(Boolean)) void request({ code: code.join("") });
              }}
            >
              <div className="flex gap-2 justify-center w-full" role="group" aria-label="Pairing code">
                {code.map((c, i) => (
                  <input
                    key={i}
                    ref={(el) => {
                      boxes.current[i] = el;
                    }}
                    className="otp num"
                    data-filled={Boolean(c)}
                    value={c}
                    inputMode="text"
                    autoCapitalize="characters"
                    autoCorrect="off"
                    autoComplete={i === 0 ? "one-time-code" : "off"}
                    spellCheck={false}
                    maxLength={6}
                    autoFocus={i === 0 && !isMobile}
                    aria-label={`Character ${i + 1}`}
                    onChange={(e) => setAt(i, e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Backspace" && !c && i > 0) boxes.current[i - 1]?.focus();
                    }}
                    onFocus={(e) => e.currentTarget.select()}
                  />
                ))}
              </div>
              {phase.kind === "error" && (
                <p className="t-small swap-enter" role="alert" style={{ color: "var(--danger)" }}>
                  {phase.text}
                </p>
              )}
              <button className="btn btn-primary btn-lg" disabled={!code.every(Boolean)}>
                Connect
              </button>
            </form>
          </div>
        )}
      </Swap>

      <div className="w-full max-w-[400px]">
        <Connection
          state={waiting ? "connecting" : "waiting"}
          left={{ name: deviceLabel(), kind: "phone", live: true }}
          right={{ name: "PC", kind: "pc", live: waiting }}
          compact
          caption={
            <>
              <span className="dot" data-state={waiting ? "live" : undefined} />
              Same Wi-Fi · No cloud required
            </>
          }
        />
      </div>
    </div>
  );
}
