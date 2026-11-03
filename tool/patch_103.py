"""1.0.3: trust the platform's NR state when the modem hides the 5G cell."""
import io


def edit(path, pairs):
    text = io.open(path, encoding="utf-8").read()
    for old, new in pairs:
        if old not in text:
            raise SystemExit("MISSING in %s: %r" % (path, old[:80]))
        text = text.replace(old, new, 1)
    io.open(path, "w", encoding="utf-8", newline="\n").write(text)
    print("patched", path)


# 1. Dart model: the NR state the platform reports.
edit(
    "lib/models/cell_snapshot.dart",
    [
        (
            "    this.overrideNetworkType = 'NONE',\n  });",
            "    this.overrideNetworkType = 'NONE',\n    this.nrState = '',\n  });",
        ),
        (
            "      overrideNetworkType: _string(map['overrideNetworkType']) ?? 'NONE',\n    );",
            "      overrideNetworkType: _string(map['overrideNetworkType']) ?? 'NONE',\n"
            "      nrState: _string(map['nrState']) ?? '',\n    );",
        ),
        (
            "  /// status-bar 5G / 5G+ indicator: NR_SA, NR_NSA, NR_NSA_MMWAVE, LTE_CA…\n"
            "  final String overrideNetworkType;",
            "  /// status-bar 5G / 5G+ indicator: NR_SA, NR_NSA, NR_NSA_MMWAVE, LTE_CA…\n"
            "  final String overrideNetworkType;\n"
            "\n"
            "  /// `TelephonyManager.getNrState()`: `NONE`, `RESTRICTED`, `NOT_RESTRICTED`,\n"
            "  /// `CONNECTED`, or empty when the platform will not answer.\n"
            "  ///\n"
            "  /// Some modems — Samsung on Spark NZ among them — keep the NR cell out of\n"
            "  /// `getAllCellInfo()` while the platform's own NR state says the leg is\n"
            "  /// **CONNECTED**, so this is the only evidence that 5G is really up.\n"
            "  final String nrState;\n"
            "\n"
            "  /// True when the platform says the NR leg is connected, cell or no cell.\n"
            "  bool get nrConnected => nrState == 'CONNECTED';",
        ),
    ],
)

# 2. The badge rule.
edit(
    "lib/widgets/tech_badge.dart",
    [
        (
            "/// (`SignalIcon.kt`), so the card and the shade never disagree: 5G is only\n"
            "/// claimed when an NR cell is attached to the slot, because Samsung keeps\n"
            "/// reporting `NR_NSA` for a while after the 5G leg has gone.",
            "/// (`SignalIcon.kt`), so the card and the shade never disagree. 5G is\n"
            "/// claimed when an NR cell is attached to the slot, or when the platform's\n"
            "/// own NR state says the leg is **CONNECTED** even though the modem is\n"
            "/// hiding the cell — NZ Samsungs do exactly that. The bare `NR_NSA`\n"
            "/// override is still not enough: it lingers after the 5G leg has gone.",
        ),
        (
            "    nrAttached: sim.nrServing != null,\n    aggregated: sim.lteAggregated,",
            "    // The NR cell when the radio publishes one; otherwise the platform's\n"
            "    // own NR state, where a CONNECTED leg with no cell exposed is still 5G.\n"
            "    nrAttached: sim.nrServing != null || sim.nrConnected,\n"
            "    aggregated: sim.lteAggregated,",
        ),
    ],
)

# 3. Header chip and its footnote.
edit(
    "lib/screens/home_screen.dart",
    [
        (
            "                attached: sim.isNsa && nr != null,",
            "                // Green while the leg is really up: an NR cell attached, or the\n"
            "                // platform's own NR state saying CONNECTED.\n"
            "                attached: (sim.isNsa && nr != null) || sim.nrConnected,",
        ),
        (
            "          const _FootNote(\n"
            "            'The platform reports 5G is active on this SIM, but the radio is '\n"
            "            'not exposing an NR cell right now — Samsung only hands the NR leg '\n"
            "            'to apps while it is carrying data. The meter above is the LTE '\n"
            "            'anchor.',\n"
            "          ),",
            "          _FootNote(\n"
            "            'The platform reports the NR leg connected (NR state: '\n"
            "            '${sim.nrState.isEmpty ? 'not reported' : sim.nrState}) while '\n"
            "            'the radio is not exposing an NR cell right now — Samsung only '\n"
            "            'hands the NR leg to apps while it is carrying data. The 5G '\n"
            "            'badge is the platform’s word, not a cell: the meter above is '\n"
            "            'the LTE anchor.',\n"
            "          ),",
        ),
    ],
)

# 4. The dashboard the phone serves on the LAN.
edit(
    "lib/services/dashboard_html.dart",
    [
        (
            "            'The platform reports 5G is active on this SIM, but the radio is '\n"
            "            'not exposing an NR cell right now — Samsung only hands the NR leg '\n"
            "            'to apps while it is carrying data. The meter above is the LTE '\n"
            "            'anchor.',",
            "            'The platform reports the NR leg connected (NR state: '\n"
            "            '${sim.nrState.isEmpty ? 'not reported' : sim.nrState}) while '\n"
            "            'the radio is not exposing an NR cell right now — Samsung only '\n"
            "            'hands the NR leg to apps while it is carrying data. The 5G '\n"
            "            'badge is the platform’s word, not a cell: the meter above is '\n"
            "            'the LTE anchor.',",
        ),
    ],
)

# 5. Kotlin: put the NR state in the slot.
edit(
    "android/app/src/main/kotlin/com/celltower/cell_tower_monitor/CellSnapshot.kt",
    [
        (
            '        m["overrideNetworkType"] = overrideName(override)',
            '        m["overrideNetworkType"] = overrideName(override)\n'
            "        // The platform's own word on the NR leg. Modems that hide the NR\n"
            "        // cell from getAllCellInfo() — Samsung on NZ networks, among\n"
            "        // others — still answer here, which is what lets the badge claim\n"
            "        // 5G with no cell to point at.\n"
            '        m["nrState"] = nrStateName(nrState(tm))',
        ),
        (
            "    /** True when the platform is advertising any active 5G link. */",
            "    /**\n"
            "     * `TelephonyManager.getNrState()`: 0 none, 1 restricted, 2 not\n"
            "     * restricted, 3 connected. A hidden API, so it is read reflectively\n"
            "     * and an absence is simply an empty answer.\n"
            "     */\n"
            "    private fun nrState(tm: TelephonyManager?): Int? {\n"
            "        if (tm == null) return null\n"
            "        return try {\n"
            '            val method = TelephonyManager::class.java.getMethod("getNrState")\n'
            "            method.invoke(tm) as? Int\n"
            "        } catch (error: Exception) {\n"
            "            null\n"
            "        }\n"
            "    }\n"
            "\n"
            "    private fun nrStateName(value: Int?): String = when (value) {\n"
            '        0 -> "NONE"\n'
            '        1 -> "RESTRICTED"\n'
            '        2 -> "NOT_RESTRICTED"\n'
            '        3 -> "CONNECTED"\n'
            '        else -> ""\n'
            "    }\n"
            "\n"
            "    /** True when the platform is advertising any active 5G link. */",
        ),
    ],
)

# 6. Kotlin: the pinned notification's badge and mode.
edit(
    "android/app/src/main/kotlin/com/celltower/cell_tower_monitor/SignalSummary.kt",
    [
        (
            "                nrAttached = nr != null,\n                aggregated = aggregated,",
            "                // NR cell attached, or the platform's NR state connected\n"
            "                // with no cell exposed: still 5G.\n"
            "                nrAttached = nr != null || nrConnected(sim),\n"
            "                aggregated = aggregated,",
        ),
        (
            '        if (nr != null) return if (lte != null) "5G NSA" else "5G SA"\n'
            "        if (lte != null) {",
            '        if (nr != null) return if (lte != null) "5G NSA" else "5G SA"\n'
            '        if (lte != null && nrConnected(sim)) return "5G NSA"\n'
            "        if (lte != null) {",
        ),
        (
            "    private fun carrierOf(",
            "    /** The platform's word on the NR leg, for a modem hiding the cell. */\n"
            "    private fun nrConnected(sim: Map<String, Any?>): Boolean =\n"
            '        sim["nrState"] == "CONNECTED"\n'
            "\n"
            "    private fun carrierOf(",
        ),
    ],
)

# 7. Versions: 1.0.3 betas everywhere.
edit("pubspec.yaml", [("version: 1.0.2+3", "version: 1.0.3+4")])
edit(
    "lib/services/update_checker.dart",
    [
        ("const String kBuildTag = 'v1.0.2-beta';", "const String kBuildTag = 'v1.0.3-beta';"),
        ("const String kVersionText = '1.0.2';", "const String kVersionText = '1.0.3';"),
    ],
)
edit("desktop/sector_scout_desktop.py", [('APP_VERSION = "1.0.2"', 'APP_VERSION = "1.0.3"')])
print("all edits applied")
