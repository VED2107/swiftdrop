# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Vite + React + TypeScript + Tailwind (static SPA) served by a local Node.js server that runs on the Windows PC. pnpm monorepo. Zod validation, Vitest + Playwright tests. Chosen by the user over Next.js because the SPA is served by the same process that moves the bytes, so there is no proxy hop on the data path.

## Users

General public. Anyone with an iPhone or Android phone and a Windows PC on the same Wi-Fi (or an iPhone hotspot) who wants to move photos, videos, and files between them without cables, accounts, or cloud uploads. Often non-technical. Typical scene: a person at a desk, laptop open, phone in hand, wanting to dump hundreds or thousands of camera-roll items to the PC, or push a file from the PC to the phone.

## Product Purpose

SwiftDrop moves files between a phone (iPhone or Android) and a Windows PC over the local network as fast as the Wi-Fi allows. Success: transfers run close to the link's real bandwidth, survive Wi-Fi drops by resuming instead of restarting, and never pass through the internet.

## Positioning

The PC is the endpoint: a small local server on Windows receives chunks straight from iPhone Safari over parallel HTTP streams and writes them directly to a real folder on disk, and serves downloads the iPhone saves through Safari's native download manager. No cloud relay, no browser memory ceiling, no install on the iPhone.

## Operating Context

- Windows: user runs SwiftDrop once, opens it in Chrome/Edge/Firefox at localhost, sees a QR code and short code.
- iPhone: scans the QR with the Camera app, lands in Safari (or iOS Chrome), confirms, picks photos/files.
- Works with no internet as long as both devices share a LAN or hotspot.
- The PC user approves each new device before it can transfer.

## Capabilities and Constraints

- iPhone → PC: parallel chunked upload, adaptive concurrency (browser caps ~6 connections per host), per-chunk SHA-256, resume after disconnect, small-file batching, duplicate policy (replace / skip / keep both).
- PC → iPhone: PC stages files locally, iPhone downloads each file or a streamed ZIP via Safari's download manager (Files app). Photos/videos can go to the Photos library through the share sheet only for sizes iOS can hold in memory.
- iOS cannot write to arbitrary folders from the web, cannot keep JavaScript running while backgrounded or locked, and may transcode HEIC/video in the photo picker. The UI must say so plainly, not pretend otherwise.
- Windows needs an inbound firewall allowance for the server port (Windows prompts on first run).

## Brand Commitments

Name: SwiftDrop (working name). User-facing errors must be plain language, never raw technical codes.

## Evidence on Hand

No real benchmarks, testimonials, or customers exist yet. Speed numbers shown in the UI must come from live measurement only; never display invented throughput claims.

## Product Principles

1. Measured speed over claimed speed: every number on screen is live and real.
2. Never lose progress: interruptions pause and resume, never restart.
3. Two obvious actions (send, receive) and always-visible connection state.
4. Honest about the platform: explain iOS limits instead of hiding them.
5. The data path never leaves the local network.

## Accessibility & Inclusion

Standard WCAG AA contrast, full keyboard use on desktop, large touch targets on iPhone, respects reduced motion.
