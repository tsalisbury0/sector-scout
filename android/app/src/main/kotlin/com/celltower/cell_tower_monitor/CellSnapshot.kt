package com.celltower.cell_tower_monitor

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.telephony.AccessNetworkConstants
import android.telephony.CarrierConfigManager
import android.telephony.CellIdentity
import android.telephony.CellIdentityCdma
import android.telephony.CellIdentityGsm
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellIdentityTdscdma
import android.telephony.CellIdentityWcdma
import android.telephony.CellInfo
import android.telephony.CellSignalStrength
import android.telephony.CellSignalStrengthCdma
import android.telephony.CellSignalStrengthGsm
import android.telephony.CellSignalStrengthLte
import android.telephony.CellSignalStrengthNr
import android.telephony.CellSignalStrengthWcdma
import android.telephony.NetworkRegistrationInfo
import android.telephony.ServiceState
import android.telephony.SignalStrength
import android.telephony.SubscriptionManager
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Reads the radio picture for every active SIM and turns it into a plain map
 * that Dart can decode.
 *
 * Two sources are used per SIM, because they answer different questions:
 *
 *  - `ServiceState` / `NetworkRegistrationInfo` is per-subscription and tells
 *    us which cell each SIM is actually camped on, plus its technology.
 *  - `TelephonyManager.getSignalStrength()` is per-subscription and gives that
 *    SIM's own level. This is how dual-SIM tools such as CellMapper and
 *    SignalCheck separate the slots.
 *  - `getAllCellInfo()` is the modem-wide neighbour scan; on many devices
 *    (Samsung/Qualcomm DSDS included) it returns the same list for every
 *    subscription, so it is only trusted for neighbours.
 */
object CellSnapshot {

    private const val TAG = "CellSnapshot"

    /** One active SIM slot, as reported by SubscriptionManager. */
    private data class SubInfo(
        val slotIndex: Int,
        val subscriptionId: Int,
        val carrierName: String,
        val isDefault: Boolean,
    )

    fun build(context: Context): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val baseTm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

        val hasLocation = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        out["permissionGranted"] = hasLocation
        out["locationEnabled"] = isLocationEnabled(context)
        out["timestamp"] = System.currentTimeMillis()
        out["deviceModel"] = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

        val subs = readSubscriptions(context, baseTm)
        val sims = subs.map { sub -> readSim(context, baseTm, sub, hasLocation) }
        out["sims"] = sims
        out["cellCount"] = sims.sumOf { (it["cells"] as? List<*>)?.size ?: 0 }

        val default = sims.firstOrNull { it["isDefault"] == true } ?: sims.firstOrNull()
        out["operatorName"] = default?.get("carrierName") ?: ""
        out["networkTypeName"] = default?.get("networkTypeName") ?: "Unknown"
        out["simState"] = default?.get("simState") ?: "UNKNOWN"
        // Whether the optional privileged reader is up, for the Settings row.
        out["carrierDetail"] = PrivilegedRadio.status(context)["state"]
        return out
    }

    // ---------------------------------------------------------------------
    // SIM enumeration
    // ---------------------------------------------------------------------

    private fun readSubscriptions(context: Context, baseTm: TelephonyManager?): List<SubInfo> {
        val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
        val infos = try {
            sm?.activeSubscriptionInfoList
        } catch (e: SecurityException) {
            Log.w(TAG, "Subscription list refused: ${e.message}")
            null
        } catch (e: Exception) {
            Log.w(TAG, "Subscription list failed: ${e.message}")
            null
        }

        if (!infos.isNullOrEmpty()) {
            val defaultData = safe { SubscriptionManager.getDefaultDataSubscriptionId() } ?: -1
            val subs = infos.sortedBy { it.simSlotIndex }.map { info ->
                val id = safe { info.subscriptionId } ?: -1
                SubInfo(
                    slotIndex = if (info.simSlotIndex >= 0) info.simSlotIndex else 0,
                    subscriptionId = id,
                    carrierName = safe { info.carrierName?.toString() }.orEmpty(),
                    isDefault = id == defaultData,
                )
            }
            if (subs.isNotEmpty()) return subs
        }

        // Single-SIM devices, or READ_PHONE_STATE denied: describe the one
        // implicit subscription instead of showing nothing.
        return listOf(
            SubInfo(
                slotIndex = 0,
                subscriptionId = -1,
                carrierName = safe { baseTm?.simOperatorName }.orEmpty(),
                isDefault = true,
            ),
        )
    }

    private fun readSim(
        context: Context,
        baseTm: TelephonyManager?,
        sub: SubInfo,
        hasLocation: Boolean,
    ): Map<String, Any?> {
        val m = LinkedHashMap<String, Any?>()
        val tm = if (sub.subscriptionId > 0) {
            safe { baseTm?.createForSubscriptionId(sub.subscriptionId) } ?: baseTm
        } else {
            baseTm
        }

        m["slotIndex"] = sub.slotIndex
        m["subscriptionId"] = sub.subscriptionId
        m["isDefault"] = sub.isDefault
        m["carrierName"] = sub.carrierName
        m["simState"] = simStateName(safe { tm?.simState } ?: TelephonyManager.SIM_STATE_UNKNOWN)
        m["networkTypeName"] = networkTypeName(
            safe { tm?.dataNetworkType } ?: TelephonyManager.NETWORK_TYPE_UNKNOWN,
        )
        // Voice side of the slot. Both are public API, so they answer without
        // Shizuku: the call state says whether a call is up, and the voice
        // network type says what is carrying it — LTE for VoLTE, NR for VoNR,
        // IWLAN for Wi-Fi calling. That is the only way to tell a VoLTE call
        // from a VoNR one, since the data network type stays on NSA either way.
        val callState = callStateName(
            safe { tm?.callState } ?: TelephonyManager.CALL_STATE_IDLE,
        )
        m["callState"] = callState
        // The network carrying voice, and there is only ever one: IWLAN while
        // Wi-Fi calling is registered, NR on a VoNR call, LTE for VoLTE. That
        // is what lets the page name the path in use instead of listing every
        // path the network could offer.
        val voiceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            safe { tm?.voiceNetworkType }
                ?.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN }
        } else {
            null
        }
        if (voiceType != null) m["voiceNetworkType"] = voiceType
        // The data side, for the one case the voice type cannot cover: a phone
        // registered for Wi-Fi calling but sitting idle reports IWLAN as its
        // *data* network type while the voice type still says LTE.
        val dataType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            safe { tm?.dataNetworkType }
                ?.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN }
        } else {
            null
        }
        // The privileged reading is fetched once here and reused below: it
        // carries both the component carriers and the IMS state.
        val privileged = PrivilegedRadio.detail(sub.subscriptionId)
        m["ims"] = imsAvailability(
            context = context,
            subId = sub.subscriptionId,
            callState = callState,
            voiceType = voiceType,
            dataType = dataType,
            detail = privileged,
        )

        val signalStrength = safe { tm?.signalStrength }
        val scanned = if (hasLocation && tm != null) readCells(tm) else emptyList()
        val override = if (sub.subscriptionId > 0) {
            RadioState.overrideFor(sub.subscriptionId)
        } else {
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE
        }

        // The network this SIM is actually on. Used to keep the other slot's
        // cells out of this slot's list: getAllCellInfo() is modem-wide, so it
        // happily reports a cell the other SIM is camped on as "registered".
        val ownPlmn = safe { tm?.networkOperator }?.takeIf { it.length >= 5 }
            ?: safe { tm?.simOperator }?.takeIf { it.length >= 5 }

        // Serving cells come from this subscription's own registration info...
        val serving = registeredCells(tm, signalStrength).toMutableList()
        // ...and anything registered in the scan that registration info missed
        // (notably the NR leg of NSA on some firmwares) is appended once — but
        // only when it is this SIM's own network, never the other slot's.
        for (cell in scanned) {
            // Identity first, before the network filter: a cell this SIM is
            // served by keeps its PCI and channel even while the scan still
            // tags it with the previous PLMN.
            val byIdentity = serving.firstOrNull {
                it["type"] == cell["type"] && ServingMerge.identityMatch(it, cell)
            }
            if (byIdentity != null) {
                fillMissing(byIdentity, cell)
                continue
            }
            if (!belongsTo(ownPlmn, cell)) continue
            // Registration info can be missing what the modem's own CellInfo
            // still carries — this A10e reports mEarfcn=2147483647 and an
            // empty band list in ServiceState while CellInfoLte keeps 3580 —
            // so fill those holes instead of throwing the scan's copy away.
            val match = serving.firstOrNull {
                it["type"] == cell["type"] && sameCell(it, cell)
            }
            if (match != null) {
                fillMissing(match, cell)
                continue
            }
            // A served cell can also arrive with too little identity to match
            // on at all — the band-lock case described in [ServingMerge].
            val thin = ServingMerge.thinMatch(serving, cell, scanned, ownPlmn)
            if (thin != null) {
                fillMissing(thin, cell)
                continue
            }
            if (cell["registered"] != true) continue
            if (serving.any { it["type"] == cell["type"] }) continue
            serving.add(cell)
        }
        // Samsung (and others) mark the NR leg as unregistered in the scan, and
        // some firmwares leave it out of getAllCellInfo() entirely. Adopt it
        // when the platform says 5G is active, or when the radio itself
        // publishes an NR carrier for this subscription.
        if (isNrOverride(override) && serving.none { it["type"] == "NR" }) {
            val nrCell = scanned.firstOrNull {
                it["type"] == "NR" && belongsTo(ownPlmn, it)
            }
            if (nrCell != null) {
                nrCell["registered"] = true
                serving.add(nrCell)
            }
        }
        // Channels the modem has stopped reporting are held per cell rather
        // than blanking the ARFCN and frequency rows.
        holdLastChannel(serving)

        val neighbours = scanned.filter { it["registered"] != true }

        val cells = serving + neighbours
        cells.forEach { cell -> cell["slotIndex"] = sub.slotIndex }
        m["cells"] = cells
        m["overrideNetworkType"] = overrideName(override)
        // The platform's own word on the NR leg. Modems that hide the NR
        // cell from getAllCellInfo() — Samsung on NZ networks, among
        // others — still answer here, which is what lets the badge claim
        // 5G with no cell to point at.
        val nrSignal = nrRsrp(tm)
        val nrState = nrStateText(tm, nrSignal)
        m["nrState"] = nrState
        // True when the NR leg is up by any evidence the platform gives:
        // the state says CONNECTED, or SignalStrength carries an NR part.
        // The second is public API, so it answers on firmware that
        // refuses the hidden state call.
        m["nrConnected"] = nrState == "CONNECTED" || nrSignal != null
        if (nrSignal != null) m["nrRsrp"] = nrSignal
        m["plmn"] = ownPlmn

        // Carrier detail, when Shizuku is lending its shell identity: one row
        // per aggregated carrier with its own width and technology. Empty
        // without it, and the card simply shows no such rows.
        if (privileged.carriers.isNotEmpty()) {
            m["carriers"] = CarrierDetail.toMaps(privileged)
        }

        if (BuildConfig.DEBUG) {
            Log.d(
                TAG,
                "slot=${sub.slotIndex} subId=${sub.subscriptionId} carrier=${sub.carrierName} " +
                    "override=${overrideName(override)} " +
                    "dataType=${safe { tm?.dataNetworkType }} " +
                    "strengths=${safe { signalStrength?.cellSignalStrengths?.map { it.javaClass.simpleName } }} " +
                    "serving=" + serving.joinToString { "${it["type"]}/${it["pci"]}/${it["bands"]}/${it["dbm"]}" } +
                    " scan=" + scanned.groupingBy { it["type"].toString() }.eachCount() +
                    " neighbours=${neighbours.size}",
            )
        }
        return m
    }

    // ---------------------------------------------------------------------
    // Serving cells: per-subscription ServiceState + SignalStrength
    // ---------------------------------------------------------------------

    private fun registeredCells(
        tm: TelephonyManager?,
        signalStrength: SignalStrength?,
    ): List<MutableMap<String, Any?>> {
        // NetworkRegistrationInfo is the only per-subscription identity API
        // left in recent SDKs (API 29+); older releases fall back to the modem
        // scan, which still carries its own registered flag.
        if (tm == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
        val state = safe { tm.serviceState } ?: return emptyList()
        val registrations = safe { state.networkRegistrationInfoList } ?: return emptyList()

        val identities = LinkedHashMap<String, CellIdentity>()
        for (reg in registrations) {
            if (safe { reg.transportType } != AccessNetworkConstants.TRANSPORT_TYPE_WWAN) continue
            val identity = safe { reg.cellIdentity } ?: continue
            identities.putIfAbsent(techKey(identity), identity)
        }

        return identities.mapNotNull { (tech, identity) ->
            val map = describeIdentity(identity, strengthFor(signalStrength, tech), registered = true)
                ?: return@mapNotNull null
            if (map["dbm"] == null) {
                val level = safe { signalStrength?.level }
                if (level != null) map["level"] = level
            }
            map
        }
    }

    // Matching, hole-filling and the last-known-channel hold live in
    // [ServingMerge], which needs nothing from the framework and is therefore
    // covered by unit tests. These keep the call sites below readable.
    private fun belongsTo(plmn: String?, cell: Map<String, Any?>) =
        ServingMerge.belongsTo(plmn, cell)

    private fun sameCell(a: Map<String, Any?>, b: Map<String, Any?>) =
        ServingMerge.sameCell(a, b)

    private fun fillMissing(target: MutableMap<String, Any?>, source: Map<String, Any?>) =
        ServingMerge.fillMissing(target, source)

    private fun holdLastChannel(serving: List<MutableMap<String, Any?>>) =
        ServingMerge.holdLastChannel(serving)

    /**
     * `TelephonyManager.getNrState()`: 0 none, 1 restricted, 2 not
     * restricted, 3 connected. A hidden API, so it is read reflectively
     * and an absence is simply an empty answer.
     */
    private fun nrStateOf(tm: TelephonyManager?): Int? {
        if (tm == null) return null
        // ServiceState is the object the state actually lives on; the
        // TelephonyManager call is a wrapper some firmware does not export.
        val state = safe { tm.serviceState }
        if (state != null) {
            val fromState = try {
                val method = state.javaClass.methods.firstOrNull { it.name == "getNrState" }
                method?.invoke(state) as? Int
            } catch (error: Exception) {
                null
            }
            if (fromState != null) return fromState
        }
        return try {
            val method = TelephonyManager::class.java.getMethod("getNrState")
            method.invoke(tm) as? Int
        } catch (error: Exception) {
            null
        }
    }

    /**
     * The NR component of the signal strength in dBm, when the modem reports one
     * without exposing an NR cell. `CellSignalStrengthNr` is public API, so this
     * still answers where the hidden NR state call is refused.
     */
    private fun nrRsrp(tm: TelephonyManager?): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val strength = safe { tm?.signalStrength } ?: return null
        val nr = safe { strength.cellSignalStrengths }
            ?.filterIsInstance<CellSignalStrengthNr>()
            ?.firstOrNull() ?: return null
        val rsrp = safe { nr.ssRsrp }
        // Int.MAX_VALUE is the framework's "not known" marker.
        return if (rsrp == null || rsrp == Int.MAX_VALUE) null else rsrp
    }

    /**
     * The NR state as text, from the hidden method where it answers and from
     * `ServiceState.toString()` where it does not.
     *
     * NetMonster (netmonster-core, `NrNsaStateParser`) established this route:
     * AOSP hides the state behind methods apps cannot call, but the fields are
     * printed by `ServiceState.toString()`, so they can be read out of it. The
     * printed `nrState` is masked to `****` from Android 12 on some firmware,
     * which is what `isNrAvailable` / `isEnDcAvailable` and an NR signal part
     * are there to cover.
     */
    private fun nrStateText(tm: TelephonyManager?, nrSignal: Int?): String {
        val numeric = nrStateOf(tm)
        if (numeric != null) return nrStateName(numeric)
        return nrStateFromServiceState(tm, nrSignal)
    }

    /** Field-by-field read of the `ServiceState` string, NetMonster style. */
    private fun nrStateFromServiceState(tm: TelephonyManager?, nrSignal: Int?): String {
        val text = safe { tm?.serviceState?.toString() } ?: return ""
        fun field(name: String): String? =
            Regex(Regex.escape(name) + """\s*=\s*([^,\s}]+)""")
                .find(text)
                ?.groupValues
                ?.get(1)
        fun flag(name: String): Boolean = field(name)?.equals("true", true) == true

        val raw = field("nrState")?.uppercase().orEmpty()
        // Huawei on Android P, LG on Android P: the same answer under other names.
        val huaweiConnected = field("nsaState")?.toIntOrNull() == 5
        val lgConnected = flag("EnDc") && flag("5G Allocated")
        val nsaState = field("nsaState")?.toIntOrNull()
        val available = flag("isNrAvailable") || flag("isEnDcAvailable") ||
            (nsaState != null && nsaState in 2..4)
        val restricted = flag("isDcNrRestricted")

        return when {
            huaweiConnected || lgConnected -> "CONNECTED"
            raw.contains("CONNECTED") -> "CONNECTED"
            raw.contains("NOT_RESTRICTED") -> "NOT_RESTRICTED"
            raw.contains("RESTRICTED") || restricted -> "RESTRICTED"
            raw.contains("NONE") -> "NONE"
            // Android 12+ masks nrState: an NR signal part is then the only
            // proof the leg is actually carrying anything.
            available && nrSignal != null -> "CONNECTED"
            available -> "AVAILABLE"
            raw.contains("***") -> "MASKED"
            else -> ""
        }
    }

    private fun nrStateName(value: Int?): String = when (value) {
        0 -> "NONE"
        1 -> "RESTRICTED"
        2 -> "NOT_RESTRICTED"
        3 -> "CONNECTED"
        else -> ""
    }

    /** True when the platform is advertising any active 5G link. */
    private fun isNrOverride(value: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return value == TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA ||
            value == TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE ||
            value == TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED
    }

    private fun overrideName(value: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "NONE"
        return when (value) {
            // "5G+" on AOSP: NR is active, SA vs NSA is decided by the legs.
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED -> "NR_ADVANCED"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA -> "NR_NSA"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE -> "NR_NSA_MMWAVE"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA -> "LTE_CA"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_ADVANCED_PRO -> "LTE_ADVANCED_PRO"
            else -> "NONE"
        }
    }

    private fun strengthFor(strength: SignalStrength?, tech: String): CellSignalStrength? {
        if (strength == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val all = safe { strength.cellSignalStrengths } ?: return null
        return when (tech) {
            "NR" -> all.filterIsInstance<CellSignalStrengthNr>().firstOrNull()
            "LTE" -> all.filterIsInstance<CellSignalStrengthLte>().firstOrNull()
            "WCDMA" -> all.filterIsInstance<CellSignalStrengthWcdma>().firstOrNull()
            "GSM" -> all.filterIsInstance<CellSignalStrengthGsm>().firstOrNull()
            "CDMA" -> all.filterIsInstance<CellSignalStrengthCdma>().firstOrNull()
            else -> null
        } ?: all.firstOrNull()
    }

    // ---------------------------------------------------------------------
    // Cell list from the modem-wide scan (neighbours)
    // ---------------------------------------------------------------------

    private fun readCells(tm: TelephonyManager): List<MutableMap<String, Any?>> {
        val infos = try {
            tm.allCellInfo
        } catch (e: SecurityException) {
            Log.w(TAG, "allCellInfo refused: ${e.message}")
            null
        } catch (e: Exception) {
            Log.w(TAG, "allCellInfo failed: ${e.message}")
            null
        } ?: return emptyList()

        return infos.mapNotNull { info ->
            try {
                describeIdentity(info.cellIdentity, info.cellSignalStrength, info.isRegistered)
            } catch (e: Exception) {
                Log.w(TAG, "Skipping unreadable cell: ${e.message}")
                null
            }
        }.sortedWith(compareByDescending { it["dbm"] as? Int ?: Int.MIN_VALUE })
    }

    // ---------------------------------------------------------------------
    // Identity → map
    // ---------------------------------------------------------------------

    // CellIdentityNr only exists from API 29, so the type check is guarded:
    // resolving the class on an older device would throw.
    private fun techKey(id: CellIdentity): String = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && id is CellIdentityNr -> "NR"
        // Android does not expose LTE-M as a distinct technology: an eMTC
        // carrier reports as plain LTE, with no mode getter on CellIdentityLte.
        // The operator list tags it instead (see CarrierBrands / CarrierNames).
        id is CellIdentityLte -> "LTE"
        id is CellIdentityWcdma -> "WCDMA"
        id is CellIdentityGsm -> "GSM"
        id is CellIdentityCdma -> "CDMA"
        id is CellIdentityTdscdma -> "TDSCDMA"
        else -> "UNKNOWN"
    }

    private fun describeIdentity(
        id: CellIdentity,
        signal: CellSignalStrength?,
        registered: Boolean,
    ): MutableMap<String, Any?>? {
        val m = LinkedHashMap<String, Any?>()
        m["registered"] = registered
        m["bands"] = emptyList<Int>()

        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && id is CellIdentityNr -> {
                m["type"] = "NR"
                m["cellId"] = id.nci.orNull()?.toString()
                m["tac"] = id.tac.orNull()
                m["pci"] = id.pci.orNull()
                m["mcc"] = id.mccString
                m["mnc"] = id.mncString
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    m["arfcn"] = id.nrarfcn.orNull()
                    m["bands"] = id.bands?.toList() ?: emptyList<Int>()
                }
                val ss = signal as? CellSignalStrengthNr
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["rsrp"] = ss.ssRsrp.orNull()
                    m["rsrq"] = ss.ssRsrq.orNull()
                    m["sinr"] = ss.ssSinr.orNull()
                }
            }

            id is CellIdentityLte -> {
                m["type"] = "LTE"
                m["cellId"] = id.ci.orNull()?.toString()
                m["tac"] = id.tac.orNull()
                m["pci"] = id.pci.orNull()
                m["mcc"] = id.mccString
                m["mnc"] = id.mncString
                m["arfcn"] = id.earfcn.orNull()
                // getBands() arrived in API 28; reading it there is what makes
                // the downlink/uplink rows work on Android 9 devices.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    m["bands"] = id.bands?.toList() ?: emptyList<Int>()
                }
                val ss = signal as? CellSignalStrengthLte
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["rsrp"] = ss.rsrp.orNull()
                    m["rsrq"] = ss.rsrq.orNull()
                    m["sinr"] = ss.rssnr.orNull()
                    m["timingAdvance"] = ss.timingAdvance.orNull()
                }
            }

            id is CellIdentityWcdma -> {
                m["type"] = "WCDMA"
                m["cellId"] = id.cid.orNull()?.toString()
                m["tac"] = id.lac.orNull()
                m["pci"] = id.psc.orNull()
                m["mcc"] = id.mccString
                m["mnc"] = id.mncString
                m["arfcn"] = id.uarfcn.orNull()
                val ss = signal as? CellSignalStrengthWcdma
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["asu"] = ss.asuLevel
                }
            }

            id is CellIdentityGsm -> {
                m["type"] = "GSM"
                m["cellId"] = id.cid.orNull()?.toString()
                m["tac"] = id.lac.orNull()
                m["pci"] = id.bsic.orNull()
                m["mcc"] = id.mccString
                m["mnc"] = id.mncString
                m["arfcn"] = id.arfcn.orNull()
                val ss = signal as? CellSignalStrengthGsm
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["asu"] = ss.asuLevel
                }
            }

            id is CellIdentityCdma -> {
                m["type"] = "CDMA"
                m["cellId"] = id.basestationId.orNull()?.toString()
                m["tac"] = id.networkId.orNull()
                m["pci"] = id.systemId.orNull()
                val ss = signal as? CellSignalStrengthCdma
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["asu"] = ss.asuLevel
                }
            }

            id is CellIdentityTdscdma -> {
                m["type"] = "TDSCDMA"
                m["cellId"] = id.cid.orNull()?.toString()
                m["tac"] = id.lac.orNull()
                m["pci"] = id.cpid.orNull()
                m["mcc"] = id.mccString
                m["mnc"] = id.mncString
                val ss = signal
                if (ss != null) {
                    m["dbm"] = ss.dbm.orNull()
                    m["level"] = ss.level
                    m["asu"] = ss.asuLevel
                }
            }

            else -> return null
        }

        return m
    }

    /** TelephonyManager reports unavailable values as Integer.MAX_VALUE / -1. */
    private fun Int.orNull(): Int? = if (this == Int.MAX_VALUE || this == -1) null else this

    /** NR identities use 64-bit values, with Long.MAX_VALUE meaning unavailable. */
    private fun Long.orNull(): Long? =
        if (this == Long.MAX_VALUE || this == Int.MAX_VALUE.toLong() || this <= 0) null else this

    private fun isLocationEnabled(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lm.isLocationEnabled
            } else {
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        } catch (e: Exception) {
            false
        }
    }

    fun networkTypeName(type: Int): String = when (type) {
        TelephonyManager.NETWORK_TYPE_NR -> "5G NR"
        TelephonyManager.NETWORK_TYPE_LTE -> "4G LTE"
        TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_HSPA,
        TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
        TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_EVDO_0,
        TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B,
        TelephonyManager.NETWORK_TYPE_EHRPD, TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3G"
        TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_GPRS,
        TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT,
        TelephonyManager.NETWORK_TYPE_GSM -> "2G"
        TelephonyManager.NETWORK_TYPE_IWLAN -> "Wi-Fi calling"
        else -> "Unknown"
    }

    private fun simStateName(state: Int): String = when (state) {
        TelephonyManager.SIM_STATE_ABSENT -> "ABSENT"
        TelephonyManager.SIM_STATE_PIN_REQUIRED -> "PIN_REQUIRED"
        TelephonyManager.SIM_STATE_PUK_REQUIRED -> "PUK_REQUIRED"
        TelephonyManager.SIM_STATE_NETWORK_LOCKED -> "NETWORK_LOCKED"
        TelephonyManager.SIM_STATE_READY -> "READY"
        TelephonyManager.SIM_STATE_NOT_READY -> "NOT_READY"
        TelephonyManager.SIM_STATE_PERM_DISABLED -> "PERM_DISABLED"
        TelephonyManager.SIM_STATE_CARD_IO_ERROR -> "CARD_IO_ERROR"
        TelephonyManager.SIM_STATE_CARD_RESTRICTED -> "CARD_RESTRICTED"
        else -> "UNKNOWN"
    }

    private fun callStateName(state: Int): String = when (state) {
        TelephonyManager.CALL_STATE_RINGING -> "ringing"
        TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
        else -> "idle"
    }

    /**
     * VoLTE, VoNR and Wi-Fi calling, as the carrier bundle says they are
     * available.
     *
     * These are the same `carrier_*_available_bool` flags the Settings app
     * reads to decide whether to offer its switches for them, so they describe
     * the network's capability rather than the current call: a phone that
     * offers both VoLTE and Wi-Fi calling reports both, and neither cancels the
     * other out. Every key is optional and differs per carrier bundle, so a
     * missing one answers false instead of being guessed, and `known` says
     * whether the config answered at all — a phone that will not hand it over
     * shows nothing rather than claiming all three are off.
     *
     * `active` is the exclusive part, taken from the voice network type, and is
     * the only one the page displays beside the mode.
     */
    private fun imsAvailability(
        context: Context,
        subId: Int,
        callState: String,
        voiceType: Int?,
        dataType: Int?,
        detail: CarrierDetail,
    ): Map<String, Any?> {
        // Wi-Fi calling is invisible to the public API while no call is up: the
        // voice network type only answers IWLAN once a call is already running
        // over it, so a registered Wi-Fi calling link looked like nothing at
        // all until the first call. IMS answers, and only the shell identity
        // can ask it.
        //
        // Two ways to know it is up. IMS answers directly when voice is
        // registered over WLAN. When it says nothing — mid-handover, or a
        // firmware that keeps the capability private — the user's switch plus
        // an IWLAN data registration means the ePDG tunnel is carrying the IMS
        // link, which is what that registration *is*. The switch is required:
        // IWLAN on its own fires on plain Wi-Fi and is the false positive every
        // other app shows as "Wi-Fi calling".
        val vowifiRegistered = detail.ims?.vowifiAvailable == true ||
            (detail.ims?.wfcSetting == true && dataType == TelephonyManager.NETWORK_TYPE_IWLAN)
        // The exclusive half of the answer. A phone registers one voice path at
        // a time, so this can only ever name one.
        val active = when {
            vowifiRegistered -> "vowifi"
            voiceType == TelephonyManager.NETWORK_TYPE_IWLAN -> "vowifi"
            voiceType == TelephonyManager.NETWORK_TYPE_NR -> "vonr"
            voiceType == TelephonyManager.NETWORK_TYPE_LTE -> "volte"
            voiceType == null -> null
            // Anything older only carries a call, never sits idle.
            callState == "idle" -> null
            else -> "cs"
        }

        val configs =
            context.getSystemService(Context.CARRIER_CONFIG_SERVICE) as? CarrierConfigManager
        val bundle = try {
            when {
                configs == null -> null
                subId > 0 -> configs.getConfigForSubId(subId)
                else -> configs.config
            }
        } catch (t: Throwable) {
            Log.w(TAG, "carrier config unavailable: ${t.message}")
            null
        }
        if (bundle == null) return mapOf("known" to false, "active" to active)
        fun flag(key: String): Boolean = try {
            bundle.getBoolean(key, false)
        } catch (t: Throwable) {
            false
        }
        return mapOf(
            "known" to true,
            "active" to active,
            "volte" to flag(CarrierConfigManager.KEY_CARRIER_VOLTE_AVAILABLE_BOOL),
            // Written out rather than referenced: the constant arrived in a much
            // later SDK than this build's minSdk, and the key itself has been
            // there since VoNR existed.
            "vonr" to flag("carrier_vonr_available_bool"),
            "vowifi" to (vowifiRegistered ||
                flag(CarrierConfigManager.KEY_CARRIER_WFC_IMS_AVAILABLE_BOOL)),
        )
    }

    private inline fun <T> safe(block: () -> T): T? = try {
        block()
    } catch (e: Exception) {
        Log.w(TAG, "Telephony call failed: ${e.message}")
        null
    }
}
