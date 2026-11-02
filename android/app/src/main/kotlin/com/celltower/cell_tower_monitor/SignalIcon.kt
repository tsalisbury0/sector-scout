package com.celltower.cell_tower_monitor

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import kotlin.math.roundToInt

/**
 * The status-bar icon: the technology the phone is on, drawn as text the way
 * carriers label it — **LTE**, **LTE+**, **5GE**, **5G**, **5G+**, **5GUC**,
 * **5GUW**.
 *
 * Android's notification icon is a single silhouette, so a different vector per
 * label would still have to spell the letters out. The label is drawn into an
 * icon-sized bitmap instead: white, bold, shrunk to fit "5GUW" without clipping.
 */
object SignalIcon {

    /** AT&T (incl. FirstNet), which shows 5G+ for NR Advanced. */
    private val attPlmns = setOf("310410", "310150", "310170", "310380", "313100")
    private const val tMobile = "310260"
    private const val verizon = "311480"

    /**
     * Badge for the current network, or null when the tech has no badge (2G/3G,
     * or nothing served) and the app's bars icon should be used instead.
     *
     * 5G is only claimed when a 5G carrier is actually there: an NR cell
     * attached to the data SIM (SA, or the secondary leg of NSA). The platform's
     * `overrideNetworkType` is not enough on its own — Samsung keeps reporting
     * `NR_NSA` for a while after the NR leg has gone, and the badge would then
     * advertise 5G on an LTE-only connection.
     *
     * @param tech the serving cell's technology, `null` when nothing is served
     * @param override `overrideNetworkType` from the display info, used to pick
     *   the carrier's badge once 5G is confirmed, and to tell LTE from LTE-A on
     *   an LTE-only slot
     * @param nrAttached whether that SIM has a registered NR cell
     * @param aggregated whether the LTE side is carrying more than one
     *   carrier: a second registered LTE cell, or a supplemental downlink
     *   (29, 32, 67, 69, 75, 76), which a radio only reports while it is
     *   aggregating it
     */
    fun labelFor(
        tech: String?,
        override: String,
        plmn: String?,
        nrAttached: Boolean,
        aggregated: Boolean = false,
    ): String? {
        if (nrAttached) {
            if (override == "NR_ADVANCED") {
                val codes = plmn?.replace("-", "")
                return when {
                    codes != null && attPlmns.contains(codes) -> "5G+"
                    codes == tMobile -> "5GUC"
                    codes == verizon -> "5GUW"
                    // NR Advanced on a network with no house style.
                    else -> "5G"
                }
            }
            return "5G"
        }
        if (tech != "LTE") return null
        // LTE-Advanced, from the display info's aggregation / Advanced Pro
        // override. AT&T (FirstNet included) sells Advanced Pro as "5GE";
        // everywhere else both read "LTE+". Still an LTE radio either way.
        if (override == "LTE_ADVANCED_PRO") {
            val codes = plmn?.replace("-", "")
            return if (codes != null && attPlmns.contains(codes)) "5GE" else "LTE+"
        }
        // Any second carrier is LTE-Advanced, whether or not the platform's
        // own override says so — which is what lets an NSA slot whose 5G leg
        // has gone read LTE+ while a B29 is still under it.
        if (aggregated || override == "LTE_CA") return "LTE+"
        return "LTE"
    }

    /** Cached icons, so a 10 s refresh does not re-draw them. */
    private val cache = HashMap<String, Icon>()
    private val largeCache = HashMap<String, Bitmap>()

    /**
     * Ink for the glyph when it is drawn on the shade's own surface.
     *
     * The status-bar icon is a silhouette the system tints, but the large icon is
     * drawn as given — white on a light shade is invisible, so light mode gets a
     * dark ink instead.
     */
    private const val INK_NIGHT = Color.WHITE
    private const val INK_DAY = 0xFF0F172A.toInt()

    fun icon(context: Context, label: String): Icon =
        cache.getOrPut(label) { Icon.createWithBitmap(bitmap(context, label)) }

    /**
     * The same badge at content size, for the expanded notification.
     *
     * Some OEM shaders (Samsung's One UI among them) draw their own app icon in
     * the small-icon slot of a foreground-service notification; the large icon
     * is rendered as given, so the badge stays readable there.
     */
    fun large(context: Context, label: String): Bitmap {
        val night = isNight(context)
        return largeCache.getOrPut(if (night) "$label/night" else "$label/day") {
            bitmap(context, label, sizeDp = 64.0, ink = if (night) INK_NIGHT else INK_DAY)
        }
    }

    /** The shade follows the system theme, not the app's dark-only palette. */
    private fun isNight(context: Context): Boolean =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private fun bitmap(
        context: Context,
        label: String,
        sizeDp: Double = 24.0,
        ink: Int = INK_NIGHT,
    ): Bitmap {
        // Rendered at the status-bar size in pixels, with a floor so the glyphs
        // keep their shape on low-density screens.
        val size = (sizeDp * context.resources.displayMetrics.density).roundToInt()
            .coerceIn(48, 256)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }

        // Start tall and shrink until the widest label fits the icon box.
        paint.textSize = size * 0.52f
        val widest = size * 0.96f
        val measured = paint.measureText(label)
        if (measured > widest) paint.textSize *= widest / measured

        val baseline = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(label, size / 2f, baseline, paint)
        return bitmap
    }
}
