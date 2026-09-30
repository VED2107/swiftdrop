/// SwiftDrop wire protocol v1 constants. Must match `packages/protocol/src/index.ts`;
/// the cross-language vectors (Phase 3) assert it.
library;

const int protocolVersion = 1;

/// Unit of integrity and resume. Resume state never depends on request size.
const int blockSize = 1 << 20;

/// A request carries 1..16 contiguous blocks (16 MiB max body).
const int maxBlocksPerChunk = 16;

/// Files up to this size ride in batch frames.
const int smallFileMax = 512 * 1024;
const int batchTargetBytes = 8 << 20;
const int batchMaxFiles = 512;
const int maxFilesPerTransfer = 100000;

/// DNS-SD service type the native apps advertise and browse.
const String serviceType = '_swiftdrop._tcp';
