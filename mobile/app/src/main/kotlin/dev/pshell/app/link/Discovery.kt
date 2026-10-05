package dev.pshell.app.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.util.concurrent.ConcurrentHashMap

/**
 * Finds PCs on the LAN by mDNS (_pshell._tcp). What is found is only a hint
 * where to knock: the connection still has to present the pinned certificate.
 */
class Discovery(context: Context) {
	private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
	private var listener: NsdManager.DiscoveryListener? = null

	/** fingerprint prefix → "address:port" */
	val found = ConcurrentHashMap<String, String>()
	var onFound: () -> Unit = {}

	@Synchronized
	fun start() {
		if (listener != null) return
		val created = object : NsdManager.DiscoveryListener {
			override fun onDiscoveryStarted(serviceType: String?) {}
			override fun onDiscoveryStopped(serviceType: String?) {}
			override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {}
			override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
			override fun onServiceLost(serviceInfo: NsdServiceInfo?) {}
			override fun onServiceFound(serviceInfo: NsdServiceInfo) = resolve(serviceInfo)
		}
		listener = created
		runCatching { nsd.discoverServices("_pshell._tcp", NsdManager.PROTOCOL_DNS_SD, created) }.onFailure { listener = null }
	}

	@Synchronized
	fun stop() {
		listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
		listener = null
	}

	@Suppress("DEPRECATION")
	private fun resolve(info: NsdServiceInfo) {
		runCatching {
			nsd.resolveService(info, object : NsdManager.ResolveListener {
				override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {}
				override fun onServiceResolved(resolved: NsdServiceInfo) {
					val id = resolved.attributes["id"]?.toString(Charsets.UTF_8) ?: return
					val host = resolved.host?.hostAddress ?: return
					if (found.put(id, "$host:${resolved.port}") != "$host:${resolved.port}") onFound()
				}
			})
		}
	}
}
