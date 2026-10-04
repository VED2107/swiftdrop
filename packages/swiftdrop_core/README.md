# swiftdrop_core

Pure-Dart SwiftDrop runtime shared by the native app.

It owns device identity, LAN endpoint discovery, pairing for browser guests, TCP/HTTP transports, receive/send state, transfer history, duplicate handling, and resumable verified file writes. Flutter UI talks to this package through service interfaces in `lib/src/services`.

## Checks

```powershell
dart analyze
dart test
```
