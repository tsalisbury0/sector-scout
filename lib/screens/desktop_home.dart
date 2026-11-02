import 'dart:async';

import 'package:flutter/material.dart';

import '../desktop/desktop_config.dart';
import '../desktop/scenario.dart';
import '../desktop/test_source.dart';
import '../models/cell_snapshot.dart';
import '../services/remote_client.dart';
import '../services/serving_view.dart';
import '../theme/app_colors.dart';
import '../widgets/signal_bars.dart';
import '../widgets/tech_badge.dart';

/// The desktop console: every watched phone gets its own card, and the cards
/// sit side by side instead of stacking. It draws the same [ServingView] rows
/// and the same widgets as the phone, so the two cannot drift apart.
class DesktopHome extends StatefulWidget {
  const DesktopHome({super.key, this.config});

  /// Tests pass their own, so they never read the real profile.
  final DesktopConfig? config;

  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<DesktopHome> {
  final List<_Peer> _peers = <_Peer>[];
  late final DesktopConfig _config;
  final DesktopTestSource _source = DesktopTestSource();
  late String _scenarioId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _config = widget.config ?? DesktopConfig.load();

    // The phones and the scenario are what the console remembered, so the
    // window comes back the way it was left.
    // A config written by the Python console names its own scenarios, so an
    // id this build does not know falls back to the first preset.
    _scenarioId = Scenario.byId(_config.scenarioId)?.id ?? Scenario.presets.first.id;
    _source.scenario = Scenario.byId(_scenarioId) ?? Scenario.presets.first;
    for (final address in _config.phones) {
      _peers.add(_Peer(address));
    }
    unawaited(_source.start());

    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollAll());
    if (_peers.isNotEmpty) unawaited(_pollAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_source.stop());
    for (final peer in _peers) {
      peer.client.dispose();
    }
    super.dispose();
  }

  Future<void> _pollAll() async {
    for (final peer in _peers) {
      try {
        final snapshot = await peer.client.fetch();
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
  }

  Future<void> _addPhone() async {
    final address = await showDialog<String>(
      context: context,
      builder: (context) => const _AddPhoneDialog(),
    );
    if (address == null || address.trim().isEmpty) return;
    setState(() => _peers.add(_Peer(address.trim())));
    unawaited(_saveConfig());
    await _pollAll();
  }

  void _clear() {
    for (final peer in _peers) {
      peer.client.dispose();
    }
    setState(_peers.clear);
    unawaited(_saveConfig());
  }

  /// Remembers the watched phones and the served scenario.
  Future<void> _saveConfig() async {
    _config.phones
      ..clear()
      ..addAll(_peers.map((peer) => peer.address));
    _config.scenarioId = _scenarioId;
    await _config.save();
  }

  void _selectScenario(String id) {
    final scenario = Scenario.byId(id);
    if (scenario == null) return;
    setState(() {
      _scenarioId = id;
      _source.scenario = scenario;
    });
    unawaited(_saveConfig());
  }

  Future<void> _toggleSource() async {
    if (_source.running) {
      await _source.stop();
    } else {
      await _source.start();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final answering = _peers.where((p) => p.snapshot != null).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _TopBar(onAdd: _addPhone, onClear: _clear, onRefresh: _pollAll),
          _SourceBar(
            scenarioId: _scenarioId,
            running: _source.running,
            uri: _source.uri,
            failure: _source.failure,
            onScenario: _selectScenario,
            onToggle: _toggleSource,
          ),
          Expanded(
            child: _peers.isEmpty
                ? const _EmptyState()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final peer in _peers)
                              SizedBox(
                                width: _cardWidth(constraints.maxWidth),
                                child: _PhoneCard(peer: peer),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Text(
              '${_peers.length} watched · $answering answering · '
              'this PC answers on 127.0.0.1:41729 when the phone app is not using it',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// Two cards at 1280 px, three at 1800, one when there is no room.
  static double _cardWidth(double available) {
    const minimum = 560.0;
    final columns = (available / minimum).floor().clamp(1, 4);
    final width = (available - 24 - (columns - 1) * 12) / columns;
    return width < minimum ? available - 24 : width;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onAdd,
    required this.onClear,
    required this.onRefresh,
  });

  final VoidCallback onAdd;
  final VoidCallback onClear;
  final VoidCallback onRefresh;

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
            'Desktop',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh now',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            color: AppColors.textMuted,
          ),
          IconButton(
            tooltip: 'Stop watching every phone',
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Watch phone'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.background,
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
    required this.running,
    required this.uri,
    required this.failure,
    required this.onScenario,
    required this.onToggle,
  });

  final String scenarioId;
  final bool running;
  final Uri? uri;
  final String? failure;
  final ValueChanged<String> onScenario;
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
          DropdownButton<String>(
            value: scenarioId,
            dropdownColor: AppColors.surface,
            underline: const SizedBox.shrink(),
            style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
            items: [
              for (final scenario in Scenario.presets)
                DropdownMenuItem(value: scenario.id, child: Text(scenario.name)),
            ],
            onChanged: (value) {
              if (value != null) onScenario(value);
            },
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onToggle,
            style: FilledButton.styleFrom(
              backgroundColor: running ? AppColors.surface : AppColors.accent,
              foregroundColor: running ? AppColors.textPrimary : AppColors.background,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(running ? 'Stop' : 'Serve'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              running
                  ? '${uri ?? ""}  ·  a phone can Watch this address'
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
              'Tap Watch phone and type the address a phone shows while it is '
              'sharing over Wi-Fi.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a peer's address.
///
/// It owns its controller: disposing one as soon as [showDialog] returns
/// throws, because the dialog's exit animation still rebuilds the field.
class _AddPhoneDialog extends StatefulWidget {
  const _AddPhoneDialog();

  @override
  State<_AddPhoneDialog> createState() => _AddPhoneDialogState();
}

class _AddPhoneDialogState extends State<_AddPhoneDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Watch a phone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Address of a phone with sharing turned on. A bare IP uses port '
            '41729; 127.0.0.1 watches this PC.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: '10.1.1.47',
              hintStyle: TextStyle(color: AppColors.textMuted),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Watch'),
        ),
      ],
    );
  }
}

class _PhoneCard extends StatelessWidget {
  const _PhoneCard({required this.peer});

  final _Peer peer;

  @override
  Widget build(BuildContext context) {
    final snapshot = peer.snapshot;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
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
                child: Text(
                  peer.address,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                peer.error != null
                    ? 'not answering'
                    : peer.lastOk == null
                        ? 'asking…'
                        : _age(peer.lastOk!),
                style: TextStyle(
                  fontSize: 11.5,
                  color: peer.error != null ? AppColors.warning : AppColors.textMuted,
                ),
              ),
            ],
          ),
          if (snapshot != null && snapshot.deviceModel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                snapshot.deviceModel,
                style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
            ),
          if (peer.error != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: const BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border(left: BorderSide(color: AppColors.warning, width: 2)),
              ),
              child: Text(
                peer.error!,
                style: const TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.warning),
              ),
            ),
          if (snapshot != null)
            for (final sim in snapshot.sims)
              _SimBlock(sim: sim, showSlot: snapshot.sims.length > 1)
          else if (peer.error == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'asking…',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  static String _age(DateTime when) {
    final seconds = DateTime.now().difference(when).inSeconds;
    if (seconds < 1) return 'now';
    if (seconds < 90) return '${seconds}s ago';
    return '${seconds ~/ 60}m ago';
  }
}

class _SimBlock extends StatelessWidget {
  const _SimBlock({required this.sim, required this.showSlot});

  final SimReading sim;
  final bool showSlot;

  @override
  Widget build(BuildContext context) {
    final anchor = sim.lteServing ?? sim.serving;
    final leg = sim.nrServing;
    final serving = leg ?? anchor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                '${showSlot ? 'SIM ${sim.slotIndex + 1}  ' : ''}'
                '${ServingView.carrierName(sim)}',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            TechBadge(label: _badge(sim)),
          ],
        ),
        if (serving != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SignalBars(bars: serving.bars, height: 26, barWidth: 6, gap: 4),
              const SizedBox(width: 10),
              Text(
                serving.dbm == null ? '—' : '${serving.dbm} dBm',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ],
        if (anchor != null) _CellRows(cell: anchor, name: 'LTE'),
        if (leg != null) _CellRows(cell: leg, name: '5G NR'),
        if (anchor == null && leg == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'no cells reported',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
      ],
    );
  }

  static String _badge(SimReading sim) {
    if (sim.nrServing != null) return sim.lteServing != null ? '5G NSA' : '5G SA';
    return 'LTE';
  }
}

class _CellRows extends StatelessWidget {
  const _CellRows({required this.cell, required this.name});

  final CellTower cell;
  final String name;

  @override
  Widget build(BuildContext context) {
    final rows = ServingView.entries(cell);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$name · ${cell.tech.label}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      row.key,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
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

class _Peer {
  _Peer(String address)
      : address = address,
        client = RemoteClient(_peerUri(address));

  final String address;
  final RemoteClient client;
  CellSnapshot? snapshot;
  String? error;
  DateTime? lastOk;

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
