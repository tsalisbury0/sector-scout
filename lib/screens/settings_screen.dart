import 'package:flutter/material.dart';

import '../models/band_filters.dart';
import '../services/app_settings.dart';
import '../services/signal_notification.dart';
import '../theme/app_colors.dart';

/// The switches that change how the app reads a cell, and the ones that keep a
/// reading on screen: the band corrections and the pinned notification.
///
/// Every switch here changes what is *displayed*, never what the modem
/// reported — the raw values stay on the detail rows, and a corrected band says
/// what it replaced (`n41 (modem: n38)`).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SignalNotification _notification = SignalNotification();
  bool _notificationOn = false;
  bool _loadedNotification = false;

  @override
  void initState() {
    super.initState();
    // The switch follows the service, which may have been started from the SIM
    // page or restored by Android after a restart.
    _notification.isOn().then((on) {
      if (mounted) {
        setState(() {
          _notificationOn = on;
          _loadedNotification = true;
        });
      }
    });
  }

  Future<void> _setNotification(bool on) async {
    if (!on) {
      await _notification.disable();
      if (mounted) setState(() => _notificationOn = false);
      return;
    }
    final outcome = await _notification.enable();
    if (!mounted) return;
    setState(() => _notificationOn = outcome.on);
    if (!outcome.on && outcome.message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(outcome.message!),
          backgroundColor: AppColors.surface,
        ),
      );
    }
  }

  /// Flips a band switch, warning first when it is being turned **on**.
  ///
  /// The corrections are drawn from North American deployments — T-Mobile's
  /// n41/n25, US CBRS, Anterix's B106 numbering — and every one of those bands
  /// exists for real elsewhere. Getting it wrong is silent, so the warning is
  /// not something to click past by accident.
  Future<void> _setFilter({
    required bool value,
    required Future<void> Function(bool) apply,
  }) async {
    if (value && !await _confirmNorthAmerica()) return;
    await apply(value);
    if (mounted) setState(() {});
  }

  Future<bool> _confirmNorthAmerica() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('North America only'),
        content: const Text(
          'This correction assumes a North American network: T-Mobile’s '
          'n41/n25, US CBRS, or Anterix’s B106 numbering. The same bands are '
          'deployed for real elsewhere, so outside North America the label can '
          'name the wrong band.\n\nThe raw ARFCN, frequencies and identity are '
          'never changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Settings',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            Text(
              'Display corrections and alerts',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _SectionLabel('Band display'),
          _SettingsCard(
            children: [
              _SettingsSwitch(
                title: 'T-Mobile band corrections',
                subtitle: 'Reads n38 as n41 and n2 as n25 on T-Mobile, whose '
                    'carriers sit inside the wider band.',
                value: BandFilters.tmobileBands,
                onChanged: (value) => _setFilter(
                  value: value,
                  apply: AppSettings.setTmobileBands,
                ),
              ),
              const _CardDivider(),
              _SettingsSwitch(
                title: 'CBRS as n48',
                subtitle: 'A carrier between 3550 and 3700 MHz reads n48 even '
                    'when the modem names the wider n77.',
                value: BandFilters.cbrs,
                onChanged: (value) => _setFilter(
                  value: value,
                  apply: AppSettings.setCbrs,
                ),
              ),
              const _CardDivider(),
              _SettingsSwitch(
                title: 'Anterix B106',
                subtitle: 'Reads the 313-700 carrier as B106 — Anterix numbering '
                    '— instead of the band 8 the modem reports.',
                value: BandFilters.anterixB106,
                onChanged: (value) => _setFilter(
                  value: value,
                  apply: AppSettings.setAnterixB106,
                ),
              ),
            ],
          ),
          const _FootNote(
            'Corrections only change the label. The ARFCN, the frequencies and '
            'the identity stay as the radio reported them, and a corrected band '
            'names what it replaced.',
          ),
          const SizedBox(height: 20),
          const _SectionLabel('Notification'),
          _SettingsCard(
            children: [
              _SettingsSwitch(
                title: 'Pinned notification',
                subtitle: 'Keeps the serving cell and signal level in the shade '
                    'while the app is closed.',
                value: _notificationOn,
                enabled: _loadedNotification && _notification.isSupported,
                onChanged: _setNotification,
              ),
            ],
          ),
          if (!_notification.isSupported)
            const _FootNote('The pinned notification is Android only.'),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: children),
    );
  }
}

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: AppColors.border,
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: enabled ? AppColors.textPrimary : AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeTrackColor: AppColors.accent,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _FootNote extends StatelessWidget {
  const _FootNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          height: 1.4,
          color: Color(0xFF64748B),
        ),
      ),
    );
  }
}
