package com.celltower.cell_tower_monitor

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.CellInfo
import android.telephony.PhoneStateListener
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.plugin.common.EventChannel

/**
 * Latest network-type override per subscription.
 *
 * `TelephonyDisplayInfo.overrideNetworkType` is the value Android uses for the
 * status-bar "5G" / "5G+" indicator, so it is the authoritative NSA vs SA
 * signal — the NR leg itself is often not reported as a cell by OEM firmwares.
 */
object RadioState {
    private val overrides = HashMap<Int, Int>()

    /** Stores the override; true when it actually changed. */
    @Synchronized
    fun setOverride(subscriptionId: Int, value: Int): Boolean =
        overrides.put(subscriptionId, value) != value

    @Synchronized
    fun overrideFor(subscriptionId: Int): Int =
        overrides[subscriptionId] ?: TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE

    @Synchronized
    fun clear() = overrides.clear()
}

/**
 * Pushes a fresh cell snapshot to Dart whenever the modem reports a change.
 *
 * Callbacks are coalesced (a moving car can fire them many times per second)
 * and a slow poll runs alongside them, because some devices/modem firmwares
 * only deliver cell-info change events while the screen is interactive.
 */
class CellMonitor(private val context: Context) : EventChannel.StreamHandler {

    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: TelephonyCallback? = null
    private var listener: PhoneStateListener? = null

    /** Redraw as soon as 5G+ appears or drops, instead of waiting for a poll. */
    private val onDisplayChange: () -> Unit = { schedule() }

    private val emitNow = Runnable { emit() }
    private val poll = object : Runnable {
        override fun run() {
            emit()
            handler.postDelayed(this, POLL_MS)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emit()
        register()
        handler.postDelayed(poll, POLL_MS)
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                callback?.let { (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)?.unregisterTelephonyCallback(it) }
            } else {
                listener?.let { (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)?.listen(it, PhoneStateListener.LISTEN_NONE) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "unregister failed: ${e.message}")
        }
        // Only drops the display-info listeners once nothing else needs them:
        // the pinned notification service reads the same overrides, and it
        // outlives this engine.
        DisplayInfoTracker.release(onDisplayChange)
        callback = null
        listener = null
        sink = null
    }

    private fun register() {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val cb = object : TelephonyCallback(),
                    TelephonyCallback.CellInfoListener,
                    TelephonyCallback.SignalStrengthsListener {
                    override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>) = schedule()
                    override fun onSignalStrengthsChanged(signalStrength: SignalStrength) = schedule()
                }
                tm.registerTelephonyCallback(context.mainExecutor, cb)
                callback = cb
            } else {
                @Suppress("DEPRECATION")
                val l = object : PhoneStateListener() {
                    override fun onCellInfoChanged(cellInfo: MutableList<CellInfo>?) = schedule()
                    override fun onSignalStrengthsChanged(signalStrength: SignalStrength?) = schedule()
                }
                @Suppress("DEPRECATION")
                tm.listen(l, PhoneStateListener.LISTEN_CELL_INFO or PhoneStateListener.LISTEN_SIGNAL_STRENGTHS)
                listener = l
            }
        } catch (e: Exception) {
            Log.w(TAG, "Live updates unavailable, falling back to polling: ${e.message}")
        }
        // Per-subscription 5G indicator tracking (NSA vs SA vs NR Advanced).
        DisplayInfoTracker.acquire(context, onDisplayChange)
    }

    /** Coalesce bursts of modem callbacks into a single send. */
    private fun schedule() {
        handler.removeCallbacks(emitNow)
        handler.postDelayed(emitNow, DEBOUNCE_MS)
    }

    private fun emit() {
        val s = sink ?: return
        try {
            s.success(CellSnapshot.build(context))
        } catch (e: Exception) {
            Log.w(TAG, "emit failed: ${e.message}")
        }
    }

    private companion object {
        const val TAG = "CellMonitor"
        const val DEBOUNCE_MS = 400L
        const val POLL_MS = 2500L
    }
}
