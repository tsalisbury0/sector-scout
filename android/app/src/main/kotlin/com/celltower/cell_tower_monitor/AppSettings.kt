package com.celltower.cell_tower_monitor

import android.content.Context

/**
 * The Settings page's band-filter switches, stored where both sides can read
 * them.
 *
 * The pinned notification is drawn by [SignalStatusService] with no Flutter
 * engine, so the flags cannot live in Dart alone: the app writes them through
 * the method channel, and the service reads the same preferences on every
 * update. Anything unset defaults to **on**, which is how a fresh install (and
 * an upgrade from a build without settings) behaves.
 */
object AppSettings {

    private const val PREFS = "sector_scout_settings"

    const val KEY_TMOBILE = "tmobileBands"
    const val KEY_CBRS = "cbrs"
    const val KEY_B106 = "anterixB106"
    const val KEY_CARRIER_DETAIL = "carrierDetail"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun tmobileBands(context: Context): Boolean =
        prefs(context).getBoolean(KEY_TMOBILE, true)

    fun cbrs(context: Context): Boolean = prefs(context).getBoolean(KEY_CBRS, true)

    /**
     * The Anterix B106 numbering, **off** unless switched on: it used to be a
     * separate build, so a fresh install keeps the 3GPP label.
     */
    fun anterixB106(context: Context): Boolean =
        prefs(context).getBoolean(KEY_B106, false)

    /**
     * Whether the Shizuku reader may run, **on** unless switched off.
     *
     * It does nothing on a phone without Shizuku and everything it adds is
     * optional, so a fresh install keeps it on; the switch exists for anyone
     * who does not want a shell-identity service running at all.
     */
    fun carrierDetail(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CARRIER_DETAIL, true)

    /** Every switch, in the shape the method channel returns. */
    fun all(context: Context): Map<String, Any> = mapOf(
        KEY_TMOBILE to tmobileBands(context),
        KEY_CBRS to cbrs(context),
        KEY_B106 to anterixB106(context),
        KEY_CARRIER_DETAIL to carrierDetail(context),
    )

    /**
     * Stores one switch. Unknown keys are refused rather than written, so a
     * typo in Dart cannot leave an unread entry behind.
     */
    fun set(context: Context, key: String, value: Boolean): Boolean {
        if (key !in all(context).keys) return false
        prefs(context).edit().putBoolean(key, value).apply()
        return true
    }

    /** The corrections the summary should apply, as read from storage. */
    fun corrections(context: Context) = SignalSummary.Corrections(
        tmobileBands = tmobileBands(context),
        cbrs = cbrs(context),
    )
}
