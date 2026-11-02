package com.celltower.cell_tower_monitor

import android.content.Context
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Keeps [RadioState] filled with each subscription's `overrideNetworkType`.
 *
 * That value is the only thing that distinguishes **5G+** (NR Advanced) from a
 * plain NSA anchor — `3GPP` reports both as LTE plus an NR leg — so whoever draws
 * the badge needs it live.
 *
 * Both readers share it: the app's [CellMonitor], and the pinned notification
 * service, which runs with no Flutter engine at all. Registering the listeners
 * here rather than inside either of them matters, because the two have different
 * lifetimes: the Activity can be destroyed (or its stream cancelled) while the
 * service keeps polling, and a teardown used to clear the overrides the service
 * was still drawing from. Reference counting keeps the listeners alive for
 * whoever is still reading.
 */
object DisplayInfoTracker {

    private const val TAG = "DisplayInfoTracker"

    private var users = 0
    private val callbacks = mutableListOf<Pair<TelephonyManager, TelephonyCallback>>()
    private val listeners = mutableSetOf<() -> Unit>()

    /**
     * Starts tracking, balanced by [release].
     *
     * [onChange] is called whenever an override arrives, so a reader that wants
     * to redraw immediately (the app's stream) does not have to wait for its own
     * poll.
     */
    @Synchronized
    fun acquire(context: Context, onChange: (() -> Unit)? = null) {
        onChange?.let { listeners.add(it) }
        if (users++ > 0) return
        register(context.applicationContext)
    }

    /** Stops tracking once the last reader is gone. */
    @Synchronized
    fun release(onChange: (() -> Unit)? = null) {
        onChange?.let { listeners.remove(it) }
        users = (users - 1).coerceAtLeast(0)
        if (users > 0) return
        for ((tm, cb) in callbacks) {
            try {
                tm.unregisterTelephonyCallback(cb)
            } catch (e: Exception) {
                Log.w(TAG, "Unregistering display info failed: ${e.message}")
            }
        }
        callbacks.clear()
        RadioState.clear()
    }

    private fun register(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val base = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
        val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
        val subs = try {
            sm?.activeSubscriptionInfoList ?: emptyList()
        } catch (e: Exception) {
            Log.w(TAG, "No subscription list for display info: ${e.message}")
            return
        }

        for (info in subs) {
            val subId = info.subscriptionId
            val tm = try {
                base.createForSubscriptionId(subId)
            } catch (e: Exception) {
                continue
            }
            val cb = object : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
                override fun onDisplayInfoChanged(displayInfo: TelephonyDisplayInfo) {
                    val changed = RadioState.setOverride(subId, displayInfo.overrideNetworkType)
                    if (changed) notifyListeners()
                }
            }
            try {
                tm.registerTelephonyCallback(context.mainExecutor, cb)
                callbacks.add(tm to cb)
            } catch (e: Exception) {
                Log.w(TAG, "Display info unavailable for sub $subId: ${e.message}")
            }
        }
    }

    private fun notifyListeners() {
        val current = synchronized(this) { listeners.toList() }
        for (listener in current) {
            try {
                listener()
            } catch (e: Exception) {
                Log.w(TAG, "Display info listener failed: ${e.message}")
            }
        }
    }
}
