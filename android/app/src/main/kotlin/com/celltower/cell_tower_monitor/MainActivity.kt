package com.celltower.cell_tower_monitor

import android.Manifest
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var monitor: CellMonitor? = null
    private var bleShare: BleShare? = null
    private var bleWatch: BleWatch? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Carrier detail is optional: this only wires Shizuku's listeners, and
        // does nothing when Shizuku is absent.
        PrivilegedRadio.attach(applicationContext)

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "snapshot" -> result.success(CellSnapshot.build(applicationContext))
                "notificationStatus" -> result.success(
                    mapOf("enabled" to SignalStatusService.isEnabled(applicationContext)),
                )
                "notificationStart" -> {
                    val alias = call.argument<Boolean>("aliasB106") == true
                    val satellites = call.argument<List<String>>("satellitePlmns")?.toSet()
                    val lteMs = call.argument<List<String>>("lteMPlmns")?.toSet()
                    // Remembered here as well as in the intent: the service is
                    // restarted by Android with no extras after a kill.
                    if (satellites != null) {
                        CarrierBrands.saveSatellites(applicationContext, satellites)
                    }
                    if (lteMs != null) CarrierBrands.saveLteMs(applicationContext, lteMs)
                    result.success(startNotification(alias, satellites, lteMs))
                }
                "notificationStop" -> {
                    SignalStatusService.stop(applicationContext)
                    result.success(false)
                }
                // The Settings page's band switches. Stored natively because
                // the pinned service reads them without the Flutter engine.
                "settingsGet" -> result.success(AppSettings.all(applicationContext))
                "settingsSet" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<Boolean>("value")
                    result.success(
                        key != null && value != null &&
                            AppSettings.set(applicationContext, key, value),
                    )
                }
                // The app owns the operator list (it can come from the user's
                // own JSON); the pinned notification needs its own copy.
                "carrierNames" -> {
                    CarrierBrands.save(applicationContext, call.arguments as? Map<*, *>)
                    result.success(true)
                }
                // The last list saved on the device, so the app has names
                // before (or without) a successful fetch.
                "carrierNamesCached" -> result.success(
                    CarrierBrands.stored(applicationContext),
                )
                // Satellite bars offsets that came with that list, cached for
                // the same offline case.
                "carrierBoosts" -> {
                    CarrierBrands.saveBoosts(applicationContext, call.arguments as? Map<*, *>)
                    result.success(true)
                }
                "carrierBoostsCached" -> result.success(
                    CarrierBrands.storedBoosts(applicationContext),
                )
                // The list's `satellite` / `lteM` tags, cached so the shade
                // keeps labelling them with the app closed and offline.
                "carrierSatellites" -> {
                    CarrierBrands.saveSatellites(
                        applicationContext,
                        (call.arguments as? List<*>)?.filterIsInstance<String>(),
                    )
                    result.success(true)
                }
                "carrierLteMs" -> {
                    CarrierBrands.saveLteMs(
                        applicationContext,
                        (call.arguments as? List<*>)?.filterIsInstance<String>(),
                    )
                    result.success(true)
                }

                // Bluetooth sharing and watching.
                "bleShareStart" -> {
                    val share = bleShare ?: BleShare(applicationContext).also { bleShare = it }
                    val started = share.start()
                    result.success(
                        mapOf(
                            "ok" to started,
                            "name" to BleShare.localName(),
                            "error" to share.lastError,
                        ),
                    )
                }
                "bleShareUpdate" -> {
                    val json = call.argument<String>("json")
                    if (json != null) bleShare?.update(json)
                    result.success(true)
                }
                "bleShareStop" -> {
                    bleShare?.stop()
                    result.success(true)
                }
                "bleShareStatus" -> result.success(
                    mapOf(
                        "running" to (bleShare?.isRunning == true),
                        "name" to BleShare.localName(),
                    ),
                )
                "bleScan" -> background(result) {
                    (bleWatch ?: BleWatch(applicationContext).also { bleWatch = it })
                        .scan()
                }
                "bleOpen" -> background(result) {
                    val address = call.argument<String>("address").orEmpty()
                    val watch = bleWatch ?: BleWatch(applicationContext).also { bleWatch = it }
                    watch.open(address)
                }
                "bleRead" -> background(result) {
                    bleWatch?.read()
                }
                "bleClose" -> {
                    bleWatch?.close()
                    result.success(true)
                }

                // Applied updates: the Dart updater hands the APK it
                // downloaded to the package installer. A user who has not
                // granted "install unknown apps" is shown that screen first.
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(false)
                    } else {
                        result.success(
                            try {
                                startApkInstall(applicationContext, path)
                                true
                            } catch (error: Exception) {
                                Log.w(TAG, "APK install failed: ${error.message}")
                                false
                            },
                        )
                    }
                }
                "appVersion" -> result.success(
                    try {
                        applicationContext.packageManager
                            .getPackageInfo(applicationContext.packageName, 0)
                            .versionName
                    } catch (error: Exception) {
                        Log.w(TAG, "Version read failed: ${error.message}")
                        null
                    },
                )

                // Android can freeze a backgrounded app (Doze and OEM battery
                // managers), which is what makes the pinned notification go
                // stale. Exempting the app is the only supported fix.
                "backgroundExempt" -> result.success(isBatteryExempt())
                "backgroundExemptRequest" -> result.success(requestBatteryExemption())

                // Carrier detail through Shizuku. `carrierDetailStatus` is
                // also the grant entry point: the Settings page asks, then
                // polls the same call until the state turns ready.
                "carrierDetailStatus" -> result.success(
                    PrivilegedRadio.status(applicationContext),
                )
                "carrierDetailRequest" -> {
                    PrivilegedRadio.requestPermission(applicationContext)
                    result.success(PrivilegedRadio.status(applicationContext))
                }
                // Opening Shizuku is how a user starts it over wireless
                // debugging, so the Settings row can point at it.
                "carrierDetailOpen" -> result.success(
                    try {
                        packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
                            ?.let { startActivity(it) }
                        true
                    } catch (error: Exception) {
                        Log.w(TAG, "Shizuku launch failed: ${error.message}")
                        false
                    },
                )

                else -> result.notImplemented()
            }
        }

        // A notification left switched on stays on across app restarts; bring it
        // back if Android allows it to be shown. The band-106 flag it was last
        // started with is kept by the service.
        if (SignalStatusService.isEnabled(applicationContext)) {
            startNotification(alias = null, satellites = null, lteMs = null)
        }

        val cellMonitor = CellMonitor(applicationContext)
        monitor = cellMonitor
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(cellMonitor)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        monitor?.stop()
        monitor = null
        bleWatch?.close()
        bleWatch = null
        bleShare?.stop()
        bleShare = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** Runs a blocking Bluetooth call off the UI thread and replies on it. */
    private fun <T> background(
        result: MethodChannel.Result,
        block: () -> T,
    ) {
        Thread {
            val value = try {
                block()
            } catch (error: Exception) {
                Log.w(TAG, "Bluetooth call failed: ${error.message}")
                null
            }
            main.post { result.success(value) }
        }.apply { isDaemon = true }.start()
    }

    /**
     * Opens the downloaded update APK in the package installer. Android only
     * allows installs from outside a store once the user has granted "install
     * unknown apps", which is asked for first.
     */
    private fun startApkInstall(context: Context, path: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            return
        }
        val uri = FileProvider.getUriForFile(
            context,
            "$packageName.fileprovider",
            java.io.File(path),
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK,
                )
            },
        )

    }

    private fun isBatteryExempt(): Boolean {
        val power = getSystemService(PowerManager::class.java) ?: return false
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Opens the system prompt that exempts this app from battery optimisation.
     * Without it Android freezes the app while it is in the background and the
     * pinned notification stops updating.
     */
    private fun requestBatteryExemption(): Boolean {
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        )
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        return try {
            startActivity(direct)
            true
        } catch (error: Exception) {
            try {
                startActivity(list)
                true
            } catch (fallback: Exception) {
                Log.w(TAG, "No battery-optimisation screen: ${fallback.message}")
                false
            }
        }
    }

    /**
     * Starts the pinned notification. A null [alias] means "whatever it was
     * last started with", which is how the restart path keeps the A10e build's
     * band-106 numbering without the service knowing about Dart constants.
     */
    private fun startNotification(
        alias: Boolean?,
        satellites: Set<String>?,
        lteMs: Set<String>?,
    ): Boolean {
        if (!notificationsAllowed()) return false
        SignalStatusService.start(applicationContext, alias, satellites, lteMs)
        return true
    }

    /** POST_NOTIFICATIONS, which only exists from Android 13. */
    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private companion object {
        const val TAG = "MainActivity"
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        const val METHOD_CHANNEL = "cell_tower/monitor"
        const val EVENT_CHANNEL = "cell_tower/stream"
    }
}
