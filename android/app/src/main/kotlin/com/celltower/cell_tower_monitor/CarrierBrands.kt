package com.celltower.cell_tower_monitor

import android.content.Context
import org.json.JSONObject

/**
 * PLMN → brand for the pinned notification.
 *
 * The list belongs to the user: `lib/services/carrier_names.dart` fetches it
 * from their GitHub file and hands it over the method channel. This stores the
 * last copy on the device, because the notification keeps running with the app
 * closed and must still name a network.
 *
 * There is deliberately no built-in table: when nothing has been fetched yet the
 * notification falls back to the SIM's own name, then to the raw PLMN.
 */
object CarrierBrands {

    private const val PREFS = "signal_status"
    private const val KEY_TABLE = "carrier_names"
    private const val KEY_BOOSTS = "carrier_boosts"
    private const val KEY_SATELLITES = "carrier_satellites"
    private const val KEY_LTE_MS = "carrier_lte_ms"
    private const val KEY_FIVE_G = "carrier_five_g"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The last table the app sent, empty when it has never sent one. */
    fun table(context: Context): Map<String, String> = stored(context)

    /** Stores the table the app loaded. An empty argument changes nothing. */
    fun save(context: Context, raw: Map<*, *>?) {
        if (raw.isNullOrEmpty()) return
        val json = JSONObject()
        for ((key, value) in raw) {
            val plmn = key?.toString() ?: continue
            val brand = value?.toString()?.trim() ?: continue
            if (plmn.isEmpty() || brand.isEmpty()) continue
            json.put(plmn, brand)
        }
        if (json.length() == 0) return
        prefs(context).edit().putString(KEY_TABLE, json.toString()).commit()
    }

    /**
     * The per-PLMN satellite bars offset, stored beside the names.
     *
     * Cached for the same reason the names are: a phone that starts with no
     * network must still count a satellite link's bars the way the list says.
     */
    fun saveBoosts(context: Context, raw: Map<*, *>?) {
        if (raw.isNullOrEmpty()) return
        val json = JSONObject()
        for ((key, value) in raw) {
            val plmn = key?.toString() ?: continue
            val boost = (value as? Number)?.toDouble()
                ?: value?.toString()?.toDoubleOrNull()
            if (plmn.isEmpty() || boost == null || boost == 0.0) continue
            json.put(plmn, boost)
        }
        if (json.length() == 0) return
        prefs(context).edit().putString(KEY_BOOSTS, json.toString()).commit()
    }

    /** The stored offsets, empty when the list has never carried any. */
    fun storedBoosts(context: Context): Map<String, Double> {
        val raw = prefs(context).getString(KEY_BOOSTS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            buildMap {
                for (key in json.keys()) {
                    val boost = json.optDouble(key, 0.0)
                    if (boost > 0) put(key, boost)
                }
            }
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /**
     * Stores a set of PLMN tags — the list's `satellite` / `lteM` entries.
     *
     * Cached beside the names for the same reason: the notification draws
     * itself with the app closed, so a phone that never fetched the file still
     * marks `SAT` and **LTE-M** the way the list does.
     */
    fun saveTags(context: Context, key: String, plmns: Collection<String>?) {
        if (plmns == null) return
        val cleaned = plmns.mapNotNull { it.trim().takeIf { plmn -> plmn.isNotEmpty() } }
        prefs(context).edit().putString(key, cleaned.joinToString(",")).commit()
    }

    /** The stored tags under [key]; empty when nothing has been saved yet. */
    fun storedTags(context: Context, key: String): Set<String> {
        val raw = prefs(context).getString(key, null) ?: return emptySet()
        return raw.split(',').mapNotNull { it.trim().takeIf { plmn -> plmn.isNotEmpty() } }
            .toSet()
    }

    /** The stored `satellite` PLMNs. */
    fun storedSatellites(context: Context): Set<String> = storedTags(context, KEY_SATELLITES)

    /** The stored `lteM` PLMNs. */
    fun storedLteMs(context: Context): Set<String> = storedTags(context, KEY_LTE_MS)

    /** Persists the `satellite` PLMNs. */
    fun saveSatellites(context: Context, plmns: Collection<String>?) =
        saveTags(context, KEY_SATELLITES, plmns)

    /** Persists the `lteM` PLMNs. */
    fun saveLteMs(context: Context, plmns: Collection<String>?) =
        saveTags(context, KEY_LTE_MS, plmns)

    /**
     * Stores the list's `fiveG` labels — the badge each network draws for NR
     * Advanced.
     *
     * Cached beside the names for the same reason: the shade outlives the app,
     * and a phone that starts offline must still write 5G+ the way the list
     * says.
     */
    fun saveFiveG(context: Context, raw: Map<*, *>?) {
        if (raw.isNullOrEmpty()) return
        val json = JSONObject()
        for ((key, value) in raw) {
            val plmn = key?.toString()?.trim() ?: continue
            val label = value?.toString()?.trim() ?: continue
            if (plmn.isEmpty() || label.isEmpty()) continue
            json.put(plmn, label)
        }
        if (json.length() == 0) return
        prefs(context).edit().putString(KEY_FIVE_G, json.toString()).commit()
    }

    /** The stored `fiveG` labels, empty when the list has never carried any. */
    fun storedFiveG(context: Context): Map<String, String> {
        val raw = prefs(context).getString(KEY_FIVE_G, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            buildMap {
                for (key in json.keys()) {
                    val label = json.optString(key, "").trim()
                    if (label.isNotEmpty()) put(key, label)
                }
            }
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /** The stored table, for the app to seed itself from before a fetch. */
    fun stored(context: Context): Map<String, String> {
        val raw = prefs(context).getString(KEY_TABLE, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            buildMap {
                for (key in json.keys()) {
                    val brand = json.optString(key, "").trim()
                    if (brand.isNotEmpty()) put(key, brand)
                }
            }
        } catch (e: Exception) {
            emptyMap()
        }
    }
}
