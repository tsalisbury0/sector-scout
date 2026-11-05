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

    /**
     * The Shizuku API level this build is compiled against.
     *
     * `dev.rikka.shizuku:api:13.1.5` speaks API 13. A Shizuku app below that
     * answers the binder differently, and the failure surfaces inside the bound
     * user service rather than as a clean refusal — so the reader is offered
     * only on that level or newer, and bound only there.
     */
    private const val MIN_SHIZUKU_API = 13
    private const val SUI_PACKAGE = "rikka.sui"

    private var appContext: Context? = null
    private var service: IPrivilegedRadio? = null
    private var binding = false
    private var attached = false

    /**
     * Whether the reader may run at all, from the Settings switch.
     *
     * Off means nothing is bound and nothing is read, so a snapshot looks
     * exactly like one from a phone without Shizuku: no carriers, no widths,
     * no aggregation card.
     */
    @Volatile
    private var enabled = true

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
        if (supported() && permitted()) bind()
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
            if (enabled && supported() && permitted()) bind()
        } catch (error: Throwable) {
            // Older Shizuku, or a device where the provider never ran.
            Log.w(TAG, "Shizuku listeners unavailable: ${error.message}")
        }
    }

    /** The state the Settings page shows, plus the reply to a grant request. */
    fun status(context: Context): Map<String, Any?> {
        attach(context)
        val state = if (enabled) state(context) else "disabled"
        return linkedMapOf(
            "state" to state,
            "uid" to uid(),
            "error" to lastError,
        )
    }

    /**
     * Turns the reader on or off, from the Settings switch.
     *
     * Off ends the shell-identity process outright rather than only dropping
     * the handle: a bound service keeps running, and the point of the switch is
     * that it does not.
     */
    fun setEnabled(context: Context, on: Boolean) {
        if (enabled == on) return
        // A second lock behind the switch, which Settings disables in this case:
        // no entry point may bind a Shizuku older than the API this build uses.
        if (on && !supported()) {
            Log.w(TAG, "carrier reader refused: Shizuku API below $MIN_SHIZUKU_API")
            return
        }
        enabled = on
        if (on) {
            attach(context)
            if (permitted()) bind()
            Log.i(TAG, "carrier reader enabled")
            return
        }
        try {
            service?.destroy()
        } catch (error: Throwable) {
            Log.d(TAG, "destroy on disable: ${error.message}")
        }
        service = null
        binding = false
        cache.clear()
        Log.i(TAG, "carrier reader disabled")
    }

    private var lastError: String? = null

    private fun uid(): Int? = try {
        if (Shizuku.pingBinder()) Shizuku.getUid() else null
    } catch (error: Throwable) {
        null
    }

    /** The API level of the running Shizuku app, or 0 when none is running. */
    private fun shizukuApi(): Int = try {
        if (Shizuku.pingBinder()) Shizuku.getVersion() else 0
    } catch (error: Throwable) {
        0
    }

    /** True when the running Shizuku speaks the API this build compiles to. */
    private fun supported(): Boolean = shizukuApi() >= MIN_SHIZUKU_API

    /** One of the strings the Dart side maps to a row in Settings. */
    private fun state(context: Context): String {
        if (!installed(context)) return "not_installed"
        return try {
            if (!Shizuku.pingBinder()) return "not_running"
            if (!supported()) return "unsupported"
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
        if (!enabled) return CarrierDetail.EMPTY
        val key = if (subId > 0) subId else -1
        val hit = cache[key]
        val now = System.currentTimeMillis()
        if (hit == null || now - hit.at > TTL_MS) refresh(key)
        return hit?.detail ?: CarrierDetail.EMPTY
    }

    private fun refresh(subId: Int) {
        if (!enabled) return
        val bound = service ?: return
        synchronized(inFlight) {
            if (!inFlight.add(subId)) return
        }
        worker.execute {
            try {
                val json = bound.readCarrierDetail(subId)
                val detail = CarrierDetail.parse(json)
                cache[subId] = CachedRead(detail, System.currentTimeMillis())
                // What the app actually gets, so a missing width on a card can
                // be told apart from a carrier the modem never reported.
                if (detail.carriers.isNotEmpty()) {
                    Log.d(
                        TAG,
                        "sub $subId: " + detail.carriers.joinToString { carrier ->
                            "${carrier.band}/${carrier.bandwidthKhz}kHz/" +
                                "net${carrier.networkType}/pci${carrier.pci}"
                        },
                    )
                }
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
        if (!enabled) return
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
