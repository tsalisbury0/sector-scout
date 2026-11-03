package com.celltower.cell_tower_monitor

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Publishes this phone's reading over Bluetooth Low Energy, for the case the
 * Wi-Fi share cannot cover: no network to join, or the phones are out of range
 * of an access point.
 *
 * It is a plain GATT server advertising one service. Reading it returns the same
 * JSON the HTTP endpoint serves, in chunks:
 *
 *  - every read answers `[index, total, ...bytes]`, where `total` is the number
 *    of chunks in the current payload and bytes are the payload slice;
 *  - the server keeps a per-client cursor, so a client reads `total` times in a
 *    row and reassembles; a lost read is recovered by writing to [RESET], which
 *    rewinds that client to the first chunk.
 *
 * Chunk size follows the client's negotiated MTU, so a phone that never
 * negotiates still works at 20-byte reads.
 */
class BleShare(private val context: Context) {

    companion object {
        /** Service advertised by every sharing phone. */
        val SERVICE: UUID = UUID.fromString("d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d00")

        /** Read repeatedly to receive the payload. */
        val DATA: UUID = UUID.fromString("d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d01")

        /** Write anything to rewind this client to the first chunk. */
        val RESET: UUID = UUID.fromString("d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d02")

        /** Upper bound on a chunk, so one payload never spans 255 readings. */
        private const val CHUNK_CAP = 480

        private const val TAG = "BleShare"

        /** Name shown by the other phone, e.g. `SM-S931U`. */
        fun localName(): String = Build.MODEL.ifBlank { "Android" }

        /** True when this build has the Bluetooth permissions it needs. */
        fun hasPermissions(context: Context): Boolean {
            fun granted(permission: String) =
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!granted(Manifest.permission.BLUETOOTH_CONNECT)) return false
                if (!granted(Manifest.permission.BLUETOOTH_ADVERTISE)) return false
            }
            return true
        }
    }

    private val cursors = ConcurrentHashMap<String, Int>()
    /** The payload each client is part-way through, pinned at its first chunk. */
    private val readings = ConcurrentHashMap<String, ByteArray>()
    private val mtus = ConcurrentHashMap<String, Int>()

    @Volatile private var payload: ByteArray = ByteArray(0)
    private var server: BluetoothGattServer? = null
    private var advertising = false
    private var advertiseCallback: AdvertiseCallback? = null

    /** Why the last [start] failed, for the app to show. */
    var lastError: String? = null
        private set

    val isRunning: Boolean get() = server != null && advertising

    /**
     * Replaces the payload.
     *
     * Cursors are deliberately left alone: a client that is half-way through
     * a reading finishes the one it started on, and its next read from the
     * first chunk picks this one up. Clearing them here restarted every
     * client mid-payload, which spliced two readings into JSON no reader
     * could parse at a small MTU, where a reading takes many chunks.
     */
    fun update(json: String) {
        payload = json.toByteArray(Charsets.UTF_8)
    }

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (isRunning) return true
        lastError = null

        if (!hasPermissions(context)) {
            lastError = "Bluetooth permissions are missing."
            return false
        }
        val manager = context.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter
        if (manager == null || adapter == null) {
            lastError = "This phone has no Bluetooth adapter."
            return false
        }
        if (!adapter.isEnabled) {
            lastError = "Bluetooth is off — turn it on to share."
            return false
        }

        try {
            val gattServer = manager.openGattServer(context, serverCallback)
            if (gattServer == null) {
                lastError = "Android would not open a Bluetooth server."
                return false
            }
            val service = BluetoothGattService(
                SERVICE,
                BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )
            service.addCharacteristic(
                BluetoothGattCharacteristic(
                    DATA,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ,
                ),
            )
            service.addCharacteristic(
                BluetoothGattCharacteristic(
                    RESET,
                    BluetoothGattCharacteristic.PROPERTY_WRITE,
                    BluetoothGattCharacteristic.PERMISSION_WRITE,
                ),
            )
            if (!gattServer.addService(service)) {
                gattServer.close()
                lastError = "Android rejected the Bluetooth service."
                return false
            }
            server = gattServer
            return advertise(adapter)
        } catch (error: SecurityException) {
            lastError = "Bluetooth permissions were revoked."
            Log.w(TAG, "Starting the share failed: ${error.message}")
            return false
        } catch (error: Exception) {
            lastError = "Bluetooth sharing failed: ${error.message}"
            Log.w(TAG, "Starting the share failed: ${error.message}")
            return false
        }
    }

    @SuppressLint("MissingPermission")
    private fun advertise(adapter: android.bluetooth.BluetoothAdapter): Boolean {
        val advertiser = try {
            adapter.bluetoothLeAdvertiser
        } catch (error: SecurityException) {
            null
        }
        if (advertiser == null) {
            lastError = "This phone cannot advertise over Bluetooth LE."
            return false
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // The advertisement carries only the service UUID, because a 128-bit
        // UUID plus the name would not fit the 31-byte legacy packet. The name
        // goes in the scan response, the packet that exists for exactly this —
        // without it the other phone lists this one by Bluetooth address.
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE))
            .setIncludeDeviceName(false)
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                advertising = true
            }

            override fun onStartFailure(errorCode: Int) {
                advertising = false
                lastError = when (errorCode) {
                    ADVERTISE_FAILED_DATA_TOO_LARGE ->
                        "The Bluetooth advertisement is too large."
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS ->
                        "Another app is already advertising on this phone."
                    ADVERTISE_FAILED_ALREADY_STARTED ->
                        "This phone is already advertising."
                    ADVERTISE_FAILED_INTERNAL_ERROR ->
                        "Android could not start the Bluetooth advertisement."
                    else -> "Bluetooth sharing could not start (code $errorCode)."
                }
            }
        }
        advertiseCallback = callback
        advertiser.startAdvertising(settings, data, scanResponse, callback)
        return true
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        val callback = advertiseCallback
        advertiseCallback = null
        if (callback != null) {
            try {
                context.getSystemService(BluetoothManager::class.java)
                    ?.adapter
                    ?.bluetoothLeAdvertiser
                    ?.stopAdvertising(callback)
            } catch (error: Exception) {
                Log.w(TAG, "Stopping the advertisement failed: ${error.message}")
            }
        }
        advertising = false
        try {
            server?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Closing the Bluetooth server failed: ${error.message}")
        }
        server = null
        cursors.clear()
        readings.clear()
        mtus.clear()
    }

    // ------------------------------------------------------------------
    // GATT server
    // ------------------------------------------------------------------

    private val serverCallback = object : BluetoothGattServerCallback() {

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "Service registration answered status $status")
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            mtus[device.address] = mtu
        }

        override fun onConnectionStateChange(
            device: BluetoothDevice,
            status: Int,
            newState: Int,
        ) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cursors.remove(device.address)
                readings.remove(device.address)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val gatt = server
            if (gatt == null) {
                respond(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }
            if (characteristic.uuid != DATA) {
                respond(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }
            if (offset != 0) {
                // The client asks for whole chunks, never a continuation.
                respond(
                    device,
                    requestId,
                    BluetoothGatt.GATT_INVALID_OFFSET,
                    offset,
                    null,
                )
                return
            }

            // A client that starts a payload pins the bytes it will be served:
            // the first chunk of a reading is where the snapshot is taken, so a
            // new reading arriving half-way through cannot change the ones
            // already sent.
            val cursor = cursors[device.address] ?: 0
            val data = if (cursor == 0) {
                payload.also { readings[device.address] = it }
            } else {
                readings[device.address]
                    ?: payload.also { readings[device.address] = it }
            }
            val chunk = ((mtus[device.address] ?: 23) - 3).coerceIn(16, CHUNK_CAP)
            val total = (data.size + chunk - 1) / chunk
            if (data.isEmpty() || total == 0) {
                // Nothing to send yet: index 0 of 0.
                respond(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    byteArrayOf(0, 0),
                )
                return
            }

            val start = cursor.let { if (it >= total) 0 else it }
            cursors[device.address] = (start + 1) % total

            val from = start * chunk
            val to = minOf(from + chunk, data.size)
            val frame = ByteArray(2 + (to - from))
            frame[0] = start.toByte()
            frame[1] = total.toByte()
            System.arraycopy(data, from, frame, 2, to - from)
            respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, frame)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (characteristic.uuid == RESET) {
                cursors[device.address] = 0
                readings.remove(device.address)
                if (responseNeeded) {
                    respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                }
                return
            }
            if (responseNeeded) {
                respond(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
            }
        }

        private fun respond(
            device: BluetoothDevice,
            requestId: Int,
            status: Int,
            offset: Int,
            value: ByteArray?,
        ) {
            try {
                server?.sendResponse(device, requestId, status, offset, value)
            } catch (error: Exception) {
                Log.w(TAG, "Answering a Bluetooth read failed: ${error.message}")
            }
        }
    }
}
