package dev.pshell.app.service

import android.Manifest
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import dev.pshell.app.App
import kotlinx.coroutines.launch

/**
 * Headphones that follow the music: when what plays moves from the PC to
 * the phone, the PC lets its Bluetooth headphones go and the phone takes
 * them. Android has no public call to connect a profile, so this asks the
 * hidden one; where that is refused, the headphones reconnect by themselves
 * or by hand.
 */
object Headset {
	fun allowed(context: Context) = context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

	/** True if the connection was asked for; the headphones answer in their own time. */
	fun connect(app: App, address: String): Boolean {
		if (!allowed(app) || !BluetoothAdapter.checkBluetoothAddress(address.uppercase())) return false
		val adapter = app.getSystemService(BluetoothManager::class.java).adapter ?: return false
		val device = runCatching { adapter.getRemoteDevice(address.uppercase()) }.getOrNull() ?: return false
		if (device.bondState != BluetoothDevice.BOND_BONDED) return false
		var asked = false
		for (profile in listOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET)) {
			adapter.getProfileProxy(app, object : BluetoothProfile.ServiceListener {
				override fun onServiceConnected(kind: Int, proxy: BluetoothProfile) {
					// the headphones may already be on their way back by themselves
					if (proxy.getConnectionState(device) == BluetoothProfile.STATE_DISCONNECTED) {
						runCatching { proxy.javaClass.getMethod("connect", BluetoothDevice::class.java).invoke(proxy, device) }
					}
					adapter.closeProfileProxy(kind, proxy)
				}

				override fun onServiceDisconnected(kind: Int) {}
			}, profile)
			asked = true
		}
		// the PC hangs up first; a second try a moment later catches headphones that were still busy
		app.link.scope.launch {
			kotlinx.coroutines.delay(4000)
			runCatching {
				adapter.getProfileProxy(app, object : BluetoothProfile.ServiceListener {
					override fun onServiceConnected(kind: Int, proxy: BluetoothProfile) {
						if (proxy.getConnectionState(device) == BluetoothProfile.STATE_DISCONNECTED)
							runCatching { proxy.javaClass.getMethod("connect", BluetoothDevice::class.java).invoke(proxy, device) }
						adapter.closeProfileProxy(kind, proxy)
					}

					override fun onServiceDisconnected(kind: Int) {}
				}, BluetoothProfile.A2DP)
			}
		}
		return asked
	}
}
