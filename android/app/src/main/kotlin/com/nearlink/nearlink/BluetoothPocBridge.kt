package com.nearlink.nearlink

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.provider.Settings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.UUID
import java.util.ArrayDeque
import java.util.concurrent.Executors

/** E25-B1 debug-only, bonded-peer secure RFCOMM server. No scan, files or IP. */
class BluetoothPocBridge(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val SERVICE_UUID = "c7941b72-4eb5-4a42-a164-25b100004672"
        private const val SERVICE_NAME = "LINYUE E25-B1"
        private const val LIMIT = 65536
    }
    private val channel = MethodChannel(messenger, "nearlink/bluetooth_poc")
    private val lock = Any()
    private var generation = 0
    private var state = "idle"
    private var error = ""
    private var listener: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null
    private var peerId = ""
    private val received = ByteArrayOutputStream()
    private var queued = 0
    private val writer = Executors.newSingleThreadExecutor()
    private var disposed = false
    private val diagnosticStart = SystemClock.elapsedRealtime()
    private val nativeEvents = ArrayDeque<String>()
    private var diagnosticRevision = 0L
    private var lastPollRevision = -1L
    private var registrationReturned = false
    private var acceptEntered = false
    private var fileCommit: Map<String, Any> = emptyMap()
    private var lastObservedPermission: Boolean? = null
    private val adapter get() = activity.getSystemService(BluetoothManager::class.java)?.adapter
    private fun permitted() = Build.VERSION.SDK_INT < 31 ||
        activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun traceLocked(message: String) {
        val clean = message.replace('\n', ' ').replace('\r', ' ').take(280)
        val line = "${SystemClock.elapsedRealtime() - diagnosticStart}ms gen=$generation $clean"
        nativeEvents.addLast(line)
        if (nativeEvents.size > 80) nativeEvents.removeFirst()
        diagnosticRevision += 1
        Log.i("LINYUE_BT", line)
    }
    private fun diagnosticsLocked(): Map<String, Any> = mapOf(
        "platform" to "android", "nativeGeneration" to generation, "phase" to state,
        "serviceUuid" to SERVICE_UUID, "serviceName" to SERVICE_NAME,
        "permission" to permitted(), "sdk" to Build.VERSION.SDK_INT,
        "osRelease" to Build.VERSION.RELEASE, "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL, "listenerOpen" to (listener != null),
        "registrationReturned" to registrationReturned, "acceptEntered" to acceptEntered,
        "connected" to (socket != null),
        "fileCommitStage" to (fileCommit["stage"] ?: "unknown"),
        "fileCommitOperation" to (fileCommit["operation"] ?: "unknown"),
        "fileCommitResult" to (fileCommit["commitResult"] ?: "unknown"),
        "fileCommitException" to (fileCommit["exceptionType"] ?: "unknown"),
        "fileCommitErrno" to (fileCommit["errno"] ?: "unknown"),
        "fileCommitStorage" to (fileCommit["storageType"] ?: "unknown"),
        "fileCommitSourceTag" to (fileCommit["sourceTag"] ?: "unknown"),
        "fileCommitTargetTag" to (fileCommit["targetTag"] ?: "unknown"),
        "fileCommitDirectoryExists" to (fileCommit["targetDirectoryExists"] ?: "unknown"),
        "fileCommitDirectoryWritable" to (fileCommit["targetDirectoryWritable"] ?: "unknown"),
        "fileCommitSameFilesystem" to (fileCommit["sameFilesystem"] ?: "unknown"),
        "fileCommitExpectedBytes" to (fileCommit["expectedBytes"] ?: "unknown"),
        "fileCommitFinalBytes" to (fileCommit["finalBytes"] ?: "unknown"),
        "fileCommitTemporaryHashVerified" to (fileCommit["temporaryHashVerified"] ?: "unknown"),
        "fileCommitFinalHashVerified" to (fileCommit["finalHashVerified"] ?: "unknown"),
        "fileCommitTransferId" to (fileCommit["transferId"] ?: "unknown"),
        "events" to nativeEvents.toList())

    fun noteFileCommit(fields: Map<String, Any>) {
        synchronized(lock) {
            fileCommit=fields.toMap()
            traceLocked("file commit stage=${fields["stage"]} op=${fields["operation"]} result=${fields["commitResult"] ?: "pending"} error=${fields["exceptionType"] ?: "none"} errno=${fields["errno"] ?: "unknown"} reason=${fields["errorReason"] ?: "none"}")
            traceLocked("file storage=${fields["storageType"]} src=${fields["sourceTag"] ?: "unknown"} dst=${fields["targetTag"] ?: fields["inboxTag"] ?: "unknown"} exists=${fields["targetDirectoryExists"] ?: "unknown"} writable=${fields["targetDirectoryWritable"] ?: "unknown"} sameFs=${fields["sameFilesystem"] ?: "unknown"} bytes=${fields["expectedBytes"]} tempHash=${fields["temporaryHashVerified"] ?: "unknown"} finalHash=${fields["finalHashVerified"] ?: "unknown"}")
        }
    }

    fun noteLifecycle(reason: String) {
        synchronized(lock) { traceLocked("$reason listener=${listener != null} accept=$acceptEntered; finishing=${activity.isFinishing} destroyed=${activity.isDestroyed}") }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "openSettings" -> {
                        activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                        result.success(null)
                    }
                    "permission" -> {
                        synchronized(lock) { traceLocked("permission requested; currently=${permitted()} sdk=${Build.VERSION.SDK_INT}") }
                        if (!permitted() && Build.VERSION.SDK_INT >= 31) {
                            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 46750)
                        }
                        result.success(null)
                    }
                    "status" -> {
                        val allowed = permitted()
                        synchronized(lock) {
                            if (lastObservedPermission != allowed) {
                                lastObservedPermission = allowed
                                traceLocked("permission observed=$allowed sdk=${Build.VERSION.SDK_INT}")
                            }
                        }
                        val a = if (allowed) adapter else null
                        result.success(mapOf("permission" to allowed, "radio" to (a?.isEnabled == true),
                            "localName" to (a?.name ?: ""),
                            "devices" to (a?.bondedDevices?.map { mapOf("id" to it.address,
                                "name" to (it.name ?: "未提供蓝牙名称"), "paired" to true) } ?: emptyList<Map<String,Any>>())))
                    }
                    "start" -> {
                        synchronized(lock) { traceLocked("start requested; permission=${permitted()} sdk=${Build.VERSION.SDK_INT}") }
                        check(!disposed) { "Bridge disposed" }
                        check(permitted()) { "BLUETOOTH_CONNECT permission denied" }
                        val a = adapter ?: throw IOException("Bluetooth radio unavailable")
                        check(a.isEnabled) { "Bluetooth is disabled" }
                        val gen = synchronized(lock) {
                            check(state == "idle" || state == "error") { "Server already active" }
                            generation += 1; error = ""; state = "connecting"
                            registrationReturned = false; acceptEntered = false
                            traceLocked("server.register begin secure=true uuid=$SERVICE_UUID name=$SERVICE_NAME")
                            received.reset(); queued = 0; generation
                        }
                        Thread({
                            var stage = "server.register"
                            try {
                                val server = a.listenUsingRfcommWithServiceRecord(SERVICE_NAME, UUID.fromString(SERVICE_UUID))
                                synchronized(lock) {
                                    if (gen != generation) { server.close(); traceLocked("stale server registration closed gen=$gen"); return@Thread }
                                    registrationReturned = true
                                    traceLocked("server.register returned socket; SDP registration API succeeded (remote visibility unverified)")
                                    acceptEntered = true
                                    stage = "server.accept"
                                    traceLocked("server.accept call entry; listener ready")
                                    listener = server; state = "listening"
                                }
                                val peer = server.accept()
                                synchronized(lock) {
                                    acceptEntered = false
                                    val bond = peer.remoteDevice.bondState
                                    traceLocked("server.accept returned; bond=$bond")
                                    server.close()
                                    if (gen != generation) { peer.close(); return@Thread }
                                    listener = null
                                    traceLocked("server listener closed after accept; accepted socket retained")
                                    if (bond != BluetoothDevice.BOND_BONDED) {
                                        peer.close(); throw IOException("Remote device is not OS-bonded")
                                    }
                                    socket = peer; peerId = peer.remoteDevice.address; state = "connected"
                                    traceLocked("secure RFCOMM connected; application authentication still required")
                                }
                                stage = "socket.read"
                                val buffer = ByteArray(4096)
                                while (true) {
                                    val count = peer.inputStream.read(buffer)
                                    if (count < 0) throw IOException("Peer disconnected")
                                    synchronized(lock) {
                                        if (gen != generation) return@Thread
                                        if (received.size() + count > LIMIT) throw IOException("Receive queue exceeded limit")
                                        received.write(buffer, 0, count)
                                    }
                                }
                            } catch (e: Exception) { fail(gen, "RFCOMM stage=$stage: ${e.javaClass.simpleName}: ${e.message}") }
                        }, "LINYUE-RFCOMM-accept-read").start()
                        result.success(gen)
                    }
                    "diagnostics" -> result.success(synchronized(lock) { diagnosticsLocked() })
                    "poll" -> result.success(synchronized(lock) {
                        val bytes = received.toByteArray(); received.reset()
                        val packet = mutableMapOf<String, Any>("generation" to generation, "state" to state, "error" to error, "bytes" to bytes, "peerId" to peerId)
                        if (diagnosticRevision != lastPollRevision) {
                            packet["diagnostics"] = diagnosticsLocked()
                            lastPollRevision = diagnosticRevision
                        }
                        packet
                    })
                    "writeCapacity" -> result.success(synchronized(lock) {
                        mapOf("generation" to generation, "queuedBytes" to queued)
                    })
                    "write" -> {
                        val bytes = call.argument<ByteArray>("bytes") ?: throw IOException("Missing bytes")
                        val gen = call.argument<Int>("generation") ?: -1
                        synchronized(lock) {
                            check(gen == generation && state == "connected") { "Stale/disconnected RFCOMM handle" }
                            check(bytes.isNotEmpty() && bytes.size <= 16384 && queued + bytes.size <= LIMIT) { "Send queue exceeded limit" }
                            queued += bytes.size
                        }
                        writer.execute {
                            try {
                                val peer = synchronized(lock) {
                                    if (gen != generation) return@execute
                                    socket ?: throw IOException("Disconnected")
                                }
                                peer.outputStream.write(bytes)
                                synchronized(lock) { if (gen == generation && state == "connected") queued -= bytes.size }
                            } catch (e: Exception) { fail(gen, "RFCOMM write: ${e.message}") }
                        }
                        result.success(null) // Queue accepted, never a delivery ACK.
                    }
                    "stop" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                synchronized(lock) { traceLocked("method=${call.method} failed ${e.javaClass.simpleName}: ${e.message}") }
                result.error("BLUETOOTH_POC", "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }
    }
    private fun fail(gen: Int, message: String) {
        synchronized(lock) {
            if (generation != gen) return
            error = message; state = "error"
            acceptEntered = false
            traceLocked(message)
            try { listener?.close() } catch (_: Exception) {}
            try { socket?.close() } catch (_: Exception) {}
            listener = null; socket = null; queued = 0
        }
    }
    fun stop() {
        synchronized(lock) {
            traceLocked("stop requested; previous=$state listener=${listener != null} accept=$acceptEntered")
            generation += 1; state = "idle"; error = ""
            registrationReturned = false
            acceptEntered = false
            try { listener?.close() } catch (_: Exception) {}
            try { socket?.close() } catch (_: Exception) {}
            listener = null; socket = null; peerId = ""; queued = 0; received.reset()
        }
    }
    fun dispose(reason: String = "bridge-dispose") {
        noteLifecycle(reason)
        disposed = true; stop(); writer.shutdownNow(); channel.setMethodCallHandler(null)
    }
}
