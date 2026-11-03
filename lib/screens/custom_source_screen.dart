import 'package:flutter/material.dart';

import '../desktop/scenario.dart';
import '../theme/app_colors.dart';

/// Carriers the page offers as a shortcut for the MCC/MNC boxes.
const List<(String, String)> _carriers = [
  ('AT&T', '310410'),
  ('T-Mobile', '310260'),
  ('Verizon', '311480'),
  ('FirstNet', '313100'),
  ('Ameren (Anterix)', '313700'),
  ('T-Satellite', '310830'),
  ('Dish', '313340'),
];

/// One entry in the override picker: the label, the value it puts on the wire,
/// and — for the two advanced flavours — whether picking it switches the anchor
/// on or off.
class _OverrideChoice {
  const _OverrideChoice(this.label, this.wire, [this.anchor]);

  final String label;
  final String wire;
  final bool? anchor;
}

/// The override list the console offered, and the value each entry sends.
///
/// `NR_ADVANCED` is one value on the wire — the phone cannot tell whether it is
/// holding an NSA pair or a standalone carrier — so the two entries send the
/// same thing and differ in what they set up: the NSA flavour keeps the anchor
/// and its single leg, the SA flavour drops the anchor and opens the source to
/// five aggregated carriers.
const List<_OverrideChoice> _overrides = [
  _OverrideChoice('NONE — LTE, no aggregation', 'NONE'),
  _OverrideChoice('LTE_CA — carrier aggregation', 'LTE_CA'),
  _OverrideChoice('LTE_ADVANCED_PRO — LTE Advanced Pro', 'LTE_ADVANCED_PRO'),
  _OverrideChoice('NR_NSA — LTE anchor + NR leg', 'NR_NSA'),
  _OverrideChoice('NR_SA — NR on its own', 'NR_SA'),
  _OverrideChoice('NR_ADVANCED (NSA) — anchor + one leg', 'NR_ADVANCED', true),
  _OverrideChoice('NR_ADVANCED (SA) — aggregated NR', 'NR_ADVANCED', false),
];

/// The custom source on a page of its own: every field of the reading is set by
/// hand here — the network, the LTE anchor, any carriers aggregated under it,
/// the NR legs, and the neighbours the modem hears but is not attached to.
///
/// The read-back at the top is built from what is actually served, not from the
/// rows, so it cannot promise a carrier the override drops.
class CustomSourceScreen extends StatefulWidget {
  const CustomSourceScreen({
    super.key,
    required this.initial,
    this.onChanged,
  });

  final CustomSource initial;

  /// Called with the draft on every edit, so what is served follows the
  /// boxes instead of waiting for the page to be dismissed.
  final ValueChanged<CustomSource>? onChanged;

  @override
  State<CustomSourceScreen> createState() => _CustomSourceScreenState();
}

/// A row plus the identity its widgets keep while the list is edited.
class _Slot {
  _Slot(this.id, this.carrier);

  final int id;
  CustomCarrier carrier;
}

class _CustomSourceScreenState extends State<CustomSourceScreen> {
  late final TextEditingController _carrier;
  late final TextEditingController _mcc;
  late final TextEditingController _mnc;
  late String _overrideLabel;
  late CustomCarrier _anchor;
  final List<_Slot> _layers = <_Slot>[];
  final List<_Slot> _legs = <_Slot>[];
  late CustomNeighbours _neighbours;
  late final TextEditingController _neighbourCount;
  late final TextEditingController _neighbourBand;
  var _nextId = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _carrier = TextEditingController(text: initial.carrierName);
    _mcc = TextEditingController(text: initial.mcc);
    _mnc = TextEditingController(text: initial.mnc);
    _overrideLabel = _labelFor(initial);
    _anchor = initial.lte ??
        const CustomCarrier(band: 30, arfcn: 9820, dbm: -104, pci: 76);
    for (final row in initial.lteLayers.take(maxLteLayers)) {
      _layers.add(_Slot(_nextId++, row));
    }
    for (final row in initial.nr.take(maxNrCarriers)) {
      _legs.add(_Slot(_nextId++, row));
    }
    _neighbours = initial.neighbours;
    _neighbourCount = TextEditingController(text: '${_neighbours.count}');
    _neighbourBand = TextEditingController(text: 'B${_neighbours.band}');
  }

  @override
  void dispose() {
    _carrier.dispose();
    _mcc.dispose();
    _mnc.dispose();
    _neighbourCount.dispose();
    _neighbourBand.dispose();
    super.dispose();
  }

  CustomSource _build() {
    String digits(TextEditingController controller, String fallback) {
      final text = controller.text.trim();
      return text.isEmpty ? fallback : text;
    }

    final mcc = digits(_mcc, '310');
    final mnc = digits(_mnc, '410');
    final name = _carrier.text.trim();
    return CustomSource(
      carrierName: name.isEmpty ? _carrierNameFor('$mcc$mnc') : name,
      mcc: mcc,
      mnc: mnc,
      override: _choice.wire,
      lte: _anchor,
      lteLayers: [for (final slot in _layers) slot.carrier],
      nr: [for (final slot in _legs) slot.carrier],
      neighbours: _neighbours,
    );
  }

  /// The picker entry that describes a saved source. Both advanced flavours
  /// carry the same wire value, so the anchor says which one it is.
  static String _labelFor(CustomSource source) {
    final v = source.override;
    if (v == 'NR_ADVANCED') {
      final anchored = source.lte?.enabled == true && source.lte!.hasBand;
      for (final choice in _overrides) {
        if (choice.wire == 'NR_ADVANCED' && choice.anchor == anchored) {
          return choice.label;
        }
      }
      return _overrides[5].label;
    }
    for (final choice in _overrides) {
      if (choice.wire == v && choice.anchor == null) return choice.label;
    }
    return _overrides.first.label;
  }

  _OverrideChoice get _choice => _overrides.firstWhere(
        (choice) => choice.label == _overrideLabel,
        orElse: () => _overrides.first,
      );

  static String _carrierNameFor(String plmn) {
    for (final entry in _carriers) {
      if (entry.$2 == plmn) return entry.$1;
    }
    return plmn.isEmpty ? 'Custom' : plmn;
  }

  /// Every edit is applied as it happens: this page is the source's editor,
  /// not a form that has to be submitted.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.onChanged?.call(_build());
  }

  void _serve() => Navigator.of(context).pop(_build());

  void _addLayer() {
    final band = 29;
    setState(() {
      _layers.add(
        _Slot(
          _nextId++,
          CustomCarrier(band: band, arfcn: defaultChannel(band, false), dbm: -108),
        ),
      );
    });
  }

  void _addLeg() {
    final band = 41;
    setState(() {
      _legs.add(
        _Slot(
          _nextId++,
          CustomCarrier(band: band, arfcn: defaultChannel(band, true), dbm: -95),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = _build();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        titleSpacing: 0,
        title: const Text(
          'Custom source',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _serve,
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: const Text('Serve this'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _ReadBack(source: source),
          const SizedBox(height: 14),
          _Section(
            title: 'Network',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  _Labelled(
                    label: 'Carrier',
                    child: SizedBox(
                      width: 210,
                      child: DropdownButton<String>(
                        key: const Key('custom-carrier'),
                        value: _carriers.any((e) => e.$2 == source.plmn)
                            ? source.plmn
                            : null,
                        isExpanded: true,
                        hint: const Text(
                          'type MCC/MNC',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                        dropdownColor: AppColors.surface,
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary,
                        ),
                        items: [
                          for (final entry in _carriers)
                            DropdownMenuItem(
                              value: entry.$2,
                              child: Text(
                                '${entry.$1} (${entry.$2.substring(0, 3)}'
                                '-${entry.$2.substring(3)})',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _mcc.text = value.substring(0, 3);
                            _mnc.text = value.substring(3);
                            _carrier.text = _carrierNameFor(value);
                          });
                        },
                      ),
                    ),
                  ),
                  _NumberField(
                    fieldKey: const Key('custom-mcc'),
                    label: 'MCC',
                    controller: _mcc,
                    width: 62,
                    onChanged: (_) => setState(() {}),
                  ),
                  _NumberField(
                    fieldKey: const Key('custom-mnc'),
                    label: 'MNC',
                    controller: _mnc,
                    width: 62,
                    onChanged: (_) => setState(() {}),
                  ),
                  _Labelled(
                    label: 'Override',
                    child: SizedBox(
                      width: 250,
                      child: DropdownButton<String>(
                        key: const Key('custom-override'),
                        value: _overrideLabel,
                        isExpanded: true,
                        dropdownColor: AppColors.surface,
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary,
                        ),
                        items: [
                          for (final choice in _overrides)
                            DropdownMenuItem(
                              value: choice.label,
                              child: Text(
                                choice.label,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          final choice = _overrides.firstWhere(
                            (entry) => entry.label == value,
                          );
                          setState(() {
                            _overrideLabel = value;
                            // An advanced flavour sets the source up as well as
                            // naming it, so the name and the layout agree.
                            final anchor = choice.anchor;
                            if (anchor != null) {
                              _anchor = _anchor.copyWith(enabled: anchor);
                            }
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'LTE anchor',
            subtitle: 'The cell the phone is registered on. Switch it off for a '
                'standalone 5G reading.',
            children: [
              _CarrierRow(
                key: const ValueKey('anchor'),
                fieldPrefix: 'anchor',
                title: 'Anchor',
                nr: false,
                carrier: _anchor,
                onChanged: (row) => setState(() => _anchor = row),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'LTE carriers',
            subtitle: 'Aggregated under the anchor. A carrier on B29 is served '
                'as a downlink-only SDL, with no identity.',
            action: TextButton.icon(
              onPressed: _layers.length >= maxLteLayers ? null : _addLayer,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add LTE carrier'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
            ),
            children: [
              if (_layers.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No aggregated carriers — the anchor alone.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
              for (final slot in _layers)
                _CarrierRow(
                  key: ValueKey(slot.id),
                  fieldPrefix: 'lte-${_layers.indexOf(slot)}',
                  title: 'LTE carrier ${_layers.indexOf(slot) + 1}',
                  nr: false,
                  carrier: slot.carrier,
                  onChanged: (row) => setState(() => slot.carrier = row),
                  onRemove: () => setState(() => _layers.remove(slot)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: '5G NR carriers',
            subtitle: 'Under NSA a leg is served without an NCI, so the app '
                'shows its estimated gNB. Standalone sends the identity, and '
                'aggregates up to five legs.',
            action: TextButton.icon(
              onPressed: _legs.length >= source.maxNr ? null : _addLeg,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add NR carrier'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
            ),
            children: [
              if (_legs.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No NR carriers — an LTE-only reading.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
              for (final slot in _legs)
                _CarrierRow(
                  key: ValueKey(slot.id),
                  fieldPrefix: 'nr-${_legs.indexOf(slot)}',
                  title: 'NR carrier ${_legs.indexOf(slot) + 1}',
                  nr: true,
                  carrier: slot.carrier,
                  onChanged: (row) => setState(() => slot.carrier = row),
                  onRemove: () => setState(() => _legs.remove(slot)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Neighbours',
            subtitle: 'Measured but not serving. A neighbour carries a PCI and a '
                'band only: no PLMN, no cell identity, no TAC.',
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Switch(
                    value: _neighbours.enabled,
                    onChanged: (value) =>
                        setState(() => _neighbours = _neighbours.copyWith(enabled: value)),
                  ),
                  _NumberField(
                    fieldKey: const Key('custom-neighbours-count'),
                    label: 'How many',
                    controller: _neighbourCount,
                    width: 80,
                    onChanged: (value) => setState(
                      () => _neighbours = _neighbours.copyWith(
                        count: parseBandLabel(value)?.clamp(0, maxNeighbours).toInt(),
                      ),
                    ),
                  ),
                  _NumberField(
                    fieldKey: const Key('custom-neighbours-band'),
                    label: 'Band',
                    controller: _neighbourBand,
                    width: 70,
                    onChanged: (value) {
                      final band = parseBandLabel(value);
                      setState(() => _neighbours = _neighbours.copyWith(band: band));
                    },
                  ),
                  const Text(
                    'up to $maxNeighbours',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the payload will actually carry, recomputed as the fields change.
class _ReadBack extends StatelessWidget {
  const _ReadBack({required this.source});

  final CustomSource source;

  @override
  Widget build(BuildContext context) {
    final override = source.wireOverride;
    final note = switch (override) {
      'NONE' => 'served as LTE with no override',
      'NR_NSA' => 'served as 5G NSA',
      'NR_SA' => 'served as 5G SA',
      _ => 'served as $override',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Serving: ${source.summary}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            note,
            style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
        ),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

/// A numeric box that reads as empty when it is empty, so a cleared identity
/// field really is cleared rather than zero.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.width,
    this.hint,
    this.onChanged,
    this.enabled = true,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final double width;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _Labelled(
      label: label,
      child: SizedBox(
        width: width,
        child: TextField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: AppColors.border),
            ),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    );
  }
}

/// One editable carrier.
///
/// Band, channel, level and identity all come from the fields, and the channel
/// follows the band when the band changes, so whichever of the two you know is
/// the one you can fill in.
class _CarrierRow extends StatefulWidget {
  const _CarrierRow({
    super.key,
    required this.fieldPrefix,
    required this.title,
    required this.nr,
    required this.carrier,
    required this.onChanged,
    this.onRemove,
  });

  final String fieldPrefix;
  final String title;
  final bool nr;
  final CustomCarrier carrier;
  final ValueChanged<CustomCarrier> onChanged;
  final VoidCallback? onRemove;

  @override
  State<_CarrierRow> createState() => _CarrierRowState();
}

class _CarrierRowState extends State<_CarrierRow> {
  late final TextEditingController _band;
  late final TextEditingController _arfcn;
  late final TextEditingController _mhz;
  late final TextEditingController _dbm;
  late final TextEditingController _site;
  late final TextEditingController _sector;
  late final TextEditingController _pci;
  late final TextEditingController _tac;
  late bool _enabled;

  static String _text(int? value) => value == null ? '' : '$value';

  @override
  void initState() {
    super.initState();
    final carrier = widget.carrier;
    _enabled = carrier.enabled;
    _band = TextEditingController(
      text: carrier.band == null ? '' : '${widget.nr ? 'n' : 'B'}${carrier.band}',
    );
    _arfcn = TextEditingController(text: _text(carrier.arfcn));
    _mhz = TextEditingController(text: _mhzText);
    _dbm = TextEditingController(text: '${carrier.dbm}');
    _site = TextEditingController(text: _text(carrier.site));
    _sector = TextEditingController(text: _text(carrier.sector));
    _pci = TextEditingController(text: _text(carrier.pci));
    _tac = TextEditingController(text: _text(carrier.tac));
  }

  @override
  void dispose() {
    _band.dispose();
    _arfcn.dispose();
    _mhz.dispose();
    _dbm.dispose();
    _site.dispose();
    _sector.dispose();
    _pci.dispose();
    _tac.dispose();
    super.dispose();
  }

  Key _key(String field) => Key('custom-${widget.fieldPrefix}-$field');

  void _emit() {
    widget.onChanged(
      widget.carrier.copyWith(
        enabled: _enabled,
        band: parseBandLabel(_band.text),
        arfcn: int.tryParse(_arfcn.text.trim()),
        dbm: int.tryParse(_dbm.text.trim()) ?? widget.carrier.dbm,
        site: int.tryParse(_site.text.trim()),
        sector: int.tryParse(_sector.text.trim()),
        // Clamped to what a radio can report, so a mistyped 900 is served as
        // the last valid LTE identity rather than a number no modem sends.
        pci: _pciValue,
        tac: int.tryParse(_tac.text.trim()),
      ),
    );
  }

  int? get _pciValue {
    final typed = int.tryParse(_pci.text.trim());
    if (typed == null) return null;
    return pciFor(widget.nr ? 'NR' : 'LTE', typed, typed);
  }

  /// The frequency for the channel in the boxes, or an empty box.
  String get _mhzText {
    final band = parseBandLabel(_band.text);
    final channel = int.tryParse(_arfcn.text.trim());
    final mhz = channelMhz(widget.nr, band, channel);
    return mhz == null ? '' : mhz.toStringAsFixed(2);
  }

  /// The channel and the frequency track each other, so whichever of the two
  /// you know is the one you can fill in.
  void _syncMhz() {
    final text = _mhzText;
    if (_mhz.text != text) _mhz.text = text;
  }

  void _mhzChanged(String text) {
    final mhz = double.tryParse(text.trim());
    final channel = channelOf(widget.nr, parseBandLabel(_band.text), mhz);
    if (channel != null && _arfcn.text.trim() != '$channel') {
      _arfcn.text = '$channel';
    }
    _emit();
    setState(() {});
  }

  /// A band is a shortcut for its channel window's middle, the way the
  /// console's band list filled the box in.
  void _bandChanged(String text) {
    final band = parseBandLabel(text);
    if (band != null) {
      final channel = defaultChannel(band, widget.nr);
      if (channel != null) _arfcn.text = '$channel';
    }
    _syncMhz();
    _emit();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Switch(
                key: _key('enabled'),
                value: _enabled,
                onChanged: (value) {
                  setState(() => _enabled = value);
                  _emit();
                },
              ),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _enabled ? AppColors.textPrimary : AppColors.textMuted,
                  ),
                ),
              ),
              if (widget.onRemove != null)
                IconButton(
                  tooltip: 'Remove this carrier',
                  onPressed: widget.onRemove,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  color: AppColors.textMuted,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _NumberField(
                fieldKey: _key('band'),
                label: 'Band',
                controller: _band,
                width: 68,
                hint: widget.nr ? 'n5' : 'B30',
                enabled: _enabled,
                onChanged: _bandChanged,
              ),
              _NumberField(
                fieldKey: _key('arfcn'),
                label: widget.nr ? 'ARFCN' : 'EARFCN',
                controller: _arfcn,
                width: 96,
                enabled: _enabled,
                onChanged: (_) {
                  _syncMhz();
                  _emit();
                  setState(() {});
                },
              ),
              _NumberField(
                fieldKey: _key('mhz'),
                label: 'MHz',
                controller: _mhz,
                width: 88,
                enabled: _enabled,
                onChanged: _mhzChanged,
              ),
              _NumberField(
                fieldKey: _key('dbm'),
                label: 'dBm',
                controller: _dbm,
                width: 62,
                enabled: _enabled,
                onChanged: (_) => _emit(),
              ),
              _NumberField(
                fieldKey: _key('site'),
                label: widget.nr ? 'gNB' : 'eNB',
                controller: _site,
                width: 92,
                enabled: _enabled,
                onChanged: (_) => _emit(),
              ),
              _NumberField(
                fieldKey: _key('sector'),
                label: 'Sector',
                controller: _sector,
                width: 68,
                enabled: _enabled,
                onChanged: (_) => _emit(),
              ),
              _NumberField(
                fieldKey: _key('pci'),
                label: 'PCI',
                controller: _pci,
                width: 58,
                enabled: _enabled,
                onChanged: (_) => _emit(),
              ),
              _NumberField(
                fieldKey: _key('tac'),
                label: 'TAC',
                controller: _tac,
                width: 72,
                enabled: _enabled,
                onChanged: (_) => _emit(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
