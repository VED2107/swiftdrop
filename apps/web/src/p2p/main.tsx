import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "../styles.css";
import { P2PApp } from "./P2PApp.tsx";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <P2PApp />
  </StrictMode>,
);
