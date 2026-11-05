package com.celltower.cell_tower_monitor

import kotlin.math.roundToInt

/**
 * Turns a snapshot into the three lines the pinned notification shows.
 *
 * Formatting only — it reads the same maps [CellSnapshot] produces, so it can
 * be unit tested without a device. Two rules are mirrored from the Dart model
 * (`lib/models/cell_snapshot.dart`) because the notification is drawn without
 * the Flutter engine: the band-106 re-code, and the gNB/sector split.
 */
object SignalSummary {

    /**
     * What the notification needs: a collapsed line, an expanded one, and the
     * slot they describe.
     *
     * The slot travels with the lines because it has to name the same SIM the
     * numbers came from — a dual-SIM phone is otherwise ambiguous.
     */
    data class Lines(
        val title: String,
        val text: String,
        val detail: String,
        val slotIndex: Int,
        val badge: String?,
    ) {
        val slotLabel: String get() = "SIM ${slotIndex + 1}"
    }

    /**
     * Which display corrections to apply, mirrored from the Settings page.
     *
     * Defaults are all-on, which is what a fresh install uses and what the
     * unit tests assume when they call [of] without arguments.
     */
    data class Corrections(
        val tmobileBands: Boolean = true,
        val cbrs: Boolean = true,
    )

    private const val B106_PLMN = "313700"
    private const val B106_FIRST = 134292
    private const val B106_LAST = 134341

    /**
     * LTE bands with a downlink and no uplink: 29, 32, 67, 69, 75 and 76.
     *
     * A supplemental carrier never serves on its own — a radio only reports
     * one while it is aggregating it under a primary — so a cell of any of
     * these is always a secondary component.
     */
    private val sdlBands = setOf(29, 32, 67, 69, 75, 76)

    /** Their EARFCN windows, for a cell the modem did not give a band. */
    private val sdlWindows = listOf(
        9660..9769,   // 29 — the 700 MHz supplemental downlink
        9920..10359,  // 32
        67336..67535, // 67
        67836..68335, // 69
        69466..70315, // 75
        70316..70365, // 76
    )

    /**
     * True for a downlink-only LTE carrier.
     *
     * Mirrors the Dart model: the band the modem named wins, and only when it
     * named none is the channel used to place it.
     */
    private fun isSecondaryLte(cell: Map<String, Any?>): Boolean {
        if (cell.tech() != "LTE") return false
        val bands = (cell["bands"] as? List<*>)
            ?.mapNotNull { (it as? Number)?.toInt() }
            .orEmpty()
        val band = bands.firstOrNull()
        if (band != null) return sdlBands.contains(band)
        val arfcn = (cell["arfcn"] as? Number)?.toInt() ?: return false
        return sdlWindows.any { arfcn in it }
    }

    /** PLMNs whose NR gNB IDs are 26 bits rather than the 22-bit default. */
    private val attPlmns = setOf("310410", "310150", "310170", "310380", "313100")

    /** T-Mobile network: 24-bit gNB IDs. T-911 rides the same RAN. */
    private val tmobilePlmns = setOf("310260", "312190")

    /**
     * Bar count for a level, using the scale the app draws: 5 bars at -84 dBm
     * and above, then 10 dB steps down to 0 below -125.
     */
    fun barsFor(dbm: Int?): Int? = dbm?.let {
        when {
            it >= -84 -> 5
            it >= -94 -> 4
            it >= -104 -> 3
            it >= -114 -> 2
            it >= -124 -> 1
            else -> 0
        }
    }

    /**
     * The notification lines for the SIM carrying data (or the call).
     *
     * [brands] maps PLMN to brand; it is the same list the app resolves names
     * with, so the notification and the card agree on what to call a network.
     */
    fun of(
        snapshot: Map<String, Any?>,
        aliasB106: Boolean,
        brands: Map<String, String> = emptyMap(),
        satellites: Set<String> = emptySet(),
        lteMs: Set<String> = emptySet(),
        corrections: Corrections = Corrections(),
        fiveG: Map<String, String> = emptyMap(),
        nrBits: Map<String, Int> = emptyMap(),
    ): Lines? {
        // The list spells PLMNs the way its UI does (`313-700`, `310-830`); a
        // cell identity reports `mcc` and `mnc` separately, so it reads
        // `313700`. Normalising both sides here is what makes a tag match.
        _satellites.clear()
        _satellites.addAll(satellites.mapNotNull(::compactPlmn))
        _lteMs.clear()
        _lteMs.addAll(lteMs.mapNotNull(::compactPlmn))

        val sim = pickSim(snapshot) ?: return null
        val cells = (sim["cells"] as? List<*>)
            ?.filterIsInstance<Map<String, Any?>>()
            .orEmpty()
        val serving = cells.filter { it["registered"] == true }
        // Band 29 is a downlink-only supplemental carrier: the radio reports it
        // with no cell identity, so it must never be the cell the shade
        // describes. It is only used when it is the sole LTE cell there is.
        val lteCells = serving.filter { it.tech() == "LTE" }
        val lte = lteCells.firstOrNull { !isSecondaryLte(it) } ?: lteCells.firstOrNull()
        val nr = serving.firstOrNull { it.tech() == "NR" }
        val primary = lte ?: nr ?: serving.firstOrNull() ?: return null

        // A second LTE carrier is aggregation: another registered cell, or a
        // supplemental downlink. An NSA slot whose NR leg has gone therefore
        // still reads LTE+ while a B29 is underneath the anchor.
        val aggregated = cells.any {
            it.tech() == "LTE" && it !== lte &&
                (it["registered"] == true || isSecondaryLte(it))
        }

        // Tag lookups accept the cell's own PLMN or the network this SIM is
        // registered on. They are usually the same string, but a cell identity
        // can arrive without mcc/mnc while `ServiceState` still carries the
        // network — the app's own cards resolve the tag on the SIM's network for
        // that reason, and the shade must agree with them.
        val tagPlmns = setOfNotNull(
            compactPlmn(plmnOf(primary)),
            compactPlmn(sim["plmn"] as? String),
        )
        fun tagged(tags: Set<String>) = tagPlmns.any { tags.contains(it) }

        val lteM = tagged(_lteMs)
        val primaryIsSat = tagged(_satellites)
        val mode = modeOf(sim, lte, lteM, nr)
        val carrier = carrierOf(sim, primary, brands)
        val band = bandLabel(primary, aliasB106, corrections)
        val channel = channelOf(primary, aliasB106)
        val dbm = primary["dbm"] as? Int

        // A satellite link names its path, not its radio, so `SAT` rides with
        // the reading in both the collapsed line and the expanded one — the
        // badge alone is invisible in a shade that draws its own small icon.
        val tag = if (primaryIsSat) "SAT" else null

        val text = listOfNotNull(
            tag,
            band,
            channel?.let { "${channelName(primary)} $it" },
            dbm?.let { "$it dBm" },
        ).joinToString(" · ")

        val detail = buildList {
            tag?.let { add(it) }
            identityOf(primary, nrBits)?.let { add(it) }
            listOfNotNull(band, channel?.let { "${channelName(primary)} $it" })
                .takeIf { it.isNotEmpty() }
                ?.let { add(it.joinToString(" · ")) }
            add(dbm?.let { "$it dBm" } ?: "No signal level reported yet")
            // The 5G leg of NSA is worth its own line: it is a different
            // carrier, often on a different band from the anchor.
            if (lte != null && nr != null) {
                add(
                    listOfNotNull(
                        "NR ${bandLabel(nr, false, corrections) ?: "carrier"}",
                        channelOf(nr, false)?.let { "ARFCN $it" },
                        (nr["dbm"] as? Int)?.let { "$it dBm" },
                    ).joinToString(" · "),
                )
            }
        }.joinToString("\n")

        val badge: String? = when {
            primaryIsSat -> "SAT"
            lteM && nr == null -> "LTE-M"
            else -> SignalIcon.labelFor(
                tech = primary.tech().ifEmpty { null },
                override = sim["overrideNetworkType"] as? String ?: "NONE",
                plmn = plmnOf(primary),
                // NR cell attached, or the platform's NR state connected
                // with no cell exposed: still 5G.
                nrAttached = nr != null || nrConnected(sim),
                aggregated = aggregated,
                fiveG = fiveG,
                highBand = highBandOf(nr),
            )
        }

        return Lines(
            title = "$carrier · $mode",
            text = text.ifEmpty { "Waiting for a cell reading…" },
            detail = detail,
            slotIndex = (sim["slotIndex"] as? Int) ?: 0,
            badge = badge,
        )
    }

    // ------------------------------------------------------------------
    // Choosing the SIM
    // ------------------------------------------------------------------

    /**
     * The SIM the notification describes: the default data subscription when
     * it has a served cell, otherwise the first SIM with one.
     *
     * Android marks the default *data* subscription in the snapshot, and a call
     * over the other slot normally makes that one the first with a cell, so a
     * call SIM takes over only when it is the one actually registered.
     */
    private fun pickSim(snapshot: Map<String, Any?>): Map<String, Any?>? {
        val sims = (snapshot["sims"] as? List<*>)
            ?.filterIsInstance<Map<String, Any?>>()
            .orEmpty()
        fun hasCell(sim: Map<String, Any?>) = (sim["cells"] as? List<*>)
            ?.filterIsInstance<Map<String, Any?>>()
            ?.any { it["registered"] == true } == true

        return sims.firstOrNull { it["isDefault"] == true && hasCell(it) }
            ?: sims.firstOrNull { hasCell(it) }
            ?: sims.firstOrNull { it["simState"] == "READY" }
            ?: sims.firstOrNull()
    }

    /**
     * Mode as the radio is actually running it.
     *
     * Derived from the cells this SIM has, not from `overrideNetworkType`: the
     * platform keeps advertising NSA after the NR leg drops, which would label
     * an LTE-only connection 5G.
     */
    private fun modeOf(
        sim: Map<String, Any?>,
        lte: Map<String, Any?>?,
        lteM: Boolean,
        nr: Map<String, Any?>?,
    ): String {
        if (nr != null) return if (lte != null) "5G NSA" else "5G SA"
        if (lte != null && nrConnected(sim)) return "5G NSA"
        if (lte != null) {
            // LTE-M is still an LTE radio, so only the label changes — and only
            // for networks the operator list tags.
            return if (lteM) "4G LTE-M" else "4G LTE"
        }
        return (sim["networkTypeName"] as? String)?.takeIf { it.isNotEmpty() } ?: "No service"
    }

    /** The platform's word on the NR leg, for a modem hiding the cell. */
    private fun nrConnected(sim: Map<String, Any?>): Boolean =
        sim["nrState"] == "CONNECTED"

    /**
     * True for a standalone NR leg on FR2 (millimetre wave).
     *
     * Samsung keeps reporting plain `NR_SA` there, so the override cannot tell
     * a 100 MHz C-band link from mmWave; the carrier's Advanced badge is still
     * what the network calls an mmWave link.
     */
    private fun highBandOf(cell: Map<String, Any?>?): Boolean {
        if (cell == null || cell.tech() != "NR") return false
        val arfcn = (cell["arfcn"] as? Number)?.toLong()
            ?: (cell["arfcn"] as? String)?.toLongOrNull()
        if (arfcn != null && arfcn >= 2016667) return true
        val bands = (cell["bands"] as? List<*>)
            ?.mapNotNull { (it as? Number)?.toInt() }
            .orEmpty() + listOfNotNull((cell["band"] as? Number)?.toInt())
        return bands.any { it in 257..262 }
    }

    private fun carrierOf(
        sim: Map<String, Any?>,
        primary: Map<String, Any?>,
        brands: Map<String, String>,
    ): String {
        val name = (sim["carrierName"] as? String)?.trim().orEmpty()
        val plmn = plmnOf(primary)
        // The network actually registered on decides the brand: the SIM's own
        // name is often an MVNO's, or "(Searching)" on a network with no card.
        if (plmn != null && plmn.length >= 5) {
            val withDash = "${plmn.take(3)}-${plmn.drop(3)}"
            brands[withDash]?.let { return it }
        }
        if (name.isNotEmpty() && !name.contains("Searching", ignoreCase = true)) return name
        if (plmn != null && plmn.length >= 5) return "${plmn.take(3)}-${plmn.drop(3)}"
        return name.ifEmpty { "SIM" }
    }

    private val _satellites = HashSet<String>()
    private val _lteMs = HashSet<String>()

    // ------------------------------------------------------------------
    // Cell fields
    // ------------------------------------------------------------------

    private fun Map<String, Any?>.tech(): String = this["type"] as? String ?: ""

    /** `310-830` and `310830` are the same network; tags are stored compact. */
    private fun compactPlmn(plmn: String?): String? =
        plmn?.replace("-", "")?.trim()?.takeIf { it.length >= 5 }

    private fun plmnOf(cell: Map<String, Any?>): String? {
        val mcc = cell["mcc"] as? String ?: return null
        val mnc = cell["mnc"] as? String ?: return null
        return "$mcc$mnc"
    }

    private fun channelName(cell: Map<String, Any?>): String =
        if (cell.tech() == "NR") "ARFCN" else "EARFCN"

    /**
     * LTE bands on the 3GPP EARFCN raster.
     *
     * Each band owns a disjoint channel range, so one lookup identifies the
     * band when the modem reports none — which this A10e frequently does.
     * Mirrors the ranges in `lib/models/cell_snapshot.dart`.
     */
    private val lteBandRanges: Map<Int, IntRange> = mapOf(
        1 to 0..599,
        2 to 600..1199,
        3 to 1200..1949,
        4 to 1950..2399,
        5 to 2400..2649,
        7 to 2750..3449,
        8 to 3450..3799,
        12 to 5010..5179,
        13 to 5180..5279,
        14 to 5280..5379,
        17 to 5730..5849,
        20 to 6150..6449,
        25 to 8040..8689,
        26 to 8690..9039,
        28 to 9210..9659,
        29 to 9660..9769,
        30 to 9770..9869,
        38 to 37750..38249,
        40 to 38650..39649,
        41 to 39650..41589,
        46 to 46790..54539,
        48 to 55240..56739,
        66 to 66436..67335,
        71 to 68586..68935,
        106 to B106_FIRST..B106_LAST,
    )

    /**
     * Band label, with the A10e re-code applied: PLMN 313-700's 900 MHz carrier
     * is **B106** in that network's numbering, whatever band number the modem
     * happens to name.
     */
    private fun bandLabel(
        cell: Map<String, Any?>,
        aliasB106: Boolean,
        corrections: Corrections,
    ): String? {
        val reported = reportedBand(cell)
        if (aliasB106 && cell.tech() == "LTE" && plmnOf(cell) == B106_PLMN) {
            if (reported == null || reported == 8 || reported == 106) return "B106"
        }
        // A band from the channel is a fallback, not a correction: it only runs
        // when the radio named none at all (or -1), so it always applies.
        val band = reported
            ?: (if (cell.tech() == "NR") inferredNrBand(cell) else inferredBand(cell))
            ?: return null
        return (if (cell.tech() == "NR") "n" else "B") +
            reconcileNrBand(cell, band, corrections)
    }

    /**
     * Bands T-Mobile runs where the modem can name the narrower band instead.
     *
     * NR's band is not signalled: the modem derives it from the NR-ARFCN, and
     * in each pair below the reported band's whole block sits inside the real
     * one's — n38 (514000–524999) inside n41 (499200–537999), n2
     * (386000–398999) inside n25 (386000–399999). T-Mobile deploys only the
     * wider band of each pair, so the label is corrected for their PLMNs; a
     * European n38 or an n2 on another carrier stays as reported.
     */
    private val tmobileNrRecodes = mapOf(
        38 to (41 to (499200..537999)),
        2 to (25 to (386000..399999)),
    )

    private fun reconcileNrBand(
        cell: Map<String, Any?>,
        band: Int,
        corrections: Corrections,
    ): Int {
        if (cell.tech() != "NR") return band
        // CBRS (3550–3700 MHz) is carved out of n77's 3300–4200 span, so the
        // modem naming the wider band is right about n77 and wrong about the
        // deployment. Frequency decides this one, for every network.
        if (corrections.cbrs && band == 77) {
            val mhz = nrMhz(cell)
            if (mhz != null && mhz >= 3550 && mhz < 3700) return 48
        }
        if (!corrections.tmobileBands) return band
        if (!tmobilePlmns.contains(plmnOf(cell))) return band
        val (actual, window) = tmobileNrRecodes[band] ?: return band
        val arfcn = cell["arfcn"] as? Int ?: return band
        return if (arfcn in window) actual else band
    }

    /** NR centre frequency in MHz, using the 3GPP global raster. */
    private fun nrMhz(cell: Map<String, Any?>): Double? {
        val channel = cell["arfcn"] as? Int ?: return null
        return when {
            channel <= 0 -> null
            channel < 600000 -> channel * 0.005
            channel <= 2016666 -> 3000.0 + (channel - 600000) * 0.015
            else -> 24250.08 + (channel - 2016667) * 0.06
        }
    }

    /**
     * The band number the modem named, ignoring `-1` (`BAND_UNKNOWN`).
     *
     * Some firmwares report -1 instead of the band, which would otherwise be
     * printed as `n-1`.
     */
    private fun reportedBand(cell: Map<String, Any?>): Int? =
        (cell["bands"] as? List<*>)
            ?.mapNotNull { it as? Int }
            ?.firstOrNull { it > 0 }

    /** NR bands on the global ARFCN raster; several overlap by design. */
    private val nrBandWindows = mapOf(
        1 to (422000..434000),
        2 to (386000..398999),
        3 to (361000..376000),
        5 to (173800..178799),
        7 to (524000..538999),
        8 to (185000..192999),
        12 to (145800..149199),
        13 to (149200..151199),
        14 to (151600..153599),
        20 to (158200..164199),
        25 to (386000..399999),
        26 to (171800..178799),
        28 to (151600..160599),
        30 to (470000..472999),
        38 to (514000..524999),
        41 to (499200..537999),
        48 to (710000..739999),
        66 to (422000..440000),
        70 to (399000..404000),
        71 to (123400..130400),
        77 to (660000..840000),
        78 to (660000..759999),
        79 to (880000..999999),
        260 to (2229167..2279166),
        261 to (2079167..2124166),
    )

    /**
     * NR band from the ARFCN, only when exactly one band owns that channel.
     *
     * Used when the modem names no band at all. An overlapping channel (n38
     * inside n41, n2 inside n25) has no single answer, so it stays unnamed
     * rather than guessing.
     */
    private fun inferredNrBand(cell: Map<String, Any?>): Int? {
        if (cell.tech() != "NR") return null
        val channel = cell["arfcn"] as? Int ?: return null
        var found: Int? = null
        for ((band, window) in nrBandWindows) {
            if (channel !in window) continue
            if (found != null) return null
            found = band
        }
        return found
    }

    /** LTE band whose channel block contains this cell's EARFCN. */
    private fun inferredBand(cell: Map<String, Any?>): Int? {
        if (cell.tech() != "LTE") return null
        val channel = cell["arfcn"] as? Int ?: return null
        return lteBandRanges.entries.firstOrNull { channel in it.value }?.key
    }

    /**
     * Channel number to show. On the A10e build the band-8 raster the modem
     * reports is re-expressed on band 106's (3580 → 134322), so the
     * notification agrees with the app instead of contradicting it.
     */
    private fun channelOf(cell: Map<String, Any?>, aliasB106: Boolean): Int? {
        val arfcn = cell["arfcn"] as? Int ?: return null
        if (!aliasB106 || cell.tech() != "LTE" || plmnOf(cell) != B106_PLMN) return arfcn
        if (arfcn in B106_FIRST..B106_LAST) return arfcn
        // Not on band 8's raster: nothing to re-express.
        if (arfcn !in 3450..3799) return arfcn
        val downlink = 925.0 + 0.1 * (arfcn - 3450)
        val moved = B106_FIRST + ((downlink - 935.0) * 10).roundToInt()
        return if (moved in B106_FIRST..B106_LAST) moved else arfcn
    }

    /**
     * Cell identity: eNB/sector for LTE, gNB/sector for NR, using the operator's
     * gNB ID length — the same split the app shows.
     */
    private fun identityOf(
        cell: Map<String, Any?>,
        nrBits: Map<String, Int> = emptyMap(),
    ): String? {
        val id = (cell["cellId"] as? String)?.toLongOrNull()
        if (id == null || id <= 0) {
            return (cell["pci"] as? Int)?.let { "PCI $it" }
        }
        return when (cell.tech()) {
            "LTE" -> "eNB ${id shr 8} · sector ${id and 0xFF}"
            "NR" -> {
                val plmn = plmnOf(cell)
                // The operator list's own `nrBits` wins, so the shade decodes
                // the NCI on the same split the card does.
                val tagged = nrBits[plmn ?: ""]
                    ?: nrBits[(plmn ?: "").let { "${it.take(3)}-${it.drop(3)}" }]
                val bits = when {
                    tagged != null && tagged in 10..30 -> tagged
                    attPlmns.contains(plmn) -> 26
                    tmobilePlmns.contains(plmn) -> 24
                    else -> 22
                }
                val sectorMask = (1L shl (36 - bits)) - 1
                "gNB ${id shr (36 - bits)} · sector ${id and sectorMask}"
            }
            else -> "CI $id"
        }
    }
}
