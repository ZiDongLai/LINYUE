package com.nearlink.nearlink

import android.app.Activity
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import java.io.File
import java.io.IOException

/** FIX1: private same-filesystem rename; no hard/symbolic links or copy fallback. */
object BluetoothReceivedFileCommit {
    class CommitFailure(val friendly: String, val diagnostic: Map<String, Any>, cause: Exception) : IOException(friendly, cause)

    fun commit(activity: Activity, path: String?, name: String?, size: Long, sha: String?,
        transferId: String? = null, commitNonce: String? = null, verifyOnly: Boolean = false, observe: (Map<String, Any>) -> Unit = {}): Map<String, Any> {
        val snapshot = mutableMapOf<String, Any>("stage" to "android_path_gate", "operation" to "private-root-resolution",
            "storageType" to "app-private-internal", "expectedBytes" to size,
            "transferId" to (transferId?.takeIf { Regex("^[a-f0-9]{32}$").matches(it) } ?: "unknown"))
        try {
            check((activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) { "Debug Bluetooth files only" }
            val root = File(activity.applicationInfo.dataDir, "app_flutter").canonicalFile
            val work = File(root, "LinYueBluetoothE32").canonicalFile
            val inbox = File(root, "NearLinkReceived").canonicalFile
            if (work.parentFile != root || inbox.parentFile != root) throw IOException("private-root-alias-refused")
            val file = File(path ?: throw IOException("missing-staged-file"))
            val operations =
                object : BluetoothFilePublisher.Operations {
                    override fun sameFileSystem(source: File, directory: File): Boolean =
                        Os.stat(source.path).st_dev == Os.stat(directory.path).st_dev
                    override fun identity(file: File): String {
                        val stat=Os.stat(file.path); return "${stat.st_dev}:${stat.st_ino}"
                    }
                    override fun rename(source: File, target: File) {
                        if (target.exists()) throw IOException("target-already-exists")
                        // Local random target under one commit lock, same device checked above.
                        Os.rename(source.path, target.path)
                    }
                    override fun syncDirectory(directory: File) {
                        if (!directory.isDirectory) throw IOException("sync-directory-missing")
                        val fd=Os.open(directory.path,OsConstants.O_RDONLY,0)
                        try { Os.fsync(fd) } finally { Os.close(fd) }
                    }
                    override fun writable(directory: File): Boolean = directory.canWrite()
                }
            val diagnostics = BluetoothFilePublisher.Diagnostics { fields ->
                    snapshot.clear(); snapshot.putAll(fields)
                    snapshot["transferId"] = transferId?.takeIf { Regex("^[a-f0-9]{32}$").matches(it) } ?: "unknown"
                    observe(snapshot.toMap())
                }
            val saved = if (verifyOnly) {
                snapshot["stage"]="verify_committed";snapshot["operation"]="sha256-file-sync-directory-sync";observe(snapshot.toMap())
                BluetoothFilePublisher.verifyReserved(inbox,name,size,sha,operations,commitNonce)
            } else if (commitNonce == null) BluetoothFilePublisher.publish(work,inbox,file,name,size,sha,operations,diagnostics)
                else BluetoothFilePublisher.publishReserved(work,inbox,file,name,size,sha,operations,diagnostics,commitNonce)
            return mapOf("path" to saved.path,"size" to size,"sha256" to (sha ?: ""))
        } catch (e: Exception) {
            if (e is BluetoothFilePublisher.Failure) snapshot.putAll(e.details)
            val original = if (e is BluetoothFilePublisher.Failure) e.cause ?: e else e
            val errno = generateSequence(original) { it.cause }.filterIsInstance<ErrnoException>().firstOrNull()
            snapshot["commitResult"]="failed"
            snapshot["exceptionType"]=original.javaClass.name
            snapshot["errnoKnown"] = errno != null
            if (errno != null) {
                snapshot["errno"]=errno.errno
                snapshot["errorReason"]=errno.message ?: "errno=${errno.errno}: ${Os.strerror(errno.errno)}"
            } else if (!snapshot.containsKey("errorReason")) {
                snapshot["errorReason"]="native-validation-failed (path redacted)"
            }
            val stage=snapshot["stage"].toString()
            val reason=snapshot["errorReason"].toString()
            val friendly=when {
                errno?.errno == OsConstants.ENOSPC -> "手机存储空间不足，文件未完成保存。"
                errno?.errno == OsConstants.EACCES || errno?.errno == OsConstants.EPERM -> "手机保存权限受限，文件未完成保存。"
                stage == "verify_temporary" || stage == "verify_final" -> "手机文件完整性校验未通过，文件未确认保存。"
                stage == "prepare_inbox" -> "手机接收目录不可写或不可用，文件未完成保存。"
                stage == "same_filesystem" -> "手机暂存与接收存储区域不兼容，文件未完成保存。"
                stage.startsWith("sync_") -> "手机文件持久化失败，文件未确认保存。"
                stage == "atomic_rename" -> "手机文件移动失败，文件未完成保存。"
                reason.contains("missing") -> "手机暂存文件不可用，文件未完成保存。"
                else -> "手机保存文件失败，请重新发送并保留诊断。"
            }
            observe(snapshot.toMap())
            throw CommitFailure(friendly,snapshot.toMap(),e)
        }
    }
}
