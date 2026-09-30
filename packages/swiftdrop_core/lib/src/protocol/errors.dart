/// Error codes travel on the wire; messages are what people read.
/// Same codes, same order as `ERROR_CODES` in `packages/protocol`.
enum ErrorCode {
  network('NETWORK'),
  unauthorized('UNAUTHORIZED'),
  forbidden('FORBIDDEN'),
  pairingExpired('PAIRING_EXPIRED'),
  pairingDenied('PAIRING_DENIED'),
  declined('DECLINED'),
  nameTaken('NAME_TAKEN'),
  rateLimited('RATE_LIMITED'),
  notFound('NOT_FOUND'),
  badRequest('BAD_REQUEST'),
  badFrame('BAD_FRAME'),
  integrity('INTEGRITY'),
  incomplete('INCOMPLETE'),
  tooLarge('TOO_LARGE'),
  diskFull('DISK_FULL'),
  diskWrite('DISK_WRITE'),
  sourceChanged('SOURCE_CHANGED'),
  cancelled('CANCELLED'),
  server('SERVER');

  const ErrorCode(this.wire);
  final String wire;

  /// Unknown codes from a newer peer degrade to [server], never throw.
  static ErrorCode fromWire(String? code) {
    for (final c in values) {
      if (c.wire == code) return c;
    }
    return server;
  }
}

/// Plain-language messages for the native app. Unlike the web copy, these don't assume
/// the other end is a PC.
const Map<ErrorCode, String> userMessages = {
  ErrorCode.network: 'Connection interrupted. Reconnecting…',
  ErrorCode.unauthorized: "This device isn't paired anymore. Connect it again.",
  ErrorCode.forbidden: "That action isn't allowed from this device.",
  ErrorCode.pairingExpired: 'That code expired. Show a fresh one on the other device.',
  ErrorCode.pairingDenied: 'The other device declined the connection.',
  ErrorCode.declined: 'The other device declined the files.',
  ErrorCode.nameTaken: 'Another device already uses that name. Pick a different one.',
  ErrorCode.rateLimited: 'Too many attempts. Wait a minute and try again.',
  ErrorCode.notFound: 'That transfer no longer exists on the other device.',
  ErrorCode.badRequest: "Something about that request didn't look right. Try again.",
  ErrorCode.badFrame: 'Part of the transfer arrived damaged. Resending it.',
  ErrorCode.integrity: 'Part of a file arrived damaged. Resending it automatically.',
  ErrorCode.incomplete: 'Catching up with the other device…',
  ErrorCode.tooLarge: 'That file is bigger than the other device accepts.',
  ErrorCode.diskFull: 'The receiving device is out of space.',
  ErrorCode.diskWrite: "Couldn't save the file. Choose another location.",
  ErrorCode.sourceChanged: 'That file changed after it was shared. Share it again.',
  ErrorCode.cancelled: 'Transfer cancelled.',
  ErrorCode.server: 'The other device hit an unexpected problem. Try again.',
};

class ProtocolException implements Exception {
  ProtocolException(this.code, [this.detail]);
  final ErrorCode code;
  final String? detail;

  String get userMessage => userMessages[code]!;

  @override
  String toString() => 'ProtocolException(${code.wire}${detail == null ? '' : ': $detail'})';
}
