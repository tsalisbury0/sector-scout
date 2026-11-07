import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/widgets/scanner_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mode chip and the IMS line while a voice call is up.
///
/// 5G NSA is unavailable during VoLTE calls, and the platform keeps reporting
/// `NR_NSA` for a while after the leg has gone, so the chip has to decide for
/// itself when to stop claiming 5G. The case cannot be reached without placing
/// a real call on a real network, so the rule is pinned here instead.
void main() {
  SimReading sim({
    String override = 'NR_NSA',
    String callState = 'idle',
    int? voiceNetworkType,
  }) => SimReading(
    slotIndex: 0,
    subscriptionId: 1,
    carrierName: 'AT&T',
    isDefault: true,
    simState: 'READY',
    networkTypeName: 'LTE',
    cells: const [],
    overrideNetworkType: override,
    callState: callState,
    voiceNetworkType: voiceNetworkType,
  );

  group('mode during a call', () {
    test('NSA reads 5G NSA while no call is up', () {
      final idle = sim();
      expect(idle.inCall, isFalse);
      expect(idle.nsaReleasedForCall, isFalse);
      expect(idle.modeLabel, '5G NSA');
    });

    test('a VoLTE call releases the NR leg', () {
      final call = sim(callState: 'offhook', voiceNetworkType: 13);
      expect(call.inCall, isTrue);
      expect(call.voiceLabel, 'VoLTE');
      expect(call.nsaReleasedForCall, isTrue);
      expect(call.modeLabel, '4G LTE');
    });

    test('a ringing call counts as in a call', () {
      expect(
        sim(callState: 'ringing', voiceNetworkType: 13).nsaReleasedForCall,
        isTrue,
      );
    });

    test('a VoNR call keeps its 5G leg', () {
      final call = sim(callState: 'offhook', voiceNetworkType: 20);
      expect(call.voiceLabel, 'VoNR');
      expect(call.nsaReleasedForCall, isFalse);
      expect(call.modeLabel, '5G NSA');
    });

    test('a Wi-Fi call leaves the cellular link alone', () {
      final call = sim(callState: 'offhook', voiceNetworkType: 18);
      expect(call.voiceLabel, 'VoWiFi');
      expect(call.modeLabel, '5G NSA');
    });

    test('an LTE slot whose voice is on LTE does not change its label', () {
      final lte = sim(
        override: 'NONE',
        callState: 'offhook',
        voiceNetworkType: 13,
      );
      expect(lte.nsaReleasedForCall, isFalse);
      expect(lte.modeLabel, 'LTE');
    });
  });

  group('IMS availability', () {
    test('reads the carrier flags and reports whether it answered', () {
      final ims = ImsAvailability.fromMap(<Object?, Object?>{
        'known': true,
        'volte': true,
        'vonr': false,
        'vowifi': true,
      });
      expect(ims.known, isTrue);
      expect(ims.any, isTrue);
      expect(ims.volte, isTrue);
      expect(ims.vonr, isFalse);
      expect(ims.vowifi, isTrue);
    });

    test('a slot with no answer knows nothing', () {
      const ims = ImsAvailability();
      expect(ims.known, isFalse);
      expect(ims.any, isFalse);
    });

    test('parses a payload that carries no IMS block at all', () {
      final reading = SimReading.fromMap(<Object?, Object?>{
        'slotIndex': 1,
        'simState': 'READY',
      });
      expect(reading.ims.known, isFalse);
      expect(reading.callState, 'idle');
      expect(reading.inCall, isFalse);
      expect(reading.voiceNetworkType, isNull);
    });
  });

  testWidgets('the path is drawn as VoLTE, not VOLTE', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SimHeaderCard(
            sim: SimReading(
              slotIndex: 1,
              subscriptionId: 2,
              carrierName: 'AT&T',
              isDefault: true,
              simState: 'READY',
              networkTypeName: 'LTE',
              cells: const [],
              overrideNetworkType: 'NONE',
              callState: 'offhook',
              voiceNetworkType: 13,
              ims: const ImsAvailability(
                known: true,
                volte: true,
                active: 'volte',
              ),
            ),
            dual: false,
            capturedAt: DateTime(2026, 11, 6, 18),
          ),
        ),
      ),
    );

    // Carriers write it in mixed case; the mode chip beside it stays the
    // machine's upper-case word.
    expect(find.text('VoLTE'), findsOneWidget);
    expect(find.text('VOLTE'), findsNothing);
  });

  group('one voice path at a time', () {
    test('the active path is exclusive even when both are offered', () {
      final ims = ImsAvailability.fromMap(<Object?, Object?>{
        'known': true,
        'volte': true,
        'vowifi': true,
        'active': 'vowifi',
      });
      // Both are capabilities; only one is carrying voice.
      expect(ims.volte, isTrue);
      expect(ims.vowifi, isTrue);
      expect(ims.activeLabel, 'VoWiFi');
    });

    test('an LTE voice registration names VoLTE', () {
      final ims = ImsAvailability.fromMap(<Object?, Object?>{
        'known': true,
        'volte': true,
        'active': 'volte',
      });
      expect(ims.activeLabel, 'VoLTE');
    });

    test('a circuit-switched call is named as CS', () {
      final ims = ImsAvailability.fromMap(<Object?, Object?>{
        'known': true,
        'active': 'cs',
      });
      expect(ims.activeLabel, 'CS');
    });

    test('no voice registration means no path to name', () {
      final ims = ImsAvailability.fromMap(<Object?, Object?>{'known': true});
      expect(ims.active, isNull);
      expect(ims.activeLabel, isNull);
    });
  });
}
