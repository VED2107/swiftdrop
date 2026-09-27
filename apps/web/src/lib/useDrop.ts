import { useEffect, useRef, useState } from "react";
import { fromDataTransfer, type Picked } from "./files.ts";

/** The whole window is the drop target. Returns whether files are hovering right now. */
export function useDropAnywhere(enabled: boolean, onDrop: (p: Picked[]) => void): boolean {
  const [over, setOver] = useState(false);
  const depth = useRef(0);
  const cb = useRef(onDrop);
  cb.current = onDrop;

  useEffect(() => {
    if (!enabled) return;
    const hasFiles = (e: DragEvent) => Boolean(e.dataTransfer?.types.includes("Files"));
    const enter = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth.current++;
      setOver(true);
    };
    const leave = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      if (--depth.current <= 0) {
        depth.current = 0;
        setOver(false);
      }
    };
    const over = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    };
    const drop = async (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth.current = 0;
      setOver(false);
      const picked = await fromDataTransfer(e.dataTransfer!);
      if (picked.length) cb.current(picked);
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragleave", leave);
    window.addEventListener("dragover", over);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("dragover", over);
      window.removeEventListener("drop", drop);
      depth.current = 0;
      setOver(false);
    };
  }, [enabled]);

  return over;
}
