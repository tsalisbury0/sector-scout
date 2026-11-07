package com.celltower.cell_tower_monitor

import android.content.Context
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.telephony.PhysicalChannelConfig
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Method
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * The half of the carrier-detail reader that runs with shell privilege.
 *
 * Shizuku starts this class as a bound user service: a separate process whose
 * Linux UID is the one Shizuku itself runs as — 2000 for ADB, 0 for root. That
 * identity is what makes the radio's physical channel configuration readable at
 * all; a normal app cannot hold the permission it checks.
 *
 * It answers one question — which carriers the radio is running, on what band,
 * at what width, and whether each one is NR — and nothing else.
 *
 * The carriers arrive as a push, not a query. `TelephonyManager` used to grow a
 * `getPhysicalChannelConfigs` method, and this reader called it by reflection;
 * on Android 17 that method is gone, which is why the widths simply stopped
 * appearing. What every release does keep is the callback: register a
 * `PhysicalChannelConfigListener` and the registry pushes the complete list of
 * component carriers whenever the modem changes them. So the first read
 * registers and waits briefly, and every read after that answers from the last
 * push.
 */
class PrivilegedRadioService(private val context: Context?) : IPrivilegedRadio.Stub() {

    /**
     * The constructor Shizuku actually uses.
     *
     * The user service is started by `moe.shizuku.starter.ServiceStarter`, which
     * instantiates it with `Class.newInstance()` — a public, no-argument
     * constructor, nothing else. With only the `(Context?)` form below, that
     * call threw `InstantiationException` inside the shell process, Shizuku gave
     * up after its 30 s start timeout, and Settings sat on "starting" forever.
     * No context comes through this path, which is fine: the shell process has no
     * app context anyway, and every call that needs one falls back to
     * [systemContext].
     */
    constructor() : this(null)

    /** The last list the registry pushed, per subscription. */
    private val live = HashMap<Int, List<Any>>()

    /** Subscriptions a listener has already been started for. */
    private val listening = HashSet<Int>()

    private val lock = Any()

    private val callbackExecutor: Executor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "carrier-callback").apply { isDaemon = true }
        }

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
            val payload = JSONObject()
                .put("uid", Process.myUid())
                .put("carriers", carriers(tm, subId))
            // IMS rides along on the same call, so the app asks once for both.
            ims(subId)?.let { payload.put("ims", it) }
            payload.toString()
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
     * Whether voice is registered over WLAN and over the cellular link.
     *
     * `ImsMmTelManager.isAvailable(capability, transport)` is the only API that
     * answers while no call is up: the public `getVoiceNetworkType()` reports
     * IWLAN only once a call is already running over Wi-Fi, so a registered
     * Wi-Fi calling link is invisible to the app until someone calls. The
     * manager is hidden, which is why this runs with the shell identity.
     */
    private fun ims(subId: Int): JSONObject? = try {
        val cls = Class.forName("android.telephony.ims.ImsMmTelManager")
        val manager = cls
            .getMethod("createForSubscriptionId", Int::class.javaPrimitiveType)
            .invoke(null, subId)
        if (manager == null) {
            null
        } else {
            // MmTelCapabilities.CAPABILITY_TYPE_VOICE = 1,
            // AccessNetworkConstants.TRANSPORT_TYPE_WLAN = 2, _WWAN = 1.
            val available = try {
                cls.getMethod(
                    "isAvailable",
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                )
            } catch (olderRelease: Throwable) {
                null
            }
            fun voice(transport: Int): Any? = try {
                available?.invoke(manager, 1, transport)
            } catch (failure: Throwable) {
                null
            }
            // The user's own Wi-Fi calling switch. The capability answer can
            // read false for a moment mid-handover, and a firmware that keeps
            // it private answers nothing at all; the switch is what separates
            // a real Wi-Fi calling registration from a plain IWLAN network
            // type, which is the false positive the other apps show.
            val wfc = try {
                findMethod(manager, "isVoWiFiSettingEnabled", 0)?.invoke(manager) as? Boolean
            } catch (failure: Throwable) {
                null
            }
            val state = JSONObject()
                .put("vowifi", voice(2) ?: JSONObject.NULL)
                .put("volte", voice(1) ?: JSONObject.NULL)
                .put("wfc", wfc ?: JSONObject.NULL)
            Log.d(TAG, "ims sub $subId: $state")
            state
        }
    } catch (failure: Throwable) {
        Log.d(TAG, "IMS state unavailable: ${failure.message}")
        null
    }

    /**
     * The carriers the radio is running right now.
     *
     * `PhysicalChannelConfig` carries the width of each component carrier and
     * the band it sits on, which is what makes aggregation visible instead of
     * inferred: four entries means four carriers, whatever the band list on
     * `CellIdentity` says.
     */
    private fun carriers(tm: TelephonyManager, subId: Int): JSONArray {
        val out = JSONArray()
        val configs = physicalChannelConfigs(tm, subId)
        for (config in configs) {
            val bandwidth = bandwidthKhz(config)
            if (bandwidth <= 0) continue
            val pci = (call(config, "getPhysicalCellId") as? Int)
                ?.takeIf { it >= 0 && it != Int.MAX_VALUE }
            out.put(
                JSONObject()
                    .put("band", (call(config, "getBand") as? Int) ?: 0)
                    .put("bw", bandwidth)
                    .put("net", (call(config, "getNetworkType") as? Int) ?: 0)
                    .put("pci", pci ?: JSONObject.NULL),
            )
        }
        return out
    }

    /**
     * The pushed list, or — on an old release, or a modem that stays quiet — a
     * one-shot read, or the copy that rides along on `ServiceState`.
     */
    private fun physicalChannelConfigs(tm: TelephonyManager, subId: Int): List<Any> {
        listenForCarriers(tm, subId)?.takeIf { it.isNotEmpty() }?.let { return it }
        directRead(subId)?.takeIf { it.isNotEmpty() }?.let { return it }
        firstList(tm, LIST_METHODS, subId)?.takeIf { it.isNotEmpty() }?.let { return it }
        val state = try {
            tm.serviceState
        } catch (error: Throwable) {
            null
        }
        firstList(state, LIST_METHODS, subId)?.takeIf { it.isNotEmpty() }?.let { return it }
        Log.d(
            TAG,
            "no carriers yet on sub $subId; radio accessors: ${accessors(tm)}; " +
                "registry: ${registrySurface()}",
        )
        return emptyList()
    }

    /**
     * `ITelephony` still answers the question outright on some releases. Where
     * it does, one binder call beats a subscription.
     */
    private fun directRead(subId: Int): List<Any>? = try {
        val phone = systemService("phone", "com.android.internal.telephony.ITelephony\$Stub")
        firstList(phone, LIST_METHODS, subId)
    } catch (failure: Throwable) {
        Log.d(TAG, "ITelephony carrier read failed: ${failure.message}")
        null
    }

    /**
     * The registry's latest push for [subId].
     *
     * Registering is the expensive half, so it happens once per subscription:
     * the first call registers and waits a moment for the initial delivery,
     * and later calls read whatever the modem last reported.
     */
    private fun listenForCarriers(tm: TelephonyManager, subId: Int): List<Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val first = synchronized(lock) { listening.add(subId) }
        if (first && !startListening(tm, subId)) return null
        if (!first) return synchronized(lock) { live[subId] }

        var waited = 0L
        while (waited < FIRST_WAIT_MS) {
            synchronized(lock) { live[subId] }?.let { return it }
            try {
                Thread.sleep(WAIT_STEP_MS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return null
            }
            waited += WAIT_STEP_MS
        }
        return synchronized(lock) { live[subId] }
    }

    /**
     * Subscribes to the registry's carrier pushes.
     *
     * `TelephonyManager.registerTelephonyCallback` is the API to use, but a
     * Shizuku user service is not an app process: Shizuku starts it through
     * `app_process`, so `ActivityThread`'s main never ran and the mainline
     * module initialisers that `TelephonyRegistryManager` reaches through were
     * never installed — the first attempt here failed with
     * `getTelephonyServiceManager()` on a null object. Running those
     * initialisers is the difference between the public registration working
     * and not, and it costs one reflective call.
     *
     * If the public route still fails, the PixelBandInfo route is tried:
     * `telephony.registry` straight off `ServiceManager`, calling
     * `listenWithEventList` with `notifyNow` set so the current list arrives at
     * once instead of waiting for the modem to change something.
     */
    private fun startListening(tm: TelephonyManager, subId: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val callback = CarrierCallback { configs ->
            synchronized(lock) { live[subId] = configs }
            Log.i(TAG, "pushed ${configs.size} carriers for sub $subId")
        }
        initializeModules()
        giveExecutor(callback)
        if (listenDirectly(subId, callback)) return true
        if (listenThroughManager(subId, callback)) return true
        // Last resort: the public registration. It only works where the
        // caller's package belongs to the calling UID, which is never true
        // here — this process runs as shell, not as the app.
        val registered = try {
            tm.registerTelephonyCallback(callbackExecutor, callback)
            Log.i(TAG, "listening through TelephonyManager for sub $subId")
            true
        } catch (failure: Throwable) {
            Log.w(TAG, "registerTelephonyCallback failed: ${failure.message}")
            false
        }
        if (!registered) synchronized(lock) { listening.remove(subId) }
        return registered
    }

    /**
     * `TelephonyRegistryManager.listenFromCallback` is the same call the public
     * API makes, one layer down: it takes the callback itself and the package
     * name to check it against, and builds the binder the registry wants.
     *
     * That package-name argument is the whole point. `TelephonyManager` sends
     * the *app's* package with a shell caller UID, and the registry refuses it
     * ("Package com.celltower.cell_tower_monitor does not belong to 2000").
     * Naming the shell package explicitly is what PixelBandInfo does; this is
     * that same hack where the listener type still checks out.
     */
    private fun listenThroughManager(subId: Int, callback: CarrierCallback): Boolean {
        val manager = try {
            Class.forName("android.telephony.TelephonyRegistryManager")
                .getConstructor(Context::class.java)
                .newInstance(context ?: systemContext())
        } catch (failure: Throwable) {
            Log.d(TAG, "TelephonyRegistryManager: ${failure.message}")
            return false
        }
        // `listenFromCallback` is not public, so it is absent from `methods`;
        // the declared walk is what finds it.
        val listen = findMethod(manager, "listenFromCallback", 8)
        if (listen == null) {
            Log.d(TAG, "no listenFromCallback on ${manager.javaClass.name}")
            return false
        }
        return try {
            listen.isAccessible = true
            listen.invoke(
                manager,
                false,
                false,
                subId,
                callerPackage(),
                "",
                callback,
                IntArray(0),
                true,
            )
            Log.i(TAG, "listening through TelephonyRegistryManager for sub $subId")
            true
        } catch (failure: Throwable) {
            Log.w(TAG, "listenFromCallback failed: ${failure.message}")
            false
        }
    }

    /**
     * The `IPhoneStateListener` the platform's own callback carries.
     *
     * On this release `TelephonyCallback` is not itself an
     * `IPhoneStateListener` — passing it to the registry is rejected on type —
     * but it holds one in its `callback` field, which is exactly the object
     * PixelBandInfo pulls out and hands to `listenWithEventList`. That stub is
     * what dispatches back to the listener interfaces this class implements.
     */
    private fun stateListener(callback: TelephonyCallback): Any? = try {
        val field = TelephonyCallback::class.java.declaredFields.firstOrNull { candidate ->
            candidate.type.name == "com.android.internal.telephony.IPhoneStateListener"
        }
        field?.isAccessible = true
        field?.get(callback)
    } catch (failure: Throwable) {
        Log.d(TAG, "IPhoneStateListener field: ${failure.message}")
        null
    }

    /**
     * The callback delivers through an executor that the public API would have
     * set. Registration here skips that step, and a null executor turns the
     * first push into a crash inside this process.
     */
    private fun giveExecutor(callback: TelephonyCallback) {
        try {
            val setter = TelephonyCallback::class.java.declaredMethods
                .firstOrNull { method ->
                    method.parameterTypes.size == 1 &&
                        method.parameterTypes[0] == Executor::class.java
                }
            if (setter != null) {
                setter.isAccessible = true
                setter.invoke(callback, callbackExecutor)
                return
            }
            val field = TelephonyCallback::class.java.declaredFields
                .firstOrNull { candidate -> Executor::class.java.isAssignableFrom(candidate.type) }
            field?.isAccessible = true
            field?.set(callback, callbackExecutor)
        } catch (failure: Throwable) {
            Log.d(TAG, "callback executor: ${failure.message}")
        }
    }

    /**
     * The registry call PixelBandInfo makes, for builds where the public
     * registration still will not take.
     */
    private fun listenDirectly(subId: Int, callback: CarrierCallback): Boolean {
        val registry = systemService(REGISTRY_SERVICE, REGISTRY_STUB)
        val listen = registry?.let { findMethod(it, "listenWithEventList", 8) }
        val listener = stateListener(callback)
        if (registry == null || listen == null || listener == null) {
            Log.w(TAG, "no listenWithEventList here; registry methods: ${registrySurface()}")
            return false
        }
        // The event mask has to name the carrier event: an empty array asks
        // the registry for nothing at all, which is what this subscription did
        // when it was copied from PixelBandInfo's call.
        val events = carrierEvent()?.let { value -> intArrayOf(value) } ?: IntArray(0)
        return try {
            listen.isAccessible = true
            listen.invoke(
                registry,
                false,
                false,
                subId,
                callerPackage(),
                "",
                listener,
                events,
                true,
            )
            Log.i(
                TAG,
                "listening on telephony.registry for sub $subId, " +
                    "events=${events.joinToString()}",
            )
            true
        } catch (failure: Throwable) {
            Log.w(TAG, "listenWithEventList failed: ${failure.message}")
            false
        }
    }

    /**
     * Installs the mainline module initialisers `ActivityThread.main` would
     * have run, which is what `TelephonyRegistryManager` needs to find the
     * registry at all.
     */
    private var modulesReady = false

    private fun initializeModules() {
        if (modulesReady) return
        try {
            Class.forName("android.app.ActivityThread")
                .getMethod("initializeMainlineModules")
                .invoke(null)
            modulesReady = true
            Log.d(TAG, "mainline modules initialised")
        } catch (failure: Throwable) {
            Log.d(TAG, "initializeMainlineModules: ${failure.javaClass.simpleName}")
        }
    }

    /** First declared method of [name] with [arity] parameters, up the hierarchy. */
    private fun findMethod(target: Any, name: String, arity: Int): Method? {
        var type: Class<*>? = target.javaClass
        while (type != null) {
            type.declaredMethods
                .firstOrNull { method -> method.name == name && method.parameterTypes.size == arity }
                ?.let { return it }
            type = type.superclass
        }
        return null
    }

    /**
     * A system service as its internal AIDL interface, straight from
     * `ServiceManager` — the route that keeps working when the process was
     * started by Shizuku rather than by the platform.
     */
    private fun systemService(service: String, stub: String): Any? = try {
        val manager = Class.forName("android.os.ServiceManager")
        val binder = manager
            .getMethod("getService", String::class.java)
            .invoke(null, service) as? IBinder
        if (binder == null) {
            null
        } else {
            Class.forName(stub)
                .getMethod("asInterface", IBinder::class.java)
                .invoke(null, binder)
        }
    } catch (failure: Throwable) {
        Log.d(TAG, "$service: ${failure.message}")
        null
    }

    /** The registry event that carries the component carriers. */
    private fun carrierEvent(): Int? = try {
        TelephonyCallback::class.java
            .getField("EVENT_PHYSICAL_CHANNEL_CONFIG_CHANGED")
            .getInt(null)
    } catch (failure: Throwable) {
        Log.d(TAG, "carrier event constant: ${failure.message}")
        null
    }

    /** The package name the registry checks the caller against. */
    private fun callerPackage(): String =
        if (Process.myUid() == 2000) "com.android.shell" else "android"

    /** What the registry offers, for the log when a subscription fails. */
    private fun registrySurface(): List<String> = try {
        systemService(REGISTRY_SERVICE, REGISTRY_STUB)
            ?.javaClass
            ?.methods
            ?.map { method ->
                "${method.name}(${method.parameterTypes.joinToString { it.simpleName }})"
            }
            ?.filter { signature -> "isten" in signature }
            ?.distinct()
            ?: emptyList()
    } catch (error: Throwable) {
        emptyList()
    }

    /** Downlink width in kHz, whichever accessor this release spells. */
    private fun bandwidthKhz(config: Any): Int {
        val downlink = (call(config, "getCellBandwidthDownlink") as? Int)?.takeIf { it > 0 }
        if (downlink != null) return downlink
        return (call(config, "getCellBandwidthDownlinkKhz") as? Int) ?: 0
    }

    /** What this firmware calls its carrier-ish methods, for the log. */
    private fun accessors(tm: TelephonyManager): List<String> = try {
        tm.javaClass.methods
            .map { method -> method.name }
            .filter { name -> "hysical" in name || "arrier" in name }
            .distinct()
    } catch (error: Throwable) {
        emptyList()
    }

    /**
     * Makes the push available to the rest of this class without leaking the
     * platform type into the service, which must load on releases that predate
     * `TelephonyCallback`.
     */
    private class CarrierCallback(
        private val onConfigs: (List<Any>) -> Unit,
    ) : TelephonyCallback(), TelephonyCallback.PhysicalChannelConfigListener {

        override fun onPhysicalChannelConfigChanged(configs: MutableList<PhysicalChannelConfig>) {
            onConfigs(configs.toList())
        }
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

        const val REGISTRY_SERVICE = "telephony.registry"
        const val REGISTRY_STUB = "com.android.internal.telephony.ITelephonyRegistry\$Stub"

        /** Releases before 17 answer this outright; newer ones have no such method. */
        val LIST_METHODS = listOf("getPhysicalChannelConfigs", "getPhysicalChannelConfig")

        /** How long the first read waits for the registry's initial push. */
        const val FIRST_WAIT_MS = 1_500L
        const val WAIT_STEP_MS = 50L
    }
}
