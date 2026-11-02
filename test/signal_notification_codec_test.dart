import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/carrier_names.dart';
import 'package:cell_tower_monitor/services/signal_notification.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pinned notification's arguments have to survive the platform codec.
///
/// Passing the operator list's Sets straight through threw
/// `Invalid argument: Instance of 'UnmodifiableSetView<String>'` inside
/// `invokeMethod`, so the toggle never reached Kotlin and looked dead. These
/// tests pin the encodable shape.
void main() {
  const codec = StandardMethodCodec();

  test('notificationStart arguments encode, tags as lists', () {
    // The native side compares PLMNs in the compact form (mcc+mcc), which is
    // what the parsed list carries.
    CarrierNames.seed(
      const {
        '310-830': 'T-Satellite',
        '312-190': 'T-911',
        '313-700': 'Ameren',
      },
      satellites: const {'310830', '312190'},
      lteMs: const {'313700'},
    );

    final args = SignalNotification().notificationStartArguments();

    expect(args['satellitePlmns'], isA<List<String>>());
    expect(args['lteMPlmns'], isA<List<String>>());
    expect(args['satellitePlmns'] as List, containsAll(<String>['310830', '312190']));
    expect(args['lteMPlmns'] as List, contains('313700'));

    // The real check: this is what used to throw, before any native call.
    final bytes = codec.encodeMethodCall(
      MethodCall('notificationStart', args),
    );
    final decoded = codec.decodeMethodCall(bytes);
    expect(decoded.method, 'notificationStart');
    final sent = decoded.arguments as Map<Object?, Object?>;
    expect(sent['aliasB106'], kA10eBandAlias);
    expect((sent['satellitePlmns'] as List).length, 2);
    expect((sent['lteMPlmns'] as List).single, '313700');
  });

  test('a raw Set is not encodable, which is why it broke', () {
    expect(
      () => codec.encodeMethodCall(
        const MethodCall('notificationStart', {
          'satellitePlmns': <String>{'310830'},
        }),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
