import 'package:cell_tower_monitor/models/cell_snapshot.dart';
import 'package:cell_tower_monitor/services/app_settings.dart';
import 'package:cell_tower_monitor/services/serving_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('band 30 shows both widths when the downlink is RB-limited', () {
    const carrier = RadioCarrier(
      tech: CellTech.lte,
      band: 30,
      bandwidthKhz: 10000,
    );
    const row = CarrierRow(carrier: carrier, tech: 'LTE');
    expect(row.width, '10 MHz');

    AppSettings.b30RbLimited = true;
    addTearDown(() => AppSettings.b30RbLimited = false);
    expect(row.width, '7\u2193/10\u2191 MHz');
  });
}
