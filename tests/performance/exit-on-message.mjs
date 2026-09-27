// Preloaded into the lab server: a clean exit on request, so --cpu-prof/--heap-prof get written.
// (Windows has no SIGINT for child processes.)
process.on("message", (m) => m === "exit" && process.exit(0));
