package com.nearlink.nearlink

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.SocketException

/** Interface metadata only. Discovery policy and identity checks stay in Dart. */
object NetworkDiscoveryBridge {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "nearlink/network_discovery")
            .setMethodCallHandler { call, result ->
                if (call.method != "getInterfaces") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val rows = mutableListOf<Map<String, Any>>()
                    val interfaces = NetworkInterface.getNetworkInterfaces()
                    while (interfaces != null && interfaces.hasMoreElements()) {
                        val network = interfaces.nextElement()
                        try {
                            if (!network.isUp || network.isLoopback || network.isPointToPoint) continue
                            for (entry in network.interfaceAddresses) {
                                val address = entry.address
                                if (address !is Inet4Address || address.isLoopbackAddress ||
                                    address.isLinkLocalAddress) continue
                                val host = address.hostAddress ?: continue
                                rows.add(mapOf("address" to host,
                                    "prefixLength" to entry.networkPrefixLength.toInt()))
                            }
                        } catch (_: SocketException) {
                            // An adapter can disappear while Wi-Fi is reconnecting.
                        }
                    }
                    result.success(rows)
                } catch (error: Exception) {
                    result.error("NETWORK_INTERFACES", "无法读取局域网接口：${error.message}", null)
                }
            }
    }
}
