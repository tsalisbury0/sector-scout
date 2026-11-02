package com.celltower.cell_tower_monitor

/**
 * Cell-list bookkeeping that needs nothing from the Android framework: pairing
 * a modem-scan reading with the cell the subscription is served by, filling the
 * holes registration leaves, and holding a channel the modem has stopped
 * reporting.
 *
 * Kept out of [CellSnapshot] so these rules can be exercised directly: the
 * situations they exist for (a band-lock change stripping `mEarfcn`, or PCI and
 * CI along with it) cannot be produced on demand on a live handset.
 */
object ServingMerge {

    /** Fields a scan reading can donate when the registration copy lacks them. */
    private val FILLABLE_KEYS = listOf(
        "cellId", "tac", "pci", "mcc", "mnc", "arfcn",
        "dbm", "level", "rsrp", "rsrq", "sinr", "asu", "timingAdvance",
    )

    // ------------------------------------------------------------------
    // Matching
    // ------------------------------------------------------------------

    /** True when a reading carries both halves of a cell's identity. */
    fun hasIdentity(cell: Map<String, Any?>): Boolean =
        cell["pci"] != null && cell["cellId"] != null

    /**
     * True when two readings describe the same cell.
     *
     * PCI identifies a cell within one network, so it decides when both sides
     * know it; otherwise the CI is compared.
     */
    fun sameCell(a: Map<String, Any?>, b: Map<String, Any?>): Boolean {
        val pciA = a["pci"] as? Int
        val pciB = b["pci"] as? Int
        if (pciA != null && pciB != null) return pciA == pciB
        val idA = a["cellId"] as? String
        return idA != null && idA == b["cellId"]
    }

    /**
     * True when two readings are the same cell, using the strongest identity
     * both sides offer: the CI when both know it, otherwise the PCI.
     *
     * This is deliberately independent of the network code. Right after a PLMN
     * switch the scan's copy can still carry the previous code while holding
     * the PCI the served cell is missing, and a match refused on the PLMN is a
     * PCI that drops off the card. A bare PCI match still has to survive
     * [compatible], so the other slot's cell on the same PCI is never borrowed.
     */
    fun identityMatch(a: Map<String, Any?>, b: Map<String, Any?>): Boolean {
        val ciA = a["cellId"] as? String
        val ciB = b["cellId"] as? String
        if (ciA != null && ciB != null && ciA == ciB) return true

        val pciA = a["pci"] as? Int
        val pciB = b["pci"] as? Int
        if (pciA == null || pciB == null || pciA != pciB) return false
        return compatible(a, b)
    }

    /**
     * True when nothing the two readings both know contradicts.
     *
     * Checked before two readings are treated as one cell, so a thin identity
     * is only completed from a scan reading that agrees on everything it does
     * know — never from some other cell's data.
     */
    fun compatible(a: Map<String, Any?>, b: Map<String, Any?>): Boolean {
        for (key in listOf("cellId", "pci", "mcc", "mnc")) {
            val left = a[key]
            val right = b[key]
            if (left != null && right != null && left != right) return false
        }
        return true
    }

    /**
     * True when a scanned cell belongs to [plmn] — this subscription's own
     * network.
     *
     * Unknown PLMNs are let through: a firmware that withholds them still gets
     * the old behaviour rather than an empty card.
     */
    fun belongsTo(plmn: String?, cell: Map<String, Any?>): Boolean {
        if (plmn == null) return true
        val mcc = cell["mcc"] as? String ?: return true
        val mnc = cell["mnc"] as? String ?: return true
        val cellPlmn = "$mcc$mnc"
        // MNC may be 2 or 3 digits, so compare as prefixes both ways.
        return plmn.startsWith(cellPlmn) || cellPlmn.startsWith(plmn)
    }

    /**
     * The served cell a scan reading completes when neither PCI nor CI can
     * identify it, or null when that match would be a guess.
     *
     * Right after this A10e's band lock changes, the registration copy keeps the
     * network but loses PCI and CI while the modem scan still knows the real
     * cell. [sameCell] then cannot pair them, and the scan's copy — channel and
     * all — used to be thrown away. Two conditions make the pairing safe: only
     * one served cell of that technology is this thin, and the scan knows only
     * one registered cell of it on this network.
     */
    fun thinMatch(
        serving: List<MutableMap<String, Any?>>,
        cell: MutableMap<String, Any?>,
        scanned: List<MutableMap<String, Any?>>,
        ownPlmn: String?,
    ): MutableMap<String, Any?>? {
        if (cell["registered"] != true) return null
        val thin = serving.filter {
            it["type"] == cell["type"] && !hasIdentity(it) && compatible(it, cell)
        }
        if (thin.size != 1) return null
        val candidates = scanned.count {
            it["type"] == cell["type"] && it["registered"] == true && belongsTo(ownPlmn, it)
        }
        return if (candidates == 1) thin.single() else null
    }

    /**
     * Fills the holes in [target] from [source], which describes the same cell.
     *
     * Registration info is authoritative for identity and level, but some
     * firmwares strip the channel number from it. Anything the scan knows and
     * the registration copy does not is adopted, so a served cell keeps its
     * band and frequencies even while it is out of service.
     */
    fun fillMissing(target: MutableMap<String, Any?>, source: Map<String, Any?>) {
        for (key in FILLABLE_KEYS) {
            if (target[key] != null) continue
            val value = source[key] ?: continue
            target[key] = value
        }
        val bands = target["bands"] as? List<*>
        if (bands.isNullOrEmpty()) {
            val fromScan = source["bands"] as? List<*>
            if (!fromScan.isNullOrEmpty()) target["bands"] = fromScan
        }
    }

    // ------------------------------------------------------------------
    // Last known channel
    // ------------------------------------------------------------------

    /** How long a remembered channel stays usable, and how many cells to keep. */
    private const val HOLD_MAX_AGE_MS = 15 * 60 * 1000L
    private const val HOLD_MAX_CELLS = 32

    /** One cell's last reported channel and band list. */
    private data class HeldChannel(val arfcn: Int, val bands: List<Int>, val at: Long)

    private val heldChannels = LinkedHashMap<String, HeldChannel>()

    /**
     * Last PCI seen for a cell, filed by its CI.
     *
     * A cell's PCI is fixed for as long as its CI is, and the modem sometimes
     * stops reporting it — most visibly while a PLMN switch is in progress,
     * where the card would otherwise lose its PCI for a few seconds.
     */
    private val heldPcis = HashMap<String, Pair<Int, Long>>()

    /**
     * Keeps the channel and band list a served cell last reported, so a reading
     * that arrives without them does not blank the ARFCN and frequency rows.
     *
     * This A10e drops `mEarfcn` from both sources for a while after its band
     * lock changes — the number comes back a minute later, or after an
     * airplane-mode cycle — while the same cell stays served throughout. The
     * hold is per cell, so a different PCI/CI or a different network starts its
     * own entry instead of inheriting this one, and a reading that does report
     * a channel always replaces what was remembered.
     */
    fun holdLastChannel(serving: List<MutableMap<String, Any?>>, now: Long = System.currentTimeMillis()) {
        for (cell in serving) {
            val key = heldKey(cell) ?: continue
            val arfcn = cell["arfcn"] as? Int
            if (arfcn != null && arfcn > 0) {
                val bands = (cell["bands"] as? List<*>)?.filterIsInstance<Int>() ?: emptyList()
                heldChannels[key] = HeldChannel(arfcn, bands, now)
                continue
            }
            val held = heldChannels[key] ?: continue
            if (now - held.at > HOLD_MAX_AGE_MS) {
                heldChannels.remove(key)
                continue
            }
            cell["arfcn"] = held.arfcn
            if ((cell["bands"] as? List<*>)?.isEmpty() != false && held.bands.isNotEmpty()) {
                cell["bands"] = held.bands
            }
            // Shown as the last channel the radio reported, not a fresh read.
            cell["heldChannel"] = true
        }
        holdPcis(serving, now)
        while (heldChannels.size > HOLD_MAX_CELLS) {
            val oldest = heldChannels.entries.minByOrNull { it.value.at } ?: break
            heldChannels.remove(oldest.key)
        }
    }

    /** Remembers each cell's PCI, and restores it when a reading omits it. */
    private fun holdPcis(serving: List<MutableMap<String, Any?>>, now: Long) {
        for (cell in serving) {
            val tech = cell["type"] as? String ?: continue
            val ci = cell["cellId"] as? String ?: continue
            val key = "$tech|$ci"
            val pci = cell["pci"] as? Int
            if (pci != null && pci > 0) {
                heldPcis[key] = pci to now
                continue
            }
            val memo = heldPcis[key] ?: continue
            if (now - memo.second > HOLD_MAX_AGE_MS) {
                heldPcis.remove(key)
                continue
            }
            cell["pci"] = memo.first
        }
        if (heldPcis.size > HOLD_MAX_CELLS * 2) {
            heldPcis.entries.removeAll { now - it.value.second > HOLD_MAX_AGE_MS }
        }
    }

    /** Identity a remembered channel is filed under: one cell of one network. */
    fun heldKey(cell: Map<String, Any?>): String? {
        val tech = cell["type"] as? String ?: return null
        val mcc = cell["mcc"] as? String ?: return null
        val mnc = cell["mnc"] as? String ?: return null
        val id = (cell["cellId"] as? String) ?: cell["pci"]?.toString() ?: return null
        return "$tech|$mcc$mnc|$id"
    }

    /** Drops what has been remembered; used between tests. */
    fun forgetHeldChannels() {
        heldChannels.clear()
        heldPcis.clear()
    }
}
