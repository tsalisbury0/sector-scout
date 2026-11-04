import 'package:flutter/material.dart' show Color;

import '../models/cell_snapshot.dart';
import '../theme/app_colors.dart';
import '../widgets/tech_badge.dart';
import 'serving_view.dart';

/// The browser page served beside the JSON.
///
/// It is built from the same model as the app's cards — [ServingView] for the
/// rows, the model's own getters for bands, channels, frequencies, eNB/gNB and
/// badge — rather than re-deriving any of it in JavaScript. A field the phone
/// shows therefore appears here too, and the two cannot disagree about what a
/// tower is called or how many bars it has.
class DashboardHtml {
  const DashboardHtml._();

  /// The whole document: the current reading inline, then a poll for updates.
  static String page(CellSnapshot? snapshot) => '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="${_hex(AppColors.background)}">
<title>Sector Scout · remote</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 18px 14px 46px;
    background: ${_hex(AppColors.background)};
    color: ${_hex(AppColors.textPrimary)};
    font: 14px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif;
    -webkit-text-size-adjust: 100%;
  }
  .wrap { max-width: 680px; margin: 0 auto; }
  .appbar { display: flex; align-items: baseline; gap: 10px; margin: 0 0 18px; }
  .appbar h1 {
    font-size: 17px; font-weight: 600; margin: 0; letter-spacing: 0.2px;
  }
  .appbar .live {
    color: ${_hex(AppColors.accent)}; font-size: 10px; font-weight: 700;
    letter-spacing: 1.1px; margin-left: auto;
  }
  .appbar .meta {
    font-size: 11px; color: ${_hex(AppColors.textMuted)}; margin-top: 2px;
  }
  .sim {
    border: 1px solid ${_hex(AppColors.border)};
    border-radius: 24px; padding: 20px; margin-bottom: 18px;
    background: linear-gradient(135deg,
      ${_hex(AppColors.surface)} 0%, ${_hex(AppColors.surfaceAlt)} 100%);
  }
  .hd { display: flex; align-items: flex-start; gap: 12px; }
  .hd-main { flex: 1; min-width: 0; }
  .names { display: flex; align-items: center; flex-wrap: wrap; gap: 7px; }
  .carrier { font-size: 17px; font-weight: 600; }
  .badge { font-size: 11.5px; font-weight: 800; letter-spacing: 0.6px; }
  .badge.fiveg { color: ${_hex(AppColors.accent)}; }
  .badge.radio { color: ${_hex(AppColors.textMuted)}; }
  .badge.sat {
    color: ${_hex(AppColors.satellite)}; font-size: 11px; font-weight: 800;
    letter-spacing: 1px;
  }
  .slot {
    font-size: 9px; font-weight: 600; letter-spacing: 0.3px;
    color: ${_hex(AppColors.textMuted)};
    background: ${_hex(AppColors.surfaceAlt)};
    border: 1px solid ${_hex(AppColors.border)};
    border-radius: 5px; padding: 2px 6px;
  }
  .eyebrow {
    font-size: 10px; letter-spacing: 1.1px;
    color: ${_hex(AppColors.textMuted)}; margin-top: 3px;
  }
  .chip {
    font-size: 11px; font-weight: 600; letter-spacing: 0.4px;
    border-radius: 8px; padding: 5px 10px; white-space: nowrap;
  }
  .chip.on {
    color: ${_hex(AppColors.accent)};
    background: ${_rgba(AppColors.accent, 0.12)};
    border: 1px solid ${_rgba(AppColors.accent, 0.35)};
  }
  .chip.off {
    color: ${_hex(AppColors.textPrimary)};
    background: ${_rgba(AppColors.textMuted, 0.12)};
    border: 1px solid ${_rgba(AppColors.textMuted, 0.35)};
  }
  .meters { display: flex; gap: 16px; align-items: flex-end; margin-top: 22px; }
  .meter { flex: 1; min-width: 0; }
  .leg-label {
    font-size: 9.5px; letter-spacing: 1px; font-weight: 600;
    color: ${_hex(AppColors.textMuted)};
  }
  .leg-body { display: flex; align-items: center; gap: 10px; margin-top: 10px; }
  .leg-body .bars { height: 40px; }
  .leg-body i { width: 8px; }
  .bars { display: flex; align-items: flex-end; gap: 4px; }
  .bars i {
    border-radius: 5px; background: ${_hex(AppColors.track)};
    transition: height 0.25s ease, background 0.25s ease;
  }
  .dbm { font-variant-numeric: tabular-nums; line-height: 1; }
  .dbm .u { font-size: 12px; color: ${_hex(AppColors.textMuted)}; margin-left: 6px; }
  .meter .dbm { font-size: 34px; }
  .leg-body .dbm { font-size: 21px; }
  .leg-body .dbm .u { font-size: 9.5px; margin-left: 0; display: block; }
  .quality { font-size: 12px; margin-top: 6px; }
  .leg-body + .quality { font-size: 11px; }
  .stamp {
    display: flex; justify-content: space-between; gap: 10px;
    border-top: 1px solid ${_hex(AppColors.border)};
    margin-top: 18px; padding-top: 12px;
    font-size: 11px; color: ${_hex(AppColors.textMuted)};
  }
  .h2 {
    font-size: 10px; letter-spacing: 1.1px; font-weight: 600;
    color: ${_hex(AppColors.textMuted)};
    margin: 20px 0 8px; text-transform: uppercase;
  }
  .card {
    border: 1px solid ${_hex(AppColors.border)};
    border-radius: 18px; background: ${_hex(AppColors.surface)};
    overflow: hidden;
  }
  .kv {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; padding: 13px 16px;
  }
  .kv + .kv { border-top: 1px solid ${_hex(AppColors.border)}; }
  .kv .k { font-size: 13px; color: ${_hex(AppColors.textMuted)}; }
  .kv .v {
    font-size: 13px; font-variant-numeric: tabular-nums; text-align: right;
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
  }
  .nb { display: flex; align-items: center; gap: 12px; padding: 12px 16px; }
  .nb + .nb { border-top: 1px solid ${_hex(AppColors.border)}; }
  .tech {
    font-size: 10px; font-weight: 600; letter-spacing: 0.4px;
    color: ${_hex(AppColors.textMuted)};
    background: ${_hex(AppColors.surfaceAlt)};
    border: 1px solid ${_hex(AppColors.border)};
    border-radius: 6px; padding: 3px 7px; flex: none;
  }
  .nb-main { flex: 1; min-width: 0; }
  .nb-title {
    font-size: 13px; font-variant-numeric: tabular-nums;
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
  }
  .nb-sub { font-size: 11px; color: ${_hex(AppColors.textMuted)}; margin-top: 2px; }
  .nb-freq {
    font-size: 10.5px; color: #64748b; margin-top: 2px;
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
  }
  .nb-dbm {
    font-size: 12px; font-variant-numeric: tabular-nums; white-space: nowrap;
    font-family: ui-monospace, "Cascadia Mono", Consolas, monospace;
  }
  .nb .bars { height: 22px; }
  .nb .bars i { width: 4px; }
  .note { margin-top: 8px; font-size: 10.5px; color: #64748b; }
  .note summary {
    cursor: pointer; list-style: none; width: 18px; height: 18px;
    line-height: 16px; text-align: center; border-radius: 9px;
    border: 1px solid #475569; font-size: 12px; color: #94a3b8;
  }
  .note summary::-webkit-details-marker { display: none; }
  .note .notetext { font-size: 10.5px; line-height: 1.5; margin-top: 6px; }
  .notice {
    display: flex; gap: 10px; align-items: flex-start;
    margin: 12px 0; padding: 14px;
    border-radius: 14px;
    background: ${_rgba(AppColors.warning, 0.08)};
    border: 1px solid ${_rgba(AppColors.warning, 0.3)};
  }
  .notice .ico { color: ${_hex(AppColors.warning)}; font-size: 14px; line-height: 1.3; }
  .notice .msg {
    font-size: 12.5px; line-height: 1.45;
    color: ${_hex(AppColors.textMuted)};
  }
  .hint {
    color: ${_hex(AppColors.textMuted)}; font-size: 13px;
    border: 1px dashed ${_hex(AppColors.border)};
    border-radius: 18px; padding: 18px;
  }
  .tick { text-align: center; font-size: 11px; color: #64748b; margin-top: 18px; }
  .tick.err { color: ${_hex(AppColors.danger)}; }
</style>
</head>
<body>
<div class="wrap">
  <div id="live">${body(snapshot)}</div>
  <div class="tick" id="foot">Live over your local network — nothing leaves the LAN.</div>
</div>
<script>
  var last = '';
  function poll() {
    fetch('/view', {cache: 'no-store'}).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then(function (html) {
      if (html !== last) {
        document.getElementById('live').innerHTML = html;
        last = html;
      }
      var foot = document.getElementById('foot');
      foot.className = 'tick';
      foot.textContent = 'Live over your local network — nothing leaves the LAN.';
    }).catch(function (e) {
      var foot = document.getElementById('foot');
      foot.className = 'tick err';
      foot.textContent = 'Waiting for the phone… (' + e.message + ')';
    });
  }
  setInterval(poll, 2000);
</script>
</body>
</html>
''';

  /// Everything inside the page's live region: one block per SIM slot.
  static String body(CellSnapshot? snapshot) {
    if (snapshot == null) {
      return '<div class="hint">Waiting for the phone\u2019s first reading…</div>';
    }
    final sims = snapshot.activeSims.isEmpty
        ? snapshot.sims
        : snapshot.activeSims;
    if (sims.isEmpty) {
      return '<div class="hint">This phone is not reporting a SIM slot.</div>';
    }
    final dual = sims.length > 1;
    // The app bar, drawn from the same payload: the device and how many SIMs
    // are in it, exactly as the app names them at the top of the screen.
    final device = snapshot.deviceModel.isEmpty
        ? 'Android'
        : snapshot.deviceModel;
    final out = StringBuffer()
      ..write('<div class="appbar"><div><h1>Sector Scout</h1>')
      ..write('<div class="meta">${_esc(device)} · ${sims.length} SIM')
      ..write('${sims.length == 1 ? '' : 's'}</div></div>')
      ..write('<span class="live">LIVE</span></div>');
    if (!snapshot.locationEnabled) {
      out.write(
        '<div class="notice"><span class="ico">\u26a0</span><span class="msg">'
        'Location services are off. Android hides cell identities from apps '
        'while location is disabled — turn it on to see tower details.'
        '</span></div>',
      );
    }
    for (var i = 0; i < sims.length; i++) {
      final sim = sims[i];
      out
        ..write(_header(sim, dual: dual))
        ..write(_sections(sim, snapshot, prefix: dual ? '${sim.label} · ' : ''))
        ..write('<div class="stamp">')
        ..write('<span>Updated ${_clock(snapshot.capturedAt)}</span>')
        ..write(
          '<span>${sim.cells.length} '
          'cell${sim.cells.length == 1 ? '' : 's'} visible</span></div>')
        ..write('</section>');
    }
    return out.toString();
  }

  // -- header ------------------------------------------------------------

  static String _header(SimReading sim, {required bool dual}) {
    final lte = sim.lteServing;
    final nr = sim.nrServing;
    final serving = sim.serving;
    final badge = badgeForSim(sim);

    final out = StringBuffer()
      ..write('<section class="sim"><div class="hd"><div class="hd-main">')
      ..write('<div class="names"><span class="carrier">')
      ..write(_esc(ServingView.carrierName(sim)))
      ..write('</span>');
    // The technology reads as part of the name, then the slot — the same order
    // the app draws. A satellite link shows SAT in this spot instead, never
    // beside it.
    if (sim.isSatellite) {
      out.write('<span class="badge sat">SAT</span>');
    } else if (badge != null) {
      final fiveG = badge.startsWith('5G') && badge != '5GE';
      out
        ..write('<span class="badge ${fiveG ? 'fiveg' : 'radio'}">')
        ..write(_esc(badge))
        ..write('</span>');
    }
    if (dual) {
      out.write('<span class="slot">${_esc(sim.label)}</span>');
    }
    out
      ..write('</div><div class="eyebrow">SERVING CELL</div></div>')
      ..write(
        '<span class="chip ${sim.isNsa && nr != null ? 'on' : 'off'}">'
        '${_esc(sim.modeLabel)}</span>',
      )
      ..write('</div><div class="meters">');

    if (sim.isNsa && lte != null && nr != null) {
      out
        ..write(_leg('LTE anchor', lte))
        ..write(
          '<div style="width:1px;background:${_hex(AppColors.border)};'
          'height:62px;align-self:center"></div>',
        )
        ..write(_leg('5G NR', nr));
    } else {
      final bars = serving?.bars ?? 0;
      out
        ..write('<div class="meter" style="flex:1">${_bars(bars, height: 62, width: 11, gap: 6)}</div>')
        ..write(
          '<div class="meter" style="flex:2">'
          '<div class="dbm" style="color:${_barsColor(bars)}">'
          '${serving?.dbm?.toString() ?? '—'}<span class="u">dBm</span></div>'
          '<div class="quality" style="color:${_barsColor(bars)}">'
          '${_esc(SignalQuality.label(bars))}</div></div>',
        );
    }
    out.write('</div>');
    return out.toString();
  }

  static String _leg(String label, CellTower cell) {
    final color = _barsColor(cell.bars);
    return '<div class="meter">'
        '<div class="leg-label">${_esc(label.toUpperCase())}</div>'
        '<div class="leg-body">${_bars(cell.bars, height: 40, width: 8, gap: 4)}'
        '<div class="dbm" style="color:$color">${cell.dbm ?? '—'}'
        '<span class="u">dBm</span></div></div>'
        '<div class="quality" style="color:$color">'
        '${_esc(SignalQuality.label(cell.bars))}</div>'
        '</div>';
  }

  // -- sections ----------------------------------------------------------

  static String _sections(
    SimReading sim,
    CellSnapshot snapshot, {
    required String prefix,
  }) {
    final problem = sim.problem(locationEnabled: snapshot.locationEnabled);
    final lte = sim.lteServing;
    final nr = sim.nrServing;
    final out = StringBuffer();

    if ((!sim.hasSim || sim.cells.isEmpty) && problem != null) {
      out.write(_notice(problem));
    }

    if (sim.serving == null) {
      if (sim.cells.isNotEmpty) {
        out.write(
          _notice(
            'No cell on this SIM is registered right now, so there is no '
            'serving cell to show. Its neighbours are still listed below.',
          ),
        );
      }
    } else {
      final paired = sim.isNsa && lte != null && nr != null;
      out
        ..write(
          '<div class="h2">${_esc(prefix)}'
          '${paired ? '4G anchor' : sim.isSa ? '5G NR' : 'Serving cell'}</div>',
        )
        // The anchor card must show the LTE cell itself, or an NSA pair renders
        // the 5G card twice and the eNB, sector and anchor band disappear.
        ..write(
          _detail(
            ServingView.entries(
              paired ? lte : sim.serving!,
              carriers: sim.carriers,
            ),
          ),
        );

      if (sim.isNsa && nr == null) {
        out.write(
          _foot(
            'The platform reports the NR leg connected (NR state: '
            '${sim.nrState.isEmpty ? 'not reported' : sim.nrState}) while '
            'the radio is not exposing an NR cell right now — many radios '
            'only hand the NR leg to apps while it is carrying data. The 5G '
            'badge follows the platform’s report, not a cell: the meter above '
            'is the LTE anchor.',
          ),
        );
      }

      if (paired) {
        out
          ..write('<div class="h2">${_esc(prefix)}5G NR secondary</div>')
          ..write(
            _detail(
              ServingView.entries(
                nr,
                gnbEstimate: sim.nsaGnbEstimate,
                carriers: sim.carriers,
              ),
            ),
          );
        if (nr.gnb == null) {
          out.write(
            _foot(
              sim.nsaGnbEstimate != null
                  ? 'This radio hides the NR cell identity while NSA is up, so '
                        'the gNB marked “est.” is derived from the LTE anchor. '
                        'There is no sector to report without the NCI; PCI, '
                        'band and ARFCN are reported directly.'
                  : 'This radio hides the NR cell identity while NSA is up, so '
                        'gNB and sector are unavailable — PCI, band and ARFCN '
                        'still identify the carrier.',
            ),
          );
        }
      }

      // LTE secondary carriers: band 29's supplemental downlink, and any extra
      // layer of carrier aggregation the radio reports alongside the primary.
      if (sim.lteSecondaries.isNotEmpty) {
        out.write('<div class="h2">${_esc(prefix)}4G LTE secondary</div>');
        for (final secondary in sim.lteSecondaries) {
          out.write(
            _detail(
              ServingView.entries(
                secondary,
                fallbackPlmn: sim.registeredPlmn,
                carriers: sim.carriers,
              ),
            ),
          );
        }
        out.write(
          _foot(
            'Secondaries are aggregated under the primary LTE cell. Band 29 is '
            'a downlink-only supplemental carrier: the radio reports it with a '
            'PCI, band and channel but no cell identity, so there is no eNB, '
            'sector or TAC to show — and no uplink frequency, because the band '
            'has none. Its MCC/MNC only come through while it is carrying '
            'data, which is why the PLMN falls back to the network the primary '
            'cell is registered on.',
          ),
        );
      }

      if (sim.carriers.isNotEmpty) {
        out
          ..write('<div class="h2">${_esc(prefix)}Carrier aggregation</div>')
          ..write(_detail(ServingView.carrierEntries(sim)));
      }

      out
        ..write('<div class="h2">${_esc(prefix)}Radio quality</div>')
        ..write(_detail(ServingView.qualityEntries(sim)));
    }

    if (sim.cells.isNotEmpty) {
      final neighbours = sim.neighbours;
      out.write(
        '<div class="h2">${_esc(prefix)}Neighbour cells'
        '${neighbours.isEmpty ? '' : ' (${neighbours.length})'}</div>',
      );
      if (neighbours.isEmpty) {
        out.write(
          '<div class="card"><div class="kv"><span class="k">'
          'The modem is not reporting any neighbour cells right now.'
          '</span></div></div>',
        );
      } else {
        out.write('<div class="card">');
        for (final cell in neighbours) {
          out.write(_neighbour(cell));
        }
        out.write('</div>');
        if (neighbours.any((cell) => cell.cellId == null)) {
          out.write(
            _foot(
              'Android 12+ hides neighbour cell IDs from apps, so those rows '
              'are identified by PCI and band instead.',
            ),
          );
        }
      }
    }
    return out.toString();
  }

  // -- pieces ------------------------------------------------------------

  static String _detail(List<MapEntry<String, String>> entries) {
    final out = StringBuffer('<div class="card">');
    for (final entry in entries) {
      out
        ..write('<div class="kv"><span class="k">${_esc(entry.key)}</span>')
        ..write('<span class="v">${_esc(entry.value)}</span></div>');
    }
    out.write('</div>');
    return out.toString();
  }

  static String _neighbour(CellTower cell) {
    final neighbourId = switch (cell.tech) {
      CellTech.lte => cell.enb,
      CellTech.nr => cell.gnb,
      _ => null,
    };
    final title = neighbourId != null
        ? '${cell.tech == CellTech.nr ? 'gNB' : 'eNB'} $neighbourId'
        : cell.cellId != null
        ? 'Cell ${cell.cellId}'
        : (cell.pci != null ? '${cell.pciLabel} ${cell.pci}' : 'Unknown cell');
    final details = [
      if (cell.cellId != null && cell.pci != null) '${cell.pciLabel} ${cell.pci}',
      if (cell.bandLabel != null) cell.bandLabel!,
      if (cell.tac != null) '${cell.tacLabel} ${cell.tac}',
      if (cell.plmn != null) cell.plmn!,
    ].join(' · ');
    final frequency = ServingView.neighbourFrequency(cell);

    final out = StringBuffer('<div class="nb">')
      ..write(
        '<span class="tech">${_esc(cell.tech.raw.isEmpty ? '?' : cell.tech.raw)}</span>',
      )
      ..write('<div class="nb-main"><div class="nb-title">${_esc(title)}</div>');
    if (details.isNotEmpty) {
      out.write('<div class="nb-sub">${_esc(details)}</div>');
    }
    if (frequency != null) {
      out.write('<div class="nb-freq">${_esc(frequency)}</div>');
    }
    out
      ..write('</div>')
      ..write(
        '<span class="nb-dbm" style="color:${_barsColor(cell.bars)}">'
        '${cell.dbm == null ? '—' : '${cell.dbm} dBm'}</span>',
      )
      ..write(_bars(cell.bars, height: 22, width: 4, gap: 3))
      ..write('</div>');
    return out.toString();
  }

  /// The app's five-bar meter, at whatever size the caller asks for.
  static String _bars(
    int bars, {
    required double height,
    required double width,
    required double gap,
  }) {
    const fractions = [0.3, 0.46, 0.62, 0.8, 1.0];
    final filled = bars.clamp(0, fractions.length);
    final color = _barsColor(bars);
    final out = StringBuffer(
      '<span class="bars" style="gap:${gap}px;height:${height}px" '
      'role="img" aria-label="Signal strength: $filled of 5 bars">',
    );
    for (var i = 0; i < fractions.length; i++) {
      final on = i < filled;
      out
        ..write(
          '<i style="width:${width}px;height:${(height * fractions[i]).toStringAsFixed(1)}px;',
        )
        ..write('background:${on ? color : _hex(AppColors.track)}"></i>');
    }
    out.write('</span>');
    return out.toString();
  }

  static String _notice(String message) =>
      '<div class="notice"><span class="ico">\u26a0</span>'
      '<span class="msg">${_esc(message)}</span></div>';

  /// A note that stays folded behind its circled question mark.
  static String _foot(String text) =>
      '<details class="note"><summary>?</summary>'
      '<div class="notetext">${_esc(text)}</div></details>';

  // -- formatting --------------------------------------------------------

  static String _barsColor(int bars) => _hex(AppColors.forBars(bars));

  static String _hex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0')}';
  }

  static String _rgba(Color color, double alpha) {
    final argb = color.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return 'rgba($r,$g,$b,$alpha)';
  }

  static String _clock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String _esc(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
