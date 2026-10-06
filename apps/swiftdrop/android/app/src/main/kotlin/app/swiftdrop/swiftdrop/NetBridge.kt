package app.swiftdrop.swiftdrop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

/**
 * What the phone's network really looks like, for picking the address other devices can
 * reach. Dart's NetworkInterface only gives names and addresses; it can't say which is the
 * mobile-data link (a private-looking CGNAT address nobody on the Wi-Fi can reach) or the
 * hotspot the phone itself hosts (no ConnectivityManager Network exists for that one).
 *
 *  kind: wifi | ethernet | cellular | vpn | hotspot | other
 *
 * Also: tells Dart when the network changed (Wi-Fi joined/lost, hotspot toggled, VPN
 * up/down), and keeps LAN traffic off a VPN tunnel by binding the process to Wi-Fi while a
 * VPN is up (SwiftDrop never needs the internet).
 */
class NetBridge(private val context: Context, private val onChanged: () -> Unit) {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null
    private var started = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
        override fun onLinkPropertiesChanged(network: Network, lp: android.net.LinkProperties) = changed()
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) = changed()
    }

    fun start() {
        if (started) return
        started = true
        try {
            cm.registerNetworkCallback(NetworkRequest.Builder().build(), callback)
        } catch (_: Exception) {
        }
        // Hotspot on/off has no Network for the owner: the (legacy but still sent) AP broadcasts say so.
        val f = IntentFilter().apply {
            addAction("android.net.wifi.WIFI_AP_STATE_CHANGED")
            addAction("android.net.conn.TETHER_STATE_CHANGED")
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, f, Context.RECEIVER_EXPORTED)
            else context.registerReceiver(receiver, f)
        } catch (_: Exception) {
        }
        routeLan()
    }

    fun stop() {
        if (!started) return
        started = false
        try { cm.unregisterNetworkCallback(callback) } catch (_: Exception) {}
        try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
        try { cm.bindProcessToNetwork(null) } catch (_: Exception) {}
    }

    private fun changed() {
        pending?.let { main.removeCallbacks(it) }
        pending = Runnable {
            routeLan()
            onChanged()
        }.also { main.postDelayed(it, 350) }
    }

    @Suppress("DEPRECATION")
    private fun networks(): List<Network> = try {
        cm.allNetworks.toList()
    } catch (_: Exception) {
        emptyList()
    }

    /** VPN up + a physical LAN network: send this process's traffic over the LAN network. */
    private fun routeLan() {
        try {
            var vpn = false
            var lan: Network? = null
            for (n in networks()) {
                val c = cm.getNetworkCapabilities(n) ?: continue
                if (c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) vpn = true
                else if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) lan = n
            }
            cm.bindProcessToNetwork(if (vpn) lan else null)
        } catch (_: Exception) {
        }
    }

    fun interfaces(): List<Map<String, Any?>> {
        val kindByIface = HashMap<String, String>()
        for (n in networks()) {
            val lp = cm.getLinkProperties(n) ?: continue
            val caps = cm.getNetworkCapabilities(n) ?: continue
            val kind = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                else -> "other"
            }
            lp.interfaceName?.let { kindByIface[it] = kind }
        }
        val out = ArrayList<Map<String, Any?>>()
        val all = try {
            Collections.list(NetworkInterface.getNetworkInterfaces())
        } catch (_: Exception) {
            emptyList<NetworkInterface>()
        }
        for (ni in all) {
            if (!ni.isUp || ni.isLoopback) continue
            for (ia in ni.interfaceAddresses) {
                val a = ia.address
                if (a !is Inet4Address || a.isLoopbackAddress || a.isLinkLocalAddress) continue
                // A private address on an interface Android keeps no Network for is the
                // hotspot (or USB / Bluetooth tethering) this phone hosts.
                val kind = kindByIface[ni.name] ?: if (a.isSiteLocalAddress) "hotspot" else "other"
                out.add(
                    mapOf(
                        "name" to ni.name,
                        "address" to a.hostAddress,
                        "prefix" to ia.networkPrefixLength.toInt(),
                        "kind" to kind,
                        "multicast" to ni.supportsMulticast(),
                    ),
                )
            }
        }
        return out
    }
}
