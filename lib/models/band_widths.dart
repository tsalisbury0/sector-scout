import 'dart:math' as math;

import '../services/app_settings.dart';
import 'band_tables.dart';

/// The width to draw for a carrier whose modem reports something wider than
/// the channel it is running, and how far the mask sits off the channel centre.
///
/// Band 106 is one case: its 5 MHz block carries a 3 MHz channel at 938.0 MHz
/// and a 1.4 MHz one anywhere else in the band, centred on the reported
/// frequency.
///
/// Band 30 with the setting on is the other: its downlink is RB-limited to
/// 7 MHz of the licensed 10 to keep clear of SiriusXM. The limit trims the
/// bottom of the block, so the mask keeps the block's top edge — 2353–2360 for
/// a 2355 MHz carrier — and the uplink is left at the modem's own width.
({double width, double shift})? drawnDownlinkWidth({
  required int band,
  required double centerMhz,
  required bool is5g,
  required double reportedMhz,
}) {
  if (is5g) return null;
  if (band == 106) {
    return (width: (centerMhz - 938.0).abs() < 0.005 ? 3.0 : 1.4, shift: 0);
  }
  if (band != 30) return null;
  final width = b30RbLimitedMhz(reportedMhz);
  if (width == null) return null;
  final plan = lteBandPlans[30];
  final top = plan == null
      ? centerMhz + reportedMhz / 2
      : math.min(
          centerMhz + reportedMhz / 2,
          plan.dlLow + (plan.last - plan.first + 1) * 0.1,
        );
  return (width: width, shift: top - width / 2 - centerMhz);
}

/// Band 30's drawn downlink width, or null when the modem's own width stands.
///
/// Seven of the licensed ten megahertz: the RB limit that keeps the downlink
/// clear of SiriusXM trims the bottom of the block, so the mask keeps the top
/// edge. A carrier already narrower than the limit is left alone.
double? b30RbLimitedMhz(double reportedMhz) {
  if (!AppSettings.b30RbLimited) return null;
  final width = math.min(7.0, reportedMhz);
  return width >= reportedMhz ? null : width;
}
