import io

ROOT = "D:/cell_tower_monitor/"


def load(path):
    return io.open(ROOT + path, encoding="utf-8", newline="").read().replace("\r\n", "\n")


def save(path, text):
    io.open(ROOT + path, "w", encoding="utf-8", newline="").write(text)


def sub(text, old, new):
    n = text.count(old)
    assert n == 1, (n, old[:80])
    return text.replace(old, new)


h = load("lib/screens/desktop_home.dart")

h = sub(
    h,
    "  bool _scanning = false;\n",
    "  bool _scanning = false;\n"
    "\n"
    "  /// Kept apart from [_scanning] so a Bluetooth scan leaves the Wi-Fi\n"
    "  /// button alone, and neither can block the other.\n"
    "  bool _bluetoothScanning = false;\n"
    "\n"
    "  /// True while a sweep is running, so the poll timer cannot start a second\n"
    "  /// one on top of the first.\n"
    "  bool _polling = false;\n",
)

h = sub(
    h,
    "    if (_scanning) return;\n"
    "    setState(() {\n"
    "      _scanning = true;\n"
    "      _status = 'Scanning Bluetooth\\u2026';\n"
    "    });",
    "    if (_bluetoothScanning) return;\n"
    "    setState(() {\n"
    "      _bluetoothScanning = true;\n"
    "      _status = 'Scanning Bluetooth\\u2026';\n"
    "    });",
)

h = sub(
    h,
    "      setState(() => _status = 'Bluetooth scan failed: $error';\n"
    "    } finally {\n"
    "      if (mounted) setState(() => _scanning = false);\n"
    "    }",
    "      setState(() => _status = 'Bluetooth scan failed: $error';\n"
    "    } finally {\n"
    "      if (mounted) setState(() => _bluetoothScanning = false);\n"
    "    }",
)

h = sub(
    h,
    "          scanning: _scanning,\n          onAdd: _addFromField,",
    "          scanning: _scanning,\n"
    "          bluetoothScanning: _bluetoothScanning,\n"
    "          onAdd: _addFromField,",
)

h = sub(
    h,
    "    required this.onScanBluetooth,\n"
    "    required this.scanning,\n"
    "    this.error,",
    "    required this.onScanBluetooth,\n"
    "    required this.scanning,\n"
    "    required this.bluetoothScanning,\n"
    "    this.error,",
)

h = sub(
    h,
    "  final bool scanning;\n  final String? error;",
    "  final bool scanning;\n"
    "\n"
    "  /// Its own state, so the Wi-Fi button does not say \"Scanning\u2026\" while\n"
    "  /// Bluetooth is the thing being scanned.\n"
    "  final bool bluetoothScanning;\n"
    "  final String? error;",
)

h = sub(
    h,
    "                  onPressed: Platform.isWindows && !scanning\n"
    "                      ? onScanBluetooth\n"
    "                      : null,",
    "                  onPressed: Platform.isWindows && !bluetoothScanning\n"
    "                      ? onScanBluetooth\n"
    "                      : null,",
)

h = sub(
    h,
    "                  label: const Text('Scan Bluetooth'),",
    "                  label: Text(\n"
    "                    bluetoothScanning ? 'Scanning\u2026' : 'Scan Bluetooth',\n"
    "                  ),",
)

# The test source is a tool, not something to hold a port for at launch.
h = sub(
    h,
    "    unawaited(_source.start());\n\n"
    "    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollAll());",
    "    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollAll());",
)

h = sub(
    h,
    "          _Tabs(index: _tab, onChanged: (value) => setState(() => _tab = value)),",
    "          _Tabs(\n"
    "            index: _tab,\n"
    "            onChanged: (value) {\n"
    "              setState(() => _tab = value);\n"
    "              // Nothing is served until the source is actually opened: a\n"
    "              // window that held port 41729 from launch was serving a test\n"
    "              // reading nobody had asked for.\n"
    "              if (value == 1 && !_source.running) unawaited(_startSource());\n"
    "            },\n"
    "          ),",
)

h = sub(
    h,
    "  Future<void> _toggleSource() async {",
    "  /// Starts the source and repaints once it has, so the bar shows the address\n"
    "  /// it bound.\n"
    "  Future<void> _startSource() async {\n"
    "    await _source.start();\n"
    "    if (mounted) setState(() {});\n"
    "  }\n"
    "\n"
    "  Future<void> _toggleSource() async {",
)

h = sub(
    h,
    "  Future<void> _pollAll() async {\n    for (final peer in _peers) {",
    "  /// One sweep at a time: a Bluetooth read takes seconds, and two of them\n"
    "  /// reset each other's cursor on the phone mid-payload.\n"
    "  Future<void> _pollAll() async {\n"
    "    if (_polling) return;\n"
    "    _polling = true;\n"
    "    try {\n"
    "      await _pollPeers();\n"
    "    } finally {\n"
    "      _polling = false;\n"
    "    }\n"
    "  }\n"
    "\n"
    "  Future<void> _pollPeers() async {\n"
    "    for (final peer in _peers) {",
)

save("lib/screens/desktop_home.dart", h)
print("scan states split, polling serialised, source starts on demand")
