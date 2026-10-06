/// SwiftDrop core: protocol types, transport and platform boundaries, application
/// services. Pure Dart. Must never import `package:flutter` or any state-management
/// library (enforced by test/boundaries_test.dart).
library;

export 'src/format/format.dart';
export 'src/platform/bridge.dart';
export 'src/platform/destination.dart';
export 'src/platform/files.dart';
export 'src/platform/io_kind.dart';
export 'src/platform/system.dart';
export 'src/protocol/constants.dart';
export 'src/protocol/errors.dart';
export 'src/protocol/types.dart';
export 'src/services/idle.dart';
export 'src/services/models.dart';
export 'src/services/services.dart';
export 'src/transport/engine_transport.dart';
export 'src/transport/link.dart';
export 'src/transport/net_ifaces.dart';
