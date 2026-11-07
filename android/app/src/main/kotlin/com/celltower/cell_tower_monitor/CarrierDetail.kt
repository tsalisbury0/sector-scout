package com.celltower.cell_tower_monitor

import org.json.JSONArray
import org.json.JSONObject

/**
 * One component carrier the modem is currently aggregating.
 *
 * This is the reading the platform keeps to itself: `CellIdentity` reports a
 * band list per cell, but the *width* of each carrier and which carriers are
 * running together at this moment only exist in `PhysicalChannelConfig`, which
 * needs `MODIFY_PHONE_STATE` to read.
 */
data class RadioCarrier(
    /** 3GPP band, or 0 when the modem did not name one. */
    val band: Int,
    /** Downlink width in kHz, exactly as the framework reports it. */
    val bandwidthKhz: Int,
    /** `TelephonyManager.NETWORK_TYPE_*` of this carrier — NR is 20. */
    val networkType: Int,
    /** Physical cell ID, or null when the framework reports it unknown. */
    val pci: Int?,
)

/**
 * IMS voice availability, as IMS itself reports it.
 *
 * Null means the question could not be asked, which is different from false.
 * A Wi-Fi calling registration is invisible to the public API while no call is
 * up, so this is the only source that can name VoWiFi before the first call.
 */
data class ImsState(
    /** Voice is available over WLAN: Wi-Fi calling is registered. */
    val vowifiAvailable: Boolean?,
    /** Voice is available over the cellular link: VoLTE or VoNR. */
    val volteAvailable: Boolean?,
    /** The user's Wi-Fi calling switch, or null when it could not be read. */
    val wfcSetting: Boolean? = null,
)

/**
 * What the privileged reader returned for one subscription.
 *
 * Nothing here needs the Android framework: [parse] takes the JSON the user
 * service produced, so the wire format and the totals can be tested on the JVM
 * — the situation they describe (a modem running four aggregated carriers)
 * cannot be produced on demand.
 */
data class CarrierDetail(
    val carriers: List<RadioCarrier>,
    /** IMS voice state, or null when the reader could not ask. */
    val ims: ImsState? = null,
) {

    /** Aggregate downlink width across every component carrier. */
    val totalBandwidthKhz: Int get() = carriers.sumOf { it.bandwidthKhz }

    val isEmpty: Boolean get() = carriers.isEmpty()

    /** Carriers on NR, as opposed to the LTE anchor and any LTE layers. */
    val nrCarriers: List<RadioCarrier> get() = carriers.filter { it.networkType == NR }

    companion object {

        /** `TelephonyManager.NETWORK_TYPE_NR`, spelled out so this stays framework-free. */
        const val NR = 20

        val EMPTY = CarrierDetail(emptyList())

        /**
         * Decodes the user service's JSON.
         *
         * A carrier with no width is dropped: `PhysicalChannelConfig` reports
         * 0 kHz for a carrier the modem has not measured yet, and a row saying
         * `B2 0 MHz` is worse than no row. An unreadable payload is simply
         * empty — the app falls back to its public-API reading.
         */
        fun parse(json: String?): CarrierDetail {
            if (json.isNullOrBlank()) return EMPTY
            return try {
                val root = JSONObject(json)
                val raw = root.optJSONArray("carriers") ?: JSONArray()
                val carriers = (0 until raw.length()).mapNotNull { index ->
                    val item = raw.optJSONObject(index) ?: return@mapNotNull null
                    val bandwidth = item.optInt("bw", 0)
                    if (bandwidth <= 0) return@mapNotNull null
                    val pci = if (item.isNull("pci")) null else item.optInt("pci", -1)
                    RadioCarrier(
                        band = item.optInt("band", 0),
                        bandwidthKhz = bandwidth,
                        networkType = item.optInt("net", 0),
                        pci = pci?.takeIf { it >= 0 },
                    )
                }
                val ims = root.optJSONObject("ims")?.let { state ->
                    fun flag(key: String): Boolean? =
                        if (state.isNull(key)) null else state.optBoolean(key)
                    ImsState(
                        vowifiAvailable = flag("vowifi"),
                        volteAvailable = flag("volte"),
                        wfcSetting = flag("wfc"),
                    )
                }
                CarrierDetail(carriers, ims)
            } catch (error: Exception) {
                EMPTY
            }
        }

        /** The shape [CellSnapshot] hands to Dart, one map per carrier. */
        fun toMaps(detail: CarrierDetail): List<Map<String, Any?>> = detail.carriers.map { carrier ->
            linkedMapOf<String, Any?>(
                "band" to carrier.band,
                "bw" to carrier.bandwidthKhz,
                "net" to carrier.networkType,
                "pci" to carrier.pci,
            )
        }
    }
}
