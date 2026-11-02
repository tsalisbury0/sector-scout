package com.celltower.cell_tower_monitor

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The reading side of [BleShare]: finds a nearby sharing phone, connects to it,
 * and reassembles its JSON.
 *
 * Every method here blocks, so the app calls them from a background thread.
 * A connection is kept open between reads — polling a peer every couple of
 * seconds over GATT is otherwise a fresh connect each time, which Bluetooth
 * does not tolerate well.
 */
class BleWatch(private val context: Context) {

    companion object {
        private const val TAG = "BleWatch"
        private const val SCAN_MS = 6_000L
        private const val CONNECT_TIMEOUT_MS = 12_000L
        private const val READ_TIMEOUT_MS = 4_000L
        private const val MAX_CHUNKS = 255

        /** True when this build may scan and connect. */
        fun hasPermissions(context: Context): Boolean {
            fun granted(permission: String) =
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!granted(Manifest.permission.BLUETOOTH_CONNECT)) return false
                if (!granted(Manifest.permission.BLUETOOTH_SCAN)) return false
            }
            return true
        }
    }

    private var gatt: BluetoothGatt? = null

    /** Released once the service is discovered, or the link fails. */
    @Volatile private var ready = CountDownLatch(1)

    @Volatile private var connected = false
    @Volatile private var connectionError: String? = null

    @Volatile private var readLatch: CountDownLatch? = null
    @Volatile private var readValue: ByteArray? = null

    @Volatile private var writeLatch: CountDownLatch? = null

    // ------------------------------------------------------------------
    // Discovery
    // ------------------------------------------------------------------

    /** Scanning phones, strongest first. Empty when none answered. */
    @SuppressLint("MissingPermission")
    fun scan(seconds: Long = SCAN_MS / 1000): List<Map<String, Any?>> {
        if (!hasPermissions(context)) return emptyList()
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()
        val scanner = try {
            adapter.bluetoothLeScanner
        } catch (error: SecurityException) {
            null
        } ?: return emptyList()

        val found = LinkedHashMap<String, Map<String, Any?>>()
        val finished = CountDownLatch(1)

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                add(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::add)
            }

            private fun add(result: ScanResult) {
                val device = result.device ?: return
                val name = try {
                    device.name
                } catch (error: SecurityException) {
                    null
                }
                found[device.address] = mapOf(
                    "address" to device.address,
                    "name" to (name ?: result.scanRecord?.deviceName ?: ""),
                    "rssi" to result.rssi,
                )
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "Scan failed ($errorCode)")
                finished.countDown()
            }
        }

        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(BleShare.SERVICE))
                .build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()

        try {
            scanner.startScan(filters, settings, callback)
        } catch (error: SecurityException) {
            return emptyList()
        } catch (error: Exception) {
            Log.w(TAG, "Scan could not start: ${error.message}")
            return emptyList()
        }

        // The latch is only released on a scan failure, so a normal scan runs
        // for the full window before the list is handed back.
        finished.await(seconds, TimeUnit.SECONDS)
        try {
            scanner.stopScan(callback)
        } catch (error: Exception) {
            Log.w(TAG, "Stopping the scan failed: ${error.message}")
        }
        return found.values.sortedByDescending { (it["rssi"] as? Int) ?: Int.MIN_VALUE }
    }

    // ------------------------------------------------------------------
    // Connection
    // ------------------------------------------------------------------

    /**
     * Connects and discovers the service. Returns an empty map on success, or
     * `{error}` when the peer could not be reached.
     */
    @SuppressLint("MissingPermission")
    fun open(address: String): Map<String, Any?> {
        close()
        if (!hasPermissions(context)) {
            return mapOf("error" to "Bluetooth permissions are missing.")
        }
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: return mapOf("error" to "This phone has no Bluetooth adapter.")
        if (!adapter.isEnabled) {
            return mapOf("error" to "Bluetooth is off — turn it on to connect.")
        }

        val device = try {
            adapter.getRemoteDevice(address)
        } catch (error: Exception) {
            return mapOf("error" to "That Bluetooth address is not valid.")
        }

        connectionError = null
        connected = false
        ready = CountDownLatch(1)
        val gattClient = try {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (error: Exception) {
            return mapOf("error" to "Connecting over Bluetooth failed: ${error.message}")
        }
        gatt = gattClient

        if (!ready.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            close()
            return mapOf(
                "error" to (connectionError
                    ?: "The other phone did not answer over Bluetooth."),
            )
        }
        if (!connected) {
            close()
            return mapOf(
                "error" to (connectionError ?: "The other phone refused the connection."),
            )
        }

        // A larger MTU lets the peer send ~500-byte chunks instead of 20-byte
        // ones; the read loop works either way, so this is best effort.
        try {
            gattClient.requestMtu(517)
            Thread.sleep(600)
        } catch (error: Exception) {
            Log.w(TAG, "MTU request failed: ${error.message}")
        }

        val name = try {
            device.name ?: address
        } catch (error: SecurityException) {
            address
        }
        return mapOf("name" to (name))
    }

    /** The peer's snapshot JSON, or null when it has none yet or the link broke. */
    fun read(): String? {
        val gattClient = gatt ?: return null
        val service: BluetoothGattService? = try {
            gattClient.getService(BleShare.SERVICE)
        } catch (error: Exception) {
            null
        }
        val characteristic = service?.getCharacteristic(BleShare.DATA) ?: return null

        repeat(2) {
            writeReset(gattClient)
            val chunks = HashMap<Int, ByteArray>()
            var total = 0
            var guard = 0

            while (guard++ <= MAX_CHUNKS + 2) {
                val value = readOnce(gattClient, characteristic) ?: return@repeat
                if (value.size < 2) return@repeat
                val index = value[0].toInt() and 0xFF
                total = value[1].toInt() and 0xFF
                if (total == 0) return null
                if (index < total) chunks[index] = value.copyOfRange(2, value.size)
                if (chunks.size == total) {
                    val out = ByteArrayOutputStream()
                    for (i in 0 until total) {
                        val chunk = chunks[i] ?: return@repeat
                        out.write(chunk)
                    }
                    return String(out.toByteArray(), Charsets.UTF_8)
                }
            }
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun readOnce(
        gattClient: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ): ByteArray? {
        val latch = CountDownLatch(1)
        readValue = null
        readLatch = latch

        val started = try {
            @Suppress("DEPRECATION")
            gattClient.readCharacteristic(characteristic)
        } catch (error: Exception) {
            false
        }
        if (!started) {
            readLatch = null
            return null
        }
        if (!latch.await(READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            readLatch = null
            return null
        }
        readLatch = null
        return readValue
    }

    @SuppressLint("MissingPermission")
    private fun writeReset(gattClient: BluetoothGatt) {
        val characteristic = try {
            gattClient.getService(BleShare.SERVICE)?.getCharacteristic(BleShare.RESET)
        } catch (error: Exception) {
            null
        } ?: return

        val latch = CountDownLatch(1)
        writeLatch = latch
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gattClient.writeCharacteristic(
                    characteristic,
                    byteArrayOf(0),
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    characteristic.writeType =
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    characteristic.value = byteArrayOf(0)
                    gattClient.writeCharacteristic(characteristic)
                }
            }
        } catch (error: Exception) {
            false
        }
        if (!started) {
            writeLatch = null
            return
        }
        latch.await(2, TimeUnit.SECONDS)
        writeLatch = null
    }

    @SuppressLint("MissingPermission")
    fun close() {
        val gattClient = gatt
        gatt = null
        connected = false
        try {
            gattClient?.disconnect()
            gattClient?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Closing the Bluetooth link failed: ${error.message}")
        }
    }

    // ------------------------------------------------------------------
    // GATT client
    // ------------------------------------------------------------------

    private val callback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(
            gattClient: BluetoothGatt,
            status: Int,
            newState: Int,
        ) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connected = true
                    try {
                        gattClient.discoverServices()
                    } catch (error: SecurityException) {
                        connectionError = "Bluetooth permission was revoked."
                        ready.countDown()
                    }
                }

                BluetoothProfile.STATE_DISCONNECTED -> {
                    connected = false
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        connectionError = when (status) {
                            133 -> "The other phone dropped the connection (133)."
                            else -> "The Bluetooth link closed (status $status)."
                        }
                    }
                    ready.countDown()
                    readLatch?.countDown()
                    writeLatch?.countDown()
                }
            }
        }

        override fun onServicesDiscovered(gattClient: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                connectionError = "The other phone did not expose its service."
                connected = false
            }
            ready.countDown()
        }

        // Android 13+ delivers the value here; older releases land in the
        // three-argument overload below.
        override fun onCharacteristicRead(
            gattClient: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            deliver(if (status == BluetoothGatt.GATT_SUCCESS) value else null)
        }

        @Suppress("DEPRECATION", "OverridingDeprecatedMember")
        override fun onCharacteristicRead(
            gattClient: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            deliver(
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    @Suppress("DEPRECATION")
                    characteristic.value
                } else {
                    null
                },
            )
        }

        override fun onCharacteristicWrite(
            gattClient: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            writeLatch?.countDown()
        }

        private fun deliver(value: ByteArray?) {
            readValue = value
            readLatch?.countDown()
        }
    }
}
