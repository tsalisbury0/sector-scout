import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../desktop/desktop_config.dart';
import '../desktop/scenario.dart';
import '../desktop/test_source.dart';
import '../models/band_filters.dart';
import '../models/cell_snapshot.dart';
import '../services/ble_desktop.dart';
import '../services/lan_discovery.dart';
import '../services/remote_client.dart';
import '../services/serving_view.dart';
import '../services/update_checker.dart';
import '../theme/app_colors.dart';
import '../widgets/signal_bars.dart';
import '../widgets/tech_badge.dart';

import 'custom_source_screen.dart';

/// The desktop console: every watched phone gets its own card, under the same
/// Phones / Test source tabs the Python console used, and the cards sit side by
/// side instead of stacking. It draws the same [ServingView] rows and the same
/// widgets as the phone, so the two cannot drift apart.
class DesktopHome extends StatefulWidget {
  const DesktopHome({super.key, this.config, this.scan});

  /// Tests pass their own, so they never read the real profile.
  final DesktopConfig? config;

  /// Tests replace the LAN sweep, which otherwise probes every host on the
  /// subnet and would leave a widget test waiting on the network.
  final Future<List<LanPeer>> Function()? scan;

  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<DesktopHome> {
  final List<_Peer> _peers = <_Peer>[];
  final TextEditingController _address = TextEditingController();
  late final DesktopConfig _config;
  final DesktopTestSource _source = DesktopTestSource();
  late String _scenarioId;
  late CustomSource _custom;
  late bool _corrections;
  Timer? _timer;
  bool _scanning = false;

  /// Kept apart from [_scanning] so a Bluetooth scan leaves the Wi-Fi
  /// button alone, and neither can block the other.
  bool _bluetoothScanning = false;

  /// True while a sweep is running, so the poll timer cannot start a second
  /// one on top of the first.
  bool _polling = false;

  /// 0 is Phones, 1 is Test source.
  int _tab = 0;

  DateTime _refreshedAt = DateTime.now();

  /// What the footer was last told — a sweep's result, mostly.
  String? _status;

  /// Why the address box refused the last add.
  String? _addError;

  @override
  void initState() {
    super.initState();
    _config = widget.config ?? DesktopConfig.load();
    _corrections = _config.corrections;
    _applyCorrections();

    // The phones and the scenario are what the console remembered, so the
    // window comes back the way it was left. A config written by the Python
    // console names its own scenarios and stores each phone as an object, and
    // both are read back into this build's shape.
    _custom = _config.custom;
    _scenarioId = _resolveScenarioId(_config.scenarioId);
    _source.scenario = _scenarioFor(_scenarioId);
    for (final address in _config.phones) {
      _peers.add(_Peer(address));
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollAll());
    if (_peers.isNotEmpty) unawaited(_pollAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _address.dispose();
    unawaited(_source.stop());
    for (final peer in _peers) {
      peer.dispose();
    }
    super.dispose();
  }

  void _applyCorrections() {
    BandFilters.tmobileBands = _corrections;
    BandFilters.cbrs = _corrections;
  }

  /// One sweep at a time: a Bluetooth read takes seconds, and two of them
  /// reset each other's cursor on the phone mid-payload.
  Future<void> _pollAll() async {
    if (_polling) return;
    _polling = true;
    try {
      await _pollPeers();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollPeers() async {
    // Together, not one after another: a Bluetooth pass takes seconds, and a
    // phone answering on Wi-Fi should not wait behind it. The Bluetooth reads
    // still queue inside BleDesktop, so they go one at a time regardless.
    await Future.wait(_peers.map(_pollPeer));
    if (mounted) setState(() => _refreshedAt = DateTime.now());
  }

  Future<void> _pollPeer(_Peer peer) async {
    try {
      final snapshot = await peer.fetch();
      if (!mounted) return;
      setState(() {
        peer.snapshot = snapshot;
        peer.error = null;
        peer.lastOk = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => peer.error = '$error');
    }
  }

  /// The address box is the console's "ip or ip:port" entry: a bare address is
  /// given the share port, and the same address is not watched twice.
  Future<void> _addFromField() async {
    final text = _address.text.trim();
    if (text.isEmpty) {
      setState(() => _addError = 'Enter a phone address first.');
      return;
    }
    if (_peers.any((peer) => peer.address == text)) {
      setState(() => _addError = 'That address is already being watched.');
      return;
    }
    setState(() {
      _peers.add(_Peer(text));
      _address.clear();
      _addError = null;
      _status = null;
    });
    unawaited(_saveConfig());
    await _pollAll();
  }

  void _removePeer(_Peer peer) {
    peer.dispose();
    setState(() {
      _peers.remove(peer);
      _status = null;
    });
    unawaited(_saveConfig());
  }

  /// Remembers the watched phones, the served scenario and the band switches.
  Future<void> _saveConfig() async {
    _config.phones
      ..clear()
      ..addAll(_peers.map((peer) => peer.saved));
    _config.scenarioId = _scenarioId;
    _config.corrections = _corrections;
    _config.custom = _custom;
    await _config.save();
  }

  Scenario _scenarioFor(String id) => id == 'custom'
      ? _custom.build()
      : Scenario.byId(id) ?? Scenario.presets.first;

  /// The console saved its own scenario names, so a name this build does not
  /// know is matched to the preset it describes before falling back.
  static String _resolveScenarioId(String saved) {
    if (Scenario.byId(saved) != null) return saved;
    final text = saved.toLowerCase();
    if (text.contains('custom')) return 'custom';
    if (text.contains('dual')) return 'dual-sim';
    if (text.contains('b106') || text.contains('anterix')) return 'anterix-b106';
    if (text.contains('n71')) return 'tmo-n71';
    if (text.contains('n41') || text.contains('t-mobile')) return 'tmo-n41';
    if (text.contains('nsa') || text.contains('at&t')) return 'att-nsa';
    return Scenario.presets.first.id;
  }

  /// Picking the custom entry edits it first, so the list and the fields are
  /// the same gesture and cancelling leaves what is serving untouched.
  Future<void> _selectScenario(String id) async {
    if (id == 'custom') {
      final edited = await _editCustom();
      if (edited == null || !mounted) return;
      setState(() {
        _custom = edited;
        _scenarioId = 'custom';
        _source.scenario = _custom.build();
      });
      unawaited(_saveConfig());
      return;
    }
    final scenario = Scenario.byId(id);
    if (scenario == null) return;
    setState(() {
      _scenarioId = id;
      _source.scenario = scenario;
    });
    unawaited(_saveConfig());
  }

  /// The editor page, or null when it is dismissed without serving.
  Future<CustomSource?> _editCustom() =>
      Navigator.of(context).push<CustomSource>(
        MaterialPageRoute(
          builder: (context) => CustomSourceScreen(
            initial: _custom,
            onChanged: _draftCustom,
          ),
        ),
      );

  /// Every edit the page makes is held here at once, so the phone watching
  /// the test source sees the change on its next poll instead of waiting for
  /// the page to be dismissed.
  void _draftCustom(CustomSource draft) {
    if (!mounted) return;
    setState(() {
      _custom = draft;
      if (_scenarioId == 'custom') _source.scenario = draft.build();
    });
  }

  /// Re-opens the editor for the source that is already selected.
  Future<void> _editSelectedCustom() async {
    final edited = await _editCustom();
    if (edited == null || !mounted) return;
    setState(() {
      _custom = edited;
      if (_scenarioId == 'custom') _source.scenario = _custom.build();
    });
    unawaited(_saveConfig());
  }

  /// Sweeps the subnet for phones answering this app's `/health` — the
  /// console's "Scan" button, over the code the phone app uses.
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _status = 'Scanning the network on port ${DesktopTestSource.defaultPort}…';
    });
    try {
      // A PC with no LAN address has nothing to sweep, and saying so is the
      // difference between a silent sweep and a broken one.
      final sweep = widget.scan;
      if (sweep == null && (await LanDiscovery.subnets()).isEmpty) {
        if (!mounted) return;
        setState(
          () => _status =
              'This PC has no Wi-Fi or Ethernet address, so there is nothing '
              'to scan.',
        );
        return;
      }
      final found = await (sweep ?? () => LanDiscovery.scan())();
      if (!mounted) return;
      final known = _peers.map((peer) => peer.address).toSet();
      final fresh = <String>[];
      for (final peer in found) {
        if (known.add(peer.label)) fresh.add(peer.label);
      }
      setState(() {
        for (final address in fresh) {
          _peers.add(_Peer(address));
        }
        // A silent sweep and a broken one look identical otherwise.
        _status = found.isEmpty
            ? 'No phone answered on port ${DesktopTestSource.defaultPort}.'
            : 'Found ${found.length} on port ${DesktopTestSource.defaultPort}; '
                'added ${fresh.length}.';
      });
      if (fresh.isNotEmpty) {
        unawaited(_saveConfig());
        await _pollAll();
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Scan failed: $error');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// The console's "Scan Bluetooth": phones advertising the GATT share, with
  /// no network between the two machines at all.
  Future<void> _scanBluetooth() async {
    if (_bluetoothScanning) return;
    setState(() {
      _bluetoothScanning = true;
      _status = 'Scanning Bluetooth\u2026';
    });
    try {
      final found = await BleDesktop.scan();
      if (!mounted) return;
      if (found.isEmpty) {
        setState(
          () => _status = 'No phone advertised the Bluetooth share. Turn '
              'Bluetooth sharing on in the app and scan again.',
        );
        return;
      }
      final chosen = await showDialog<BleDesktopPeer>(
        context: context,
        builder: (context) => _BlePicker(peers: found),
      );
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _status = 'Found ${found.length} over Bluetooth.');
        return;
      }
      final saved = 'ble:${chosen.address}';
      if (_peers.any((peer) => peer.saved == saved)) {
        setState(() => _status = '${chosen.label} is already being watched.');
        return;
      }
      setState(() {
        _peers.add(_Peer(saved));
        _status = 'Watching ${chosen.label} over Bluetooth.';
      });
      unawaited(_saveConfig());
      await _pollAll();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Bluetooth scan failed: $error');
    } finally {
      if (mounted) setState(() => _bluetoothScanning = false);
    }
  }

  /// Starts the source and repaints once it has, so the bar shows the address
  /// it bound.
  Future<void> _startSource() async {
    await _source.start();
    if (mounted) setState(() {});
  }

  Future<void> _toggleSource() async {
    if (_source.running) {
      await _source.stop();
    } else {
      await _source.start();
    }
    if (mounted) setState(() {});
  }

  String get _sourceLabel {
    if (!_source.running) return 'test source stopped';
    final uri = _source.lanUri ?? _source.uri;
    return uri == null
        ? 'test source serving'
        : 'test source serving on $uri';
  }

  @override
  Widget build(BuildContext context) {
    final answering = _peers.where((p) => p.snapshot != null).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _Header(status: _sourceLabel),
          _Tabs(
            index: _tab,
            onChanged: (value) {
              setState(() => _tab = value);
              // Nothing is served until the source is actually opened: a
              // window that held port 41729 from launch was serving a test
              // reading nobody had asked for.
              if (value == 1 && !_source.running) unawaited(_startSource());
            },
          ),
          _UpdateBanner(),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [_phonesPane(), _sourcePane()],
            ),
          ),
          _Footer(
            counters: '$answering/${_peers.length} phones answering · '
                'refreshed ${_clock(_refreshedAt)}',
            status: _status,
            corrections: _corrections,
            onCorrections: (value) {
              setState(() {
                _corrections = value;
                _applyCorrections();
              });
              unawaited(_saveConfig());
            },
            betas: UpdateChecker.betas,
            onBetas: (value) => unawaited(UpdateChecker.setBetas(value)),
            onCheck: () => unawaited(UpdateChecker.refresh()),
          ),
        ],
      ),
    );
  }

  Widget _phonesPane() {
    return Column(
      children: [
        _AddBar(
          controller: _address,
          error: _addError,
          scanning: _scanning,
          bluetoothScanning: _bluetoothScanning,
          onAdd: _addFromField,
          onScan: _scan,
          onScanBluetooth: _scanBluetooth,
        ),
        Expanded(
          child: _peers.isEmpty
              ? const _EmptyState()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final peer in _peers)
                            SizedBox(
                              width: _cardWidth(constraints.maxWidth),
                              child: _PhoneCard(
                                peer: peer,
                                onRemove: () => _removePeer(peer),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sourcePane() {
    return Column(
      children: [
        _SourceBar(
          scenarioId: _scenarioId,
          customSummary: _custom.summary,
          running: _source.running,
          uri: _source.uri,
          lanUri: _source.lanUri,
          failure: _source.failure,
          onScenario: _selectScenario,
          onEditCustom: _editSelectedCustom,
          onToggle: _toggleSource,
        ),
        const Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Serve a reading',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'A phone watches this PC by typing the address above into '
                  'Watch a phone. The port is fixed at 41729 — the same one the '
                  'phone app shares on — so either end can find the other by a '
                  'scan instead of being told an address.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppColors.textMuted,
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  'Custom source',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Every field of the reading by hand: the network, the LTE '
                  'anchor, carriers aggregated under it, up to five NR legs and '
                  'the neighbours a modem hears. The page reads back what it '
                  'will actually serve.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Two cards at 1280 px, three at 1800, one when there is no room.
  static double _cardWidth(double available) {
    const minimum = 560.0;
    final columns = (available / minimum).floor().clamp(1, 4);
    final width = (available - 24 - (columns - 1) * 12) / columns;
    return width < minimum ? available - 24 : width;
  }

  static String _clock(DateTime when) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            'Sector Scout',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Desktop console',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              status,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const List<String> _labels = ['Phones', 'Test source'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Row(
        children: [
          for (var tab = 0; tab < _labels.length; tab++)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Material(
                color: tab == index ? AppColors.surface : AppColors.surfaceAlt,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
                child: InkWell(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  onTap: () => onChanged(tab),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      _labels[tab],
                      style: TextStyle(
                        fontSize: 12,
                        color: tab == index
                            ? AppColors.textPrimary
                            : AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The console's add row: type an address, add it, or sweep for phones.
class _AddBar extends StatelessWidget {
  const _AddBar({
    required this.controller,
    required this.onAdd,
    required this.onScan,
    required this.onScanBluetooth,
    required this.scanning,
    required this.bluetoothScanning,
    this.error,
  });

  final TextEditingController controller;
  final VoidCallback onAdd;
  final VoidCallback onScan;
  final VoidCallback onScanBluetooth;
  final bool scanning;

  /// Its own state, so the Wi-Fi button does not say "Scanning…" while
  /// Bluetooth is the thing being scanned.
  final bool bluetoothScanning;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('phone-address'),
                  controller: controller,
                  onSubmitted: (_) => onAdd(),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'ip or ip:port',
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 11,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.background,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Add phone'),
              ),
              const SizedBox(width: 8),
              // Shown in both builds so a non-Windows platform sees the
              // reason rather than a missing button.
              Tooltip(
                message: Platform.isWindows
                    ? 'Find phones advertising the Bluetooth share'
                    : 'Bluetooth watching is available in the Windows app',
                child: OutlinedButton.icon(
                  onPressed: Platform.isWindows && !bluetoothScanning
                      ? onScanBluetooth
                      : null,
                  icon: const Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 16,
                  ),
                  label: Text(
                    bluetoothScanning ? 'Scanning…' : 'Scan Bluetooth',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    side: const BorderSide(color: AppColors.border),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: scanning ? null : onScan,
                icon: const Icon(Icons.wifi_find_rounded, size: 16),
                label: Text(scanning ? 'Scanning…' : 'Scan'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textMuted,
                  side: const BorderSide(color: AppColors.border),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                error!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.warning,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The test source: pick a scenario, serve it on the phones' own port.
class _SourceBar extends StatelessWidget {
  const _SourceBar({
    required this.scenarioId,
    required this.customSummary,
    required this.running,
    required this.uri,
    required this.lanUri,
    required this.failure,
    required this.onScenario,
    required this.onEditCustom,
    required this.onToggle,
  });

  final String scenarioId;
  final String customSummary;
  final bool running;
  final Uri? uri;

  /// The address a phone on the same network can actually reach.
  final Uri? lanUri;
  final String? failure;
  final ValueChanged<String> onScenario;
  final VoidCallback onEditCustom;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: const BoxDecoration(
        color: AppColors.surfaceAlt,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            'Test source',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(width: 12),
          // Flexible and ellipsised: the custom entry is long, and the bar has
          // to keep fitting in a narrow window instead of overflowing.
          Flexible(
            child: DropdownButton<String>(
              value: scenarioId,
              isExpanded: true,
              dropdownColor: AppColors.surface,
              underline: const SizedBox.shrink(),
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textPrimary,
              ),
              items: [
                for (final scenario in Scenario.presets)
                  DropdownMenuItem(
                    value: scenario.id,
                    child: Text(scenario.name, overflow: TextOverflow.ellipsis),
                  ),
                // The editor's own source, named by what it actually serves, so
                // the bar cannot promise a carrier that was switched off.
                DropdownMenuItem(
                  value: 'custom',
                  child: Text(
                    'Custom · $customSummary',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) onScenario(value);
              },
            ),
          ),
          // The custom source has its own page, reachable whether or not it
          // is the scenario being served.
          Tooltip(
            message: 'Edit the custom source',
            child: TextButton.icon(
              onPressed: onEditCustom,
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('Custom source'),
              style: TextButton.styleFrom(
                foregroundColor: scenarioId == 'custom'
                    ? AppColors.accent
                    : AppColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onToggle,
            style: FilledButton.styleFrom(
              backgroundColor: running ? AppColors.surface : AppColors.accent,
              foregroundColor:
                  running ? AppColors.textPrimary : AppColors.background,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(running ? 'Stop' : 'Serve'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              running
                  ? lanUri == null
                      ? '${uri ?? ""}  ·  no LAN address, so only this PC can '
                          'reach it'
                      : '$lanUri  ·  a phone can Watch this address'
                  : failure == null
                      ? 'not serving'
                      : 'port ${DesktopTestSource.defaultPort} is taken: $failure',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: running ? AppColors.accent : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.counters,
    required this.corrections,
    required this.onCorrections,
    required this.betas,
    required this.onBetas,
    required this.onCheck,
    this.status,
  });

  final String counters;
  final bool corrections;
  final ValueChanged<bool> onCorrections;
  final String? status;

  /// Whether prerelease updates should be offered, shown as a checkbox here
  /// and in the phone's Settings page.
  final ValueListenable<bool> betas;
  final ValueChanged<bool> onBetas;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final checking = ListenableBuilder(
      listenable: UpdateChecker.update,
      builder: (context, _) {
        final phase = UpdateChecker.update.value;
        return phase is UpdateChecking
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const SizedBox(width: 12, height: 12);
      },
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status == null ? counters : '$counters  ·  $status',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: corrections,
                onChanged: (value) => onCorrections(value ?? true),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: AppColors.textMuted),
              ),
              const Text(
                'Display corrections',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'Check for updates',
                child: IconButton(
                  onPressed: onCheck,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  color: AppColors.textMuted,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              checking,
              const SizedBox(width: 4),
              const Text(
                kBuildTag,
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
              ListenableBuilder(
                listenable: betas,
                builder: (context, _) => Checkbox(
                  value: betas.value,
                  onChanged: (value) => onBetas(value ?? false),
                  visualDensity: VisualDensity.compact,
                  side: const BorderSide(color: AppColors.textMuted),
                ),
              ),
              const Text(
                'Betas',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.cell_tower_rounded, size: 40, color: AppColors.textMuted),
            SizedBox(height: 12),
            Text(
              'No phones yet',
              style: TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Type the address a phone shows above and press Add phone, or '
              'Scan to find phones sharing on this Wi-Fi.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One phone, drawn the way the app draws a SIM: header, meter, rows.
class _PhoneCard extends StatelessWidget {
  const _PhoneCard({required this.peer, required this.onRemove});

  final _Peer peer;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final snapshot = peer.snapshot;
    final name = snapshot != null && snapshot.deviceModel.isNotEmpty
        ? snapshot.deviceModel
        : peer.error != null
            ? 'not answering'
            : 'asking…';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      peer.address,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onRemove,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textMuted,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Remove'),
              ),
            ],
          ),
          if (peer.error != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: const BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border(
                  left: BorderSide(color: AppColors.warning, width: 2),
                ),
              ),
              child: Text(
                peer.error!,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: AppColors.warning,
                ),
              ),
            ),
          if (snapshot != null)
            for (final sim in snapshot.sims)
              _SimBlock(
                sim: sim,
                updated: peer.lastOk,
                showSlot: snapshot.sims.length > 1,
              ),
        ],
      ),
    );
  }
}

class _SimBlock extends StatelessWidget {
  const _SimBlock({
    required this.sim,
    required this.showSlot,
    this.updated,
  });

  final SimReading sim;
  final bool showSlot;
  final DateTime? updated;

  @override
  Widget build(BuildContext context) {
    final lte = sim.lteServing;
    final nr = sim.nrServing;
    final paired = sim.isNsa && lte != null && nr != null;
    final serving = nr ?? lte;
    final badge = badgeForSim(sim);
    final cells = sim.cells;
    final neighbours = sim.neighbours;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              ServingView.carrierName(sim),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 7),
              TechBadge(label: badge),
            ],
            if (showSlot) ...[
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  'SIM ${sim.slotIndex + 1}',
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
            const Spacer(),
            const Text(
              'SERVING CELL',
              style: TextStyle(
                fontSize: 9.5,
                letterSpacing: 0.8,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (paired)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _Meter(cell: lte, label: 'LTE anchor')),
              Container(
                width: 1,
                height: 56,
                color: AppColors.border,
                margin: const EdgeInsets.symmetric(horizontal: 14),
              ),
              Expanded(child: _Meter(cell: nr, label: '5G NR')),
            ],
          )
        else
          _Meter(cell: serving),
        const SizedBox(height: 12),
        Container(height: 1, color: AppColors.border),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Text(
                'Updated ${_clock(updated)}',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppColors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${cells.length} cell${cells.length == 1 ? '' : 's'} visible',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (serving != null) ...[
          if (paired) ...[
            const _SectionHeading('4G anchor'),
            _DetailCard(rows: ServingView.entries(lte)),
            const _SectionHeading('5G NR secondary'),
            _DetailCard(
              rows: ServingView.entries(
                nr,
                gnbEstimate: sim.nsaGnbEstimate,
              ),
            ),
          ] else ...[
            _SectionHeading(lte == null ? '5G NR' : 'Serving cell'),
            _DetailCard(rows: ServingView.entries(serving)),
          ],
          for (final secondary in sim.lteSecondaries) ...[
            const _SectionHeading('4G LTE secondary'),
            _DetailCard(
              rows: ServingView.entries(
                secondary,
                fallbackPlmn: lte?.plmn ?? nr?.plmn,
              ),
            ),
          ],
          const _SectionHeading('Radio quality'),
          _DetailCard(rows: ServingView.qualityEntries(sim)),
        ],
        if (cells.isNotEmpty) ...[
          _SectionHeading(
            neighbours.isEmpty
                ? 'Neighbour cells'
                : 'Neighbour cells (${neighbours.length})',
          ),
          _NeighbourCard(cells: neighbours),
        ],
      ],
    );
  }

  static String _clock(DateTime? when) {
    if (when == null) return '—';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
  }
}

/// One leg's meter: bars, the level, and the word under it.
class _Meter extends StatelessWidget {
  const _Meter({required this.cell, this.label});

  final CellTower? cell;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final dbm = cell?.dbm;
    final bars = cell?.bars ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SignalBars(
              bars: bars,
              height: label == null ? 40 : 30,
              barWidth: label == null ? 8 : 6,
              gap: 4,
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      dbm?.toString() ?? '—',
                      style: TextStyle(
                        fontSize: label == null ? 26 : 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'dBm',
                      style: TextStyle(
                        fontSize: 9.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                Text(
                  SignalQuality.label(bars),
                  style: TextStyle(
                    fontSize: label == null ? 11.5 : 10.5,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 9.5,
          letterSpacing: 0.9,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

/// A bordered block of label/value rows, the way the console drew its cards.
class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.rows});

  final List<MapEntry<String, String>> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text(
                'nothing reported',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ),
          for (var index = 0; index < rows.length; index++)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
              decoration: index == 0
                  ? null
                  : const BoxDecoration(
                      border: Border(
                        top: BorderSide(color: AppColors.border),
                      ),
                    ),
              child: Row(
                children: [
                  Text(
                    rows[index].key,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[index].value,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Cells heard but not serving: a band and a PCI, and the frequency line.
class _NeighbourCard extends StatelessWidget {
  const _NeighbourCard({required this.cells});

  final List<CellTower> cells;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          if (cells.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text(
                'none heard',
                style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ),
          for (var index = 0; index < cells.length; index++)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: index == 0
                  ? null
                  : const BoxDecoration(
                      border: Border(
                        top: BorderSide(color: AppColors.border),
                      ),
                    ),
              child: Row(
                children: [
                  Text(
                    _label(cells[index]),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // A neighbour arrives as a PCI, a band and a level, so the
                  // level is what says whether it is worth handing over to.
                  Text(
                    cells[index].dbm == null
                        ? '—'
                        : '${cells[index].dbm} dBm',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.forBars(cells[index].bars),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SignalBars(
                    bars: cells[index].bars,
                    height: 14,
                    barWidth: 3,
                    gap: 2,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      ServingView.neighbourFrequency(cells[index]) ?? '—',
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _label(CellTower cell) {
    final parts = <String>[
      if (cell.bandLabel != null) cell.bandLabel!,
      if (cell.pci != null) 'PCI ${cell.pci}',
    ];
    return parts.isEmpty ? 'unknown cell' : parts.join(' · ');
  }
}

/// Lists what the Bluetooth scan found, strongest first.
class _BlePicker extends StatelessWidget {
  const _BlePicker({required this.peers});

  final List<BleDesktopPeer> peers;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Phones over Bluetooth'),
      content: SizedBox(
        width: 380,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final peer in peers)
              ListTile(
                dense: true,
                title: Text(
                  peer.label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${peer.address}  \u00b7  ${peer.rssi} dBm',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textMuted,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(peer),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A phone being watched, over Wi-Fi or Bluetooth.
class _Peer {
  _Peer(String saved)
      : saved = saved,
        address = saved.startsWith(blePrefix)
            ? saved.substring(blePrefix.length)
            : saved;

  /// A Bluetooth share is saved as `ble:<address>`, so one list holds both
  /// transports and the config stays a list of strings.
  static const String blePrefix = 'ble:';

  final String saved;
  final String address;
  CellSnapshot? snapshot;
  String? error;
  DateTime? lastOk;

  RemoteClient? _client;

  bool get isBluetooth => saved.startsWith(blePrefix);

  /// One reading, over whichever transport this phone is watched by.
  Future<CellSnapshot> fetch() {
    if (isBluetooth) return BleDesktop.read(address);
    return (_client ??= RemoteClient(_peerUri(address))).fetch();
  }

  void dispose() {
    _client?.dispose();
    _client = null;
  }

  static Uri _peerUri(String input) {
    var text = input.trim();
    if (text.isEmpty) text = '127.0.0.1:41729';
    if (!text.contains('://')) text = 'http://$text';
    final parsed = Uri.parse(text);
    return Uri(
      scheme: parsed.scheme.isEmpty ? 'http' : parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : 41729,
    );
  }
}

/// The update banner that sits between the tabs and the phone list whenever
/// the checker has something to say: an offer, a download, a ready APK or a
/// failure. Quiet when there is nothing to offer.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdatePhase?>(
      valueListenable: UpdateChecker.update,
      builder: (context, phase, _) {
        if (phase == null || phase is UpdateChecking) {
          return const SizedBox.shrink();
        }
        final windows = Platform.isWindows;
        late final String title;
        late final String subtitle;
        var progress = 0.0;
        var action = '';
        switch (phase) {
          case final UpdateAvailable offer:
            title = 'Update available: ${offer.info.versionText}';
            subtitle = windows
                ? 'Unzip the new folder beside this one and swap them in — '
                    'a running exe cannot replace itself.'
                : 'The APK downloads and Android offers the install.';
            action = windows ? 'Open release page' : 'Download update';
          case final UpdateDownloading download:
            title = 'Downloading ${download.info.versionText}';
            subtitle = '${download.percent}% · installing comes next';
            progress = download.percent / 100;
          case final UpdateReady ready:
            title = '${ready.info.versionText} is downloaded';
            subtitle = windows
                ? 'Saved in Downloads — the button opens it in Explorer, then '
                    'unzip the new folder over this one.'
                : 'Tap install and Android takes it from there.';
            action = windows ? 'Show download' : 'Install update';
          case final UpdateFailed failed:
            title = 'Update check failed';
            subtitle = failed.message;
            action = 'Try again';
          case UpdateChecking():
            break;
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.system_update_alt_rounded,
                size: 18,
                color: AppColors.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (phase is UpdateDownloading)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: AppColors.border,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (action.isNotEmpty)
                FilledButton(
                  onPressed: () {
                    if (phase is UpdateAvailable) {
                      unawaited(UpdateChecker.install(phase.info));
                    } else if (phase is UpdateReady) {
                      unawaited(UpdateChecker.openReady(phase.filePath));
                    } else if (phase is UpdateFailed) {
                      unawaited(UpdateChecker.refresh());
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.background,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(action),
                ),
              const SizedBox(width: 6),
              if (phase is UpdateAvailable)
                TextButton(
                  onPressed: () => unawaited(UpdateChecker.skip()),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textMuted,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Skip this version'),
                ),
            ],
          ),
        );
      },
    );
  }
}
