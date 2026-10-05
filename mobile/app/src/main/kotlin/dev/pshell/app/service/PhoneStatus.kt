package dev.pshell.app.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import dev.pshell.app.App
import dev.pshell.app.link.json

/** phone.status: battery, charging and what network the phone is on. */
class PhoneStatus(private val context: Context, private val app: App) {
	private val receiver = object : BroadcastReceiver() {
		override fun onReceive(context: Context, intent: Intent) = publish(intent)
	}

	fun start() {
		context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let(::publish)
	}

	fun stop() {
		runCatching { context.unregisterReceiver(receiver) }
	}

	private fun publish(battery: Intent) {
		val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
		val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
		val state = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
		app.link.publish("phone.status", json(
			"battery" to if (level >= 0) level * 100 / scale else -1,
			"charging" to (state == BatteryManager.BATTERY_STATUS_CHARGING || state == BatteryManager.BATTERY_STATUS_FULL),
			"network" to network(),
		))
	}

	private fun network(): String {
		val manager = context.getSystemService(ConnectivityManager::class.java)
		val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return ""
		return when {
			capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
			capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
			capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile data"
			capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
			else -> ""
		}
	}
}
