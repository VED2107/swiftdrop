import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/testing.dart';

import 'app/app.dart';
import 'app/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(
    overrides: [
      if (demoMode) ...[
        deviceDirectoryProvider.overrideWithValue(DemoDeviceDirectory()),
        transferServiceProvider.overrideWithValue(DemoTransferService()),
        transferHistoryProvider.overrideWithValue(DemoTransferHistory()),
      ],
    ],
    child: const SwiftDropApp(),
  ));
}
