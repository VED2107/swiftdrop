import type { Offer, OfferFile } from "@swiftdrop/protocol";
import { formatBytes, formatCount } from "@swiftdrop/shared";
import { Download, FileText, Film, ImageDown, Images, Share, X } from "lucide-react";
import { useState } from "react";
import { Api, ApiError, getToken } from "../lib/api.ts";
import { canShareFiles, isAndroid, isIOS } from "../lib/env.ts";
import { kindOf } from "../lib/files.ts";
import { notify, useApp } from "../lib/store.ts";

/** iOS holds shared files in memory; past this the share sheet tends to give up. */
const PHOTOS_SHARE_LIMIT = 400e6;

/** Files the PC set out for the phone. Plain downloads → Safari's download manager (no RAM ceiling). */
export function Offers({ perspective }: { perspective: "host" | "guest" }) {
  const offers = useApp((s) => s.offers);
  if (!offers.length) return null;
  return (
    <section aria-labelledby="offers-title" className="flex flex-col gap-3">
      <h2 id="offers-title" className="t-section">
        {perspective === "guest" ? "From your PC" : "Waiting on your phone"}
      </h2>
      <div>
        {offers.map((o, i) => (
          <OfferRow key={o.transferId} offer={o} perspective={perspective} i={i} />
        ))}
      </div>
    </section>
  );
}

function OfferRow({ offer, perspective, i }: { offer: Offer; perspective: "host" | "guest"; i: number }) {
  const [prepared, setPrepared] = useState<File[] | null>(null);
  const [busy, setBusy] = useState(false);
  const kinds = offer.files.map((f) => kindOf(f.name, f.type));
  const allMedia = kinds.every((k) => k === "image" || k === "video");
  const Icon = allMedia ? (kinds.every((k) => k === "video") ? Film : Images) : FileText;
  const canPhotos = perspective === "guest" && isIOS && allMedia && offer.totalBytes <= PHOTOS_SHARE_LIMIT && "share" in navigator;

  async function download(file?: OfferFile) {
    try {
      const { ticket } = await Api.ticket(offer.transferId);
      const path = file || offer.files.length === 1 ? `files/${(file ?? offer.files[0]!).id}` : "zip";
      const href = `/api/offers/${offer.transferId}/${path}?ticket=${encodeURIComponent(ticket)}`;
      // A failed navigation would save the error body as a "file"; check first.
      const head = await fetch(href, { method: "HEAD", cache: "no-store" }).catch(() => null);
      if (!head) throw new ApiError("NETWORK", 0);
      if (!head.ok) throw new ApiError(head.status === 410 ? "SOURCE_CHANGED" : head.status === 404 ? "NOT_FOUND" : "SERVER", head.status);
      const a = document.createElement("a");
      a.href = href;
      a.download = "";
      a.rel = "noopener";
      document.body.append(a);
      a.click();
      a.remove();
      if (isIOS) notify("Downloading — you'll find it in Files › Downloads.");
      else if (isAndroid) notify("Downloading — you'll find it in Downloads. Photos also appear in your gallery.");
    } catch (err) {
      notify((err as Error).message, "error");
    }
  }

  // Two taps on purpose: iOS only opens the share sheet from a fresh tap,
  // and fetching the files first can outlast that window.
  async function prepare() {
    setBusy(true);
    try {
      const files = await Promise.all(
        offer.files.map(async (f) => {
          const res = await fetch(`/api/offers/${offer.transferId}/files/${f.id}`, { headers: { authorization: `Bearer ${getToken()}` } });
          if (res.status === 410) throw new ApiError("SOURCE_CHANGED", 410);
          if (!res.ok) throw new Error("Couldn't load the files from your PC.");
          return new File([await res.blob()], f.name, { type: f.type || "application/octet-stream" });
        }),
      );
      if (!canShareFiles(files)) throw new Error("This browser can't hand these to Photos. Use Download instead.");
      setPrepared(files);
    } catch (err) {
      notify((err as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function share() {
    if (!prepared) return;
    try {
      await navigator.share({ files: prepared });
    } catch (err) {
      if ((err as Error).name !== "AbortError") notify("The share sheet closed before saving.", "error");
    } finally {
      setPrepared(null);
    }
  }

  return (
    <div className="row rise" style={{ "--i": i } as React.CSSProperties}>
      <div className="row-thumb">
        <Icon size={17} strokeWidth={1.5} />
      </div>
      <div className="min-w-0">
        <div className="truncate" style={{ fontWeight: 500, letterSpacing: "-0.01em" }}>
          {offer.label || "Files"}
        </div>
        <div className="t-small num">
          {formatCount(offer.files.length)} {offer.files.length === 1 ? "file" : "files"} · {formatBytes(offer.totalBytes)}
        </div>
      </div>
      {perspective === "guest" ? (
        <div className="flex items-center gap-1">
          {canPhotos &&
            (prepared ? (
              <button className="btn btn-primary btn-sm" onClick={() => void share()}>
                <Share size={15} strokeWidth={1.75} /> Save to Photos
              </button>
            ) : (
              <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => void prepare()} aria-label="Prepare for Photos">
                <ImageDown size={15} strokeWidth={1.75} /> {busy ? "Loading…" : "Photos"}
              </button>
            ))}
          <button className="btn btn-secondary btn-sm" onClick={() => void download()}>
            <Download size={15} strokeWidth={1.75} /> {offer.files.length === 1 ? "Download" : "Download .zip"}
          </button>
        </div>
      ) : (
        <button className="btn btn-ghost btn-sm reveal" onClick={() => void Api.removeOffer(offer.transferId).catch((e: Error) => notify(e.message, "error"))} aria-label={`Remove ${offer.label}`}>
          <X size={15} strokeWidth={1.75} /> Remove
        </button>
      )}
    </div>
  );
}
