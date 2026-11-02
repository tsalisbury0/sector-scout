package com.celltower.cell_tower_monitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Keeps the current SIM's signal in a pinned notification.
 *
 * A foreground service is the only way Android lets an app hold a notification
 * the user cannot swipe away: the notification is `setOngoing`, has no dismiss
 * action, and the service outlives the app's screen (and the task being swiped
 * out of Recents). Nothing here can survive an app force-stop, or the **Stop**
 * button in Android 13+'s *Active apps* panel — that is the OS, not this app.
 *
 * The reading comes from [CellSnapshot] directly, so the notification keeps
 * updating with the app closed.
 */
class SignalStatusService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var aliasB106 = false

    private val tick = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, UPDATE_MS)
        }
    }

    /**
     * Refreshes the moment the phone is picked up.
     *
     * The 10 s tick still runs, but while the CPU is asleep it is suspended, so
     * without this the shade shows the reading from just before the screen went
     * off until the next tick lands.
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            refresh()
        }
    }

    override fun onCreate() {
        super.onCreate()
        aliasB106 = prefs(this).getBoolean(KEY_ALIAS, false)
        // Android restarts a START_STICKY service with a null intent after it
        // kills the process, so the tags come from the cache it last saw.
        _satellites.addAll(CarrierBrands.storedSatellites(this))
        _lteMs.addAll(CarrierBrands.storedLteMs(this))
        // The notification draws itself and outlives the app, so it owns the
        // NR Advanced tracking too: without this, 5G+ only exists while the
        // Activity is alive, and the shade falls back to plain 5G (or the LTE
        // anchor) once the app is off screen or has been killed.
        DisplayInfoTracker.acquire(this)
        createChannel()
        startForegroundCompat(notificationFor(null))
        registerScreenReceiver()
        handler.post(tick)
    }

    private fun registerScreenReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, filter)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Screen-on refresh unavailable: ${e.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let { aliasB106 = it.getBooleanExtra(EXTRA_ALIAS, aliasB106) }
        intent?.let {
            refreshTags(_satellites, it.getStringArrayExtra(EXTRA_SATELLITES))
            refreshTags(_lteMs, it.getStringArrayExtra(EXTRA_LTE_MS))
        }
        // Committed, not applied: the process can be killed (app update, low
        // memory) moments later, and an async write would lose the switch state.
        prefs(this).edit()
            .putBoolean(KEY_ENABLED, true)
            .putBoolean(KEY_ALIAS, aliasB106)
            .apply()
        refresh()
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        DisplayInfoTracker.release()
        try {
            unregisterReceiver(screenReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Unregistering the screen receiver failed: ${e.message}")
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------------
    // Reading and drawing
    // ------------------------------------------------------------------

    /**
     * The operator list's `satellite` / `lteM` tags, re-read every tick.
     *
     * They arrive over the method channel — which stores them and returns — so
     * a tag that lands after this service started would otherwise never reach a
     * running instance: the sets were only seeded in [onCreate] and from the
     * start intent. Reading them back each update keeps the shade's wording in
     * step with the list the app is using.
     */
    private fun refreshTagsFromStore() {
        _satellites.clear()
        _satellites.addAll(CarrierBrands.storedSatellites(this))
        _lteMs.clear()
        _lteMs.addAll(CarrierBrands.storedLteMs(this))
    }

    /** One modem read per update: the lines and the slot tag come from it. */
    private fun refresh() {
        refreshTagsFromStore()
        // The Anterix B106 switch can be flipped while this service runs, so the
        // flag is read here rather than only at start-up.
        aliasB106 = AppSettings.anterixB106(applicationContext)
        val snapshot = try {
            CellSnapshot.build(applicationContext)
        } catch (e: Exception) {
            Log.w(TAG, "Reading for the notification failed: ${e.message}")
            null
        }
        // The Settings page's band switches are read each tick, so flipping one
        // reaches the shade without restarting the service.
        val lines = snapshot?.let {
            SignalSummary.of(
                it,
                aliasB106,
                CarrierBrands.table(applicationContext),
                _satellites,
                _lteMs,
                AppSettings.corrections(applicationContext),
            )
        }
        val manager = getSystemService(NotificationManager::class.java)
        try {
            manager?.notify(NOTIFICATION_ID, notificationFor(lines))
        } catch (e: Exception) {
            Log.w(TAG, "Notification update failed: ${e.message}")
        }
    }

    private fun notificationFor(lines: SignalSummary.Lines?): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val badge = lines?.badge
        val crispIcon = if (badge != null) {
            SignalIcon.icon(this, badge)
        } else {
            Icon.createWithResource(this, R.drawable.ic_stat_signal)
        }

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(crispIcon)
            .setContentTitle(lines?.title ?: "Sector Scout")
            .setContentText(lines?.text ?: "Waiting for a cell reading…")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    lines?.detail ?: "The modem has not reported a served cell yet.",
                ),
            )
            // Pinned: no swipe-away, and it only alerts once.
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setColor(COLOUR)
            .setContentIntent(open)
            .setSubText(lines?.slotLabel)
            .apply {
                // From Android 13 the shade draws its own icon for a foreground
                // service on One UI, so the badge is repeated at content size
                // there. Older shades render the small icon faithfully and a
                // second one would just read as a duplicate.
                if (badge != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    setLargeIcon(SignalIcon.large(this@SignalStatusService, badge))
                }
            }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Show it straight away instead of after the usual 10 s grace.
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    /**
     * Starts in the foreground with the `location` type, so cell reads keep
     * working while the app is off screen.
     *
     * Android gates cell identities behind location, and a while-in-use grant
     * only covers an app the system considers in use. A service typed `location`
     * is in use for that purpose; `specialUse` — which is all this service used
     * to claim — is not, which is why the pinned notification used to fall back
     * to "Waiting for a cell reading…" a few seconds after the screen went off.
     *
     * Android 14+ refuses to *start* a location service from the background when
     * the app has no background-location grant, which is the case after the
     * process is killed and restarted. That start throws; the reading is then
     * unavailable anyway, so the service falls back to `specialUse` and keeps
     * the last drawn notification rather than dying.
     */
    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        val location = ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        val specialUse = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            location or specialUse
        } else {
            location
        }
        try {
            startForeground(NOTIFICATION_ID, notification, types)
        } catch (e: Exception) {
            Log.w(TAG, "Location service type refused (${e.message}); keeping it pinned without it")
            try {
                startForeground(NOTIFICATION_ID, notification, specialUse)
            } catch (fallback: Exception) {
                Log.w(TAG, "specialUse refused too: ${fallback.message}")
                startForeground(NOTIFICATION_ID, notification)
            }
        }
    }

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Live signal",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "The serving cell and signal level, kept pinned in the shade."
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "SignalStatusService"
        private const val CHANNEL_ID = "signal_status"
        private const val NOTIFICATION_ID = 4310
        // Matches CellMonitor's poll, so the shade is never more than one app
        // refresh behind the screen.
        private const val UPDATE_MS = 2_500L
        private const val COLOUR = 0xFF34D399.toInt()

        private const val KEY_ENABLED = "signal_notification_enabled"
        private const val KEY_ALIAS = "signal_notification_alias_b106"
        private const val KEY_SATELLITES = "signal_notification_satellites"
        private const val EXTRA_ALIAS = "alias_b106"
        private const val EXTRA_SATELLITES = "satellite_plmns"
        private const val EXTRA_LTE_MS = "lte_m_plmns"

        private fun prefs(context: Context) =
            context.getSharedPreferences("signal_status", Context.MODE_PRIVATE)

        /** True when the user has left the notification switched on. */
        fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

        /**
         * Starts (or re-starts) the notification. A null [aliasB106] keeps the
         * numbering the service was last started with, which is what the app's
         * restart path wants.
         */
        fun start(
            context: Context,
            aliasB106: Boolean?,
            satellites: Set<String>?,
            lteMs: Set<String>?,
        ) {
            val alias = aliasB106 ?: prefs(context).getBoolean(KEY_ALIAS, false)
            // Committed before the service starts: these flags are what restores
            // the notification after the app is killed or updated.
            prefs(context).edit()
                .putBoolean(KEY_ENABLED, true)
                .putBoolean(KEY_ALIAS, alias)
                .apply()
            val intent = Intent(context, SignalStatusService::class.java)
                .putExtra(EXTRA_ALIAS, alias)
                .putExtra(EXTRA_SATELLITES, satellites?.toTypedArray())
                .putExtra(EXTRA_LTE_MS, lteMs?.toTypedArray())
            context.startForegroundService(intent)
        }

        /** PLMNs the operator list flags `satellite` and `lteM`. */
        private val _satellites = mutableSetOf<String>()
        private val _lteMs = mutableSetOf<String>()

        /**
         * Replaces a tag set from the intent extras Android delivered.
         *
         * A null array means this start carried no tags (the restart path), so
         * whatever was cached in [onCreate] stays in use.
         */
        private fun refreshTags(target: MutableSet<String>, values: Array<String>?) {
            if (values == null) return
            target.clear()
            target.addAll(values.toList())
        }

        fun stop(context: Context) {
            prefs(context).edit().putBoolean(KEY_ENABLED, false).commit()
            context.stopService(Intent(context, SignalStatusService::class.java))
        }
    }
}
