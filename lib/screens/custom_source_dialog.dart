import 'package:flutter/material.dart';

import '../desktop/scenario.dart';
import '../theme/app_colors.dart';

/// The custom source editor: an LTE anchor and an NR leg, each optional.
///
/// The console also exposed aggregation layers and neighbour cells. What is
/// kept is the part a phone can tell apart for one site: which carriers are
/// served, on which band and channel, and how strong they arrive.
class CustomSourceDialog extends StatefulWidget {
  const CustomSourceDialog({super.key, required this.initial});

  final CustomSource initial;

  @override
  State<CustomSourceDialog> createState() => _CustomSourceDialogState();
}

class _CustomSourceDialogState extends State<CustomSourceDialog> {
  static const Map<String, String> _overrides = {
    'NONE': 'None — LTE only',
    'LTE_CA': 'LTE carrier aggregation',
    'NR_NSA': '5G NSA — LTE anchor plus a leg',
    'NR_SA': '5G SA — NR on its own',
  };

  late final TextEditingController _carrier;
  late final TextEditingController _mcc;
  late final TextEditingController _mnc;
  late final TextEditingController _lteBand;
  late final TextEditingController _lteArfcn;
  late final TextEditingController _lteDbm;
  late final TextEditingController _nrBand;
  late final TextEditingController _nrArfcn;
  late final TextEditingController _nrDbm;
  late bool _lteOn;
  late bool _nrOn;
  late String _override;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _carrier = TextEditingController(text: initial.carrierName);
    _mcc = TextEditingController(text: initial.mcc);
    _mnc = TextEditingController(text: initial.mnc);
    _lteOn = (initial.lteBand ?? 0) > 0;
    _nrOn = (initial.nrBand ?? 0) > 0;
    _lteBand = TextEditingController(text: '${initial.lteBand ?? 30}');
    _lteArfcn = TextEditingController(text: initial.lteArfcn?.toString() ?? '');
    _lteDbm = TextEditingController(text: '${initial.lteDbm}');
    _nrBand = TextEditingController(text: '${initial.nrBand ?? 5}');
    _nrArfcn = TextEditingController(text: initial.nrArfcn?.toString() ?? '');
    _nrDbm = TextEditingController(text: '${initial.nrDbm}');
    _override = initial.override;
  }

  @override
  void dispose() {
    for (final controller in [
      _carrier,
      _mcc,
      _mnc,
      _lteBand,
      _lteArfcn,
      _lteDbm,
      _nrBand,
      _nrArfcn,
      _nrDbm,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Custom source'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What the test source serves: an LTE anchor and an NR leg, each '
                'on its own band and channel. An empty ARFCN uses the middle of '
                'the band.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _field(
                      'Carrier',
                      _carrier,
                      const Key('custom-carrier'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _field('MCC', _mcc, const Key('custom-mcc'))),
                  const SizedBox(width: 8),
                  Expanded(child: _field('MNC', _mnc, const Key('custom-mnc'))),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 96,
                    child: Text(
                      'Network',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ),
                  // Expanded and ellipsised: these labels are long, and a
                  // dialog 460 px wide has to hold the whole list.
                  Expanded(
                    child: DropdownButton<String>(
                      value: _override,
                      isExpanded: true,
                      dropdownColor: AppColors.surface,
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textPrimary,
                      ),
                      items: [
                        for (final entry in _overrides.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(
                              entry.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _override = value);
                      },
                    ),
                  ),
                ],
              ),
              _carrierRow(
                label: 'LTE anchor',
                keyName: 'custom-lte',
                enabled: _lteOn,
                band: _lteBand,
                arfcn: _lteArfcn,
                dbm: _lteDbm,
                onToggle: (value) => setState(() => _lteOn = value),
              ),
              _carrierRow(
                label: 'NR leg',
                keyName: 'custom-nr',
                enabled: _nrOn,
                band: _nrBand,
                arfcn: _nrArfcn,
                dbm: _nrDbm,
                onToggle: (value) => setState(() => _nrOn = value),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.warning,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Serve this'),
        ),
      ],
    );
  }

  Widget _carrierRow({
    required String label,
    required String keyName,
    required bool enabled,
    required TextEditingController band,
    required TextEditingController arfcn,
    required TextEditingController dbm,
    required ValueChanged<bool> onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: enabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (value) => onToggle(value ?? false),
              ),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Row(
              children: [
                Expanded(
                  child: _field(
                    'Band',
                    band,
                    Key('$keyName-band'),
                    enabled: enabled,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field(
                    'ARFCN',
                    arfcn,
                    Key('$keyName-arfcn'),
                    enabled: enabled,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field(
                    'dBm',
                    dbm,
                    Key('$keyName-dbm'),
                    enabled: enabled,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    Key key, {
    bool enabled = true,
  }) {
    return TextField(
      key: key,
      controller: controller,
      enabled: enabled,
      style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        labelStyle: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
      ),
    );
  }

  void _save() {
    final mcc = _mcc.text.trim();
    final mnc = _mnc.text.trim();
    if (!RegExp(r'^\d{3}$').hasMatch(mcc) ||
        !RegExp(r'^\d{1,3}$').hasMatch(mnc)) {
      setState(() => _error = 'MCC is three digits and MNC one to three.');
      return;
    }
    if (!_lteOn && !_nrOn) {
      setState(() => _error = 'Turn on the LTE anchor, the NR leg, or both.');
      return;
    }

    final lteBand = _lteOn ? int.tryParse(_lteBand.text.trim()) : null;
    final nrBand = _nrOn ? int.tryParse(_nrBand.text.trim()) : null;
    if ((_lteOn && (lteBand == null || lteBand <= 0)) ||
        (_nrOn && (nrBand == null || nrBand <= 0))) {
      setState(() => _error = 'A band is a positive number, e.g. 30 or 5.');
      return;
    }

    int level(TextEditingController controller, int fallback) =>
        (int.tryParse(controller.text.trim()) ?? fallback).clamp(-140, -20).toInt();

    Navigator.of(context).pop(
      CustomSource(
        carrierName:
            _carrier.text.trim().isEmpty ? '$mcc-$mnc' : _carrier.text.trim(),
        mcc: mcc,
        mnc: mnc,
        override: _override,
        lteBand: lteBand,
        lteArfcn: lteBand == null ? null : int.tryParse(_lteArfcn.text.trim()),
        lteDbm: level(_lteDbm, -104),
        nrBand: nrBand,
        nrArfcn: nrBand == null ? null : int.tryParse(_nrArfcn.text.trim()),
        nrDbm: level(_nrDbm, -98),
      ),
    );
  }
}
