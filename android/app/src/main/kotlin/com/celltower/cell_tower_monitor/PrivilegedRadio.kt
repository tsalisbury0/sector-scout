package com.celltower.cell_tower_monitor

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.util.Log
import rikka.shizuku.Shizuku
import java.util.concurrent.Executors

/**
 * App-side half of the carrier-detail reader: Shizuku lifecycle, the grant, and
 * a cache the snapshot can read from the main thread.
 *
 * The whole feature is optional by design. Every entry point answers "not
 * available" rather than throwing, and [CellSnapshot] keeps producing exactly
 * what it did before when nothing is bound — a phone without Shizuku loses the
 * added rows and nothing else.
 *
 * Reads happen on one worker thread and land in [cache]; a snapshot only ever
 * reads that cache, so a slow or wedged modem cannot stall the UI thread that
 * builds it. A miss schedules the next read and returns what is already known.
 */
object PrivilegedRadio {

    private const val TAG = "PrivilegedRadio"

    /** How long a reading stays fresh; the app polls the modem every 2.5 s. */
    private const val TTL_MS = 5_000L

    /** Shizuku package name, and the Sui package that provides the same API. */
    private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
    private const val SUI_PACKAGE = "rikka.sui"

    private var appContext: Context? = null
    private var service: IPrivilegedRadio? = null
    private var binding = false
    private var attached = false

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "privileged-radio").apply { isDaemon = true }
    }

    private val cache = HashMap<Int, CachedRead>()
    private val inFlight = HashSet<Int>()

    private data class CachedRead(val detail: CarrierDetail, val at: Long)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = IPrivilegedRadio.Stub.asInterface(binder)
            binding = false
            Log.i(TAG, "user service connected")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            binding = false
            cache.clear()
            Log.i(TAG, "user service disconnected")
        }
    }

    private val onBinderReceived = Shizuku.OnBinderReceivedListener {
        if (permitted()) bind()
    }

    private val onBinderDead = Shizuku.OnBinderDeadListener {
        service = null
        binding = false
        cache.clear()
    }

    private val onPermissionResult =
        Shizuku.OnRequestPermissionResultListener { _, grantResult ->
            if (grantResult == PackageManager.PERMISSION_GRANTED) bind()
        }

    /**
     * Wires the Shizuku listeners up, once per process.
     *
     * Called from the activity and from the pinned-notification service, which
     * builds snapshots without a Flutter engine — whichever runs first wins.
     */
    @Synchronized
    fun attach(context: Context) {
        val app = context.applicationContext
        appContext = app
        if (attached) return
        attached = true
        try {
            Shizuku.addBinderReceivedListenerSticky(onBinderReceived)
            Shizuku.addBinderDeadListener(onBinderDead)
            Shizuku.addRequestPermissionResultListener(onPermissionResult)
            if (permitted()) bind()
        } catch (error: Throwable) {
            // Older Shizuku, or a device where the provider never ran.
            Log.w(TAG, "Shizuku listeners unavailable: ${error.message}")
        }
    }

    /** The state the Settings page shows, plus the reply to a grant request. */
    fun status(context: Context): Map<String, Any?> {
        attach(context)
        val state = state(context)
        return linkedMapOf(
            "state" to state,
            "uid" to uid(),
            "error" to lastError,
        )
    }

    private var lastError: String? = null

    private fun uid(): Int? = try {
        if (Shizuku.pingBinder()) Shizuku.getUid() else null
    } catch (error: Throwable) {
        null
    }

    /** One of the strings the Dart side maps to a row in Settings. */
    private fun state(context: Context): String {
        if (!installed(context)) return "not_installed"
        return try {
            if (!Shizuku.pingBinder()) return "not_running"
            if (Shizuku.isPreV11()) return "unsupported"
            if (!permitted()) return "no_permission"
            if (service == null) {
                bind()
                "starting"
            } else {
                "ready"
            }
        } catch (error: Throwable) {
            lastError = error.message
            "not_running"
        }
    }

    /** Asks Shizuku's own confirmation dialog for this app's grant. */
    fun requestPermission(context: Context) {
        attach(context)
        try {
            if (!Shizuku.pingBinder()) return
            if (permitted()) {
                bind()
                return
            }
            Shizuku.requestPermission(REQUEST_CODE)
        } catch (error: Throwable) {
            lastError = error.message
            Log.w(TAG, "requestPermission failed: ${error.message}")
        }
    }

    /**
     * The last reading for a subscription, and a nudge to refresh it.
     *
     * Never blocks and never throws: an absent service simply answers empty.
     */
    fun detail(subId: Int): CarrierDetail {
        val key = if (subId > 0) subId else -1
        val hit = cache[key]
        val now = System.currentTimeMillis()
        if (hit == null || now - hit.at > TTL_MS) refresh(key)
        return hit?.detail ?: CarrierDetail.EMPTY
    }

    private fun refresh(subId: Int) {
        val bound = service ?: return
        synchronized(inFlight) {
            if (!inFlight.add(subId)) return
        }
        worker.execute {
            try {
                val json = bound.readCarrierDetail(subId)
                cache[subId] = CachedRead(CarrierDetail.parse(json), System.currentTimeMillis())
            } catch (error: Throwable) {
                Log.w(TAG, "read failed for sub $subId: ${error.message}")
            } finally {
                synchronized(inFlight) { inFlight.remove(subId) }
            }
        }
    }

    private fun permitted(): Boolean = try {
        Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (error: Throwable) {
        false
    }

    private fun installed(context: Context): Boolean {
        val pm = context.packageManager
        return try {
            pm.getPackageInfo(SHIZUKU_PACKAGE, 0)
            true
        } catch (error: PackageManager.NameNotFoundException) {
            try {
                pm.getPackageInfo(SUI_PACKAGE, 0)
                true
            } catch (alsoMissing: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    private fun bind() {
        val context = appContext ?: return
        if (binding || service != null) return
        binding = true
        try {
            val args = Shizuku.UserServiceArgs(
                ComponentName(context.packageName, PrivilegedRadioService::class.java.name),
            )
                .daemon(false)
                .processNameSuffix("radio")
                .debuggable(BuildConfig.DEBUG)
                .version(BuildConfig.VERSION_CODE)
            Shizuku.bindUserService(args, connection)
        } catch (error: Throwable) {
            binding = false
            lastError = error.message
            Log.w(TAG, "bindUserService failed: ${error.message}")
        }
    }

    /** Grant request code; the listener above re-binds when it comes back. */
    const val REQUEST_CODE = 4210
}
