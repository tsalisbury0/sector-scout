package com.celltower.cell_tower_monitor

import android.content.Context
import android.os.Process
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Method

/**
 * The half of the carrier-detail reader that runs with shell privilege.
 *
 * Shizuku starts this class as a bound user service: a separate process whose
 * Linux UID is the one Shizuku itself runs as — 2000 for ADB, 0 for root. That
 * identity is what makes the radio's physical channel configuration readable at
 * all; a normal app cannot hold the permission it checks.
 *
 * It answers one question — which carriers the radio is running, on what band,
 * at what width, and whether each one is NR — and nothing else. Everything
 * below is reflection on purpose: `PhysicalChannelConfig` is a system class and
 * is not in the public SDK the app compiles against.
 */
class PrivilegedRadioService(private val context: Context?) : IPrivilegedRadio.Stub() {

    /**
     * Shizuku calls this when the service is being replaced or the app is
     * unbinding for good. Unbinding alone leaves the process running, so this
     * is the only place it can end.
     */
    override fun destroy() {
        System.exit(0)
    }

    override fun readCarrierDetail(subId: Int): String = try {
        val base = telephony()
        if (base == null) {
            error("no telephony service")
        } else {
            // createForSubscriptionId keeps the answering SIM's own radio: a
            // dual-SIM phone otherwise reports the other slot's carriers.
            val tm = if (subId > 0) base.createForSubscriptionId(subId) else base
            JSONObject()
                .put("uid", Process.myUid())
                .put("carriers", carriers(tm, subId))
                .toString()
        }
    } catch (failure: Throwable) {
        // Nothing here may take the process down: the app polls this every few
        // seconds, and a modem that refuses one call must not break the rest.
        Log.w(TAG, "carrier detail failed: ${failure.message}")
        error(failure.message ?: failure.javaClass.simpleName)
    }

    // ---------------------------------------------------------------------
    // Component carriers: band, width, technology, PCI
    // ---------------------------------------------------------------------

    /**
     * The carriers the radio is running right now.
     *
     * `PhysicalChannelConfig` carries the width of each component carrier and
     * the band it sits on, which is what makes aggregation visible instead of
     * inferred: four entries means four carriers, whatever the band list on
     * `CellIdentity` says. The per-carrier method moved around across releases,
     * so the TelephonyManager copy is tried first and the one on `ServiceState`
     * second.
     */
    private fun carriers(tm: TelephonyManager, subId: Int): JSONArray {
        val out = JSONArray()
        val configs = physicalChannelConfigs(tm, subId)
        for (config in configs) {
            val bandwidth = (call(config, "getCellBandwidthDownlink") as? Int) ?: 0
            val networkType = (call(config, "getNetworkType") as? Int) ?: 0
            if (bandwidth <= 0) continue
            val pci = (call(config, "getPhysicalCellId") as? Int)
                ?.takeIf { it >= 0 && it != Int.MAX_VALUE }
            out.put(
                JSONObject()
                    .put("band", (call(config, "getBand") as? Int) ?: 0)
                    .put("bw", bandwidth)
                    .put("net", networkType)
                    .put("pci", pci ?: JSONObject.NULL),
            )
        }
        return out
    }

    private fun physicalChannelConfigs(tm: TelephonyManager, subId: Int): List<Any> {
        val names = listOf("getPhysicalChannelConfigs", "getPhysicalChannelConfig")
        firstList(tm, names, subId)?.let { return it }
        val state = try {
            tm.serviceState
        } catch (error: Throwable) {
            null
        }
        firstList(state, names, subId)?.let { return it }
        Log.d(TAG, "no physical channel configs on this firmware")
        return emptyList()
    }

    // ---------------------------------------------------------------------
    // Plumbing
    // ---------------------------------------------------------------------

    /**
     * The user service is not a real app process, so it may have no Context at
     * all (Shizuku before 13). The system context is the fallback: it is a
     * handle the framework itself owns, which is enough to ask for a system
     * service.
     */
    private fun telephony(): TelephonyManager? {
        val ctx = context ?: systemContext()
        return ctx?.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    }

    private fun systemContext(): Context? = try {
        val thread = Class.forName("android.app.ActivityThread")
        val main = thread.getMethod("systemMain").invoke(null)
        thread.getMethod("getSystemContext").invoke(main) as? Context
    } catch (error: Throwable) {
        null
    }

    /** First call among [names] that returns a list, over the usual arities. */
    private fun firstList(target: Any?, names: List<String>, subId: Int): List<Any>? {
        if (target == null) return null
        for (name in names) {
            for (args in listOf(arrayOf<Any?>(subId), emptyArray<Any?>())) {
                val value = invokeMatching(target, name, args)
                if (value is List<*>) return value.filterNotNull()
            }
        }
        return null
    }

    /** Calls the first method of [name] whose parameters match [args]. */
    private fun invokeMatching(target: Any?, name: String, args: Array<Any?>): Any? {
        if (target == null) return null
        val method: Method = target.javaClass.methods.firstOrNull { candidate ->
            if (candidate.name != name) return@firstOrNull false
            if (candidate.parameterTypes.size != args.size) return@firstOrNull false
            candidate.parameterTypes.indices.all { index ->
                val type = candidate.parameterTypes[index]
                val value = args[index]
                value == null ||
                    type.isInstance(value) ||
                    (type == Int::class.javaPrimitiveType && value is Int) ||
                    (type == Long::class.javaPrimitiveType && value is Long)
            }
        } ?: return null
        return try {
            method.isAccessible = true
            method.invoke(target, *args)
        } catch (error: Throwable) {
            Log.d(TAG, "$name: ${error.message}")
            null
        }
    }

    private fun call(target: Any?, name: String): Any? = invokeMatching(target, name, emptyArray())

    private fun error(message: String): String =
        JSONObject().put("error", message).toString()

    private companion object {
        const val TAG = "PrivilegedRadioService"
    }
}
