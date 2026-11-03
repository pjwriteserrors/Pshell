package dev.pshell.app.zepp

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.UUID

/**
 * The phone's own Zepp OS link to the watch, for when no PC is on: a GATT
 * client on the watch the phone is bonded with. Gadgetbridge on the same
 * phone shares that connection – its session is replaced while this one is
 * open and it authenticates again when it reconnects, so the screen opens
 * this only when asked and closes it when it goes.
 */
@SuppressLint("MissingPermission")
object WatchLink {
	private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
	private val main = Handler(Looper.getMainLooper())
	private val state = MutableStateFlow(WatchState())
	val flow: StateFlow<WatchState> = state
	var catalog: Catalog? = null
		private set
	private var gatt: GattHolder? = null
	val zepp: Zepp? get() = gatt?.zepp

	fun catalog(context: Context): Catalog = catalog ?: Catalog(JSONObject(context.assets.open("zepp.json").bufferedReader().readText())).also { catalog = it }

	/** The bonded watches: Huami's names (Active, Amazfit, Balance, Bip, GTR, GTS, T-Rex). */
	fun bonded(context: Context): List<BluetoothDevice> {
		val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return emptyList()
		return runCatching { adapter.bondedDevices.filter { d -> listOf("Active", "Amazfit", "Balance", "Bip", "GTR", "GTS", "T-Rex", "Cheetah").any { (d.name ?: "").startsWith(it) } } }.getOrDefault(emptyList())
	}

	fun open(context: Context, address: String, key: ByteArray?) {
		close()
		val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
		val device = runCatching { adapter.getRemoteDevice(address) }.getOrNull() ?: return
		gatt = GattHolder(context.applicationContext, device, key, catalog(context))
	}

	fun close() {
		gatt?.close()
		gatt = null
		state.value = state.value.copy(link = "idle")
	}

	private class GattHolder(context: Context, device: BluetoothDevice, private val key: ByteArray?, catalog: Catalog) : BluetoothGattCallback() {
		// one GATT operation at a time, as Android wants
		private val ops = ArrayDeque<() -> Boolean>()
		private var busy = false
		private var chars = mapOf<String, BluetoothGattCharacteristic>()
		val zepp = Zepp(catalog, { uuid, data -> main.post { queueWrite(uuid, data) } }) { s -> state.value = s }
		private val gatt: BluetoothGatt = device.connectGatt(context, false, this, BluetoothDevice.TRANSPORT_LE)

		init {
			zepp.named(device.name ?: "Watch")
			zepp.linkState("connecting")
		}

		fun close() {
			runCatching { gatt.disconnect(); gatt.close() }
		}

		private fun next() {
			while (!busy && ops.isNotEmpty()) busy = ops.poll()!!.invoke()
		}

		private fun queue(op: () -> Boolean) {
			ops.add(op)
			next()
		}

		private fun done() = main.post { busy = false; next() }

		fun queueWrite(uuid: String, data: ByteArray) = queue {
			val c = chars[uuid] ?: return@queue false
			if (android.os.Build.VERSION.SDK_INT >= 33) gatt.writeCharacteristic(c, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothGatt.GATT_SUCCESS
			else @Suppress("DEPRECATION") run {
				c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
				c.value = data
				gatt.writeCharacteristic(c)
			}
		}

		private fun subscribe(uuid: String) = queue {
			val c = chars[uuid] ?: return@queue false
			gatt.setCharacteristicNotification(c, true)
			val d = c.getDescriptor(CCCD) ?: return@queue false
			if (android.os.Build.VERSION.SDK_INT >= 33) gatt.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
			else @Suppress("DEPRECATION") run {
				d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
				gatt.writeDescriptor(d)
			}
		}

		override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
			main.post {
				if (newState == BluetoothProfile.STATE_CONNECTED) {
					zepp.linkState("gatt")
					g.requestMtu(247)
				} else if (newState == BluetoothProfile.STATE_DISCONNECTED) zepp.gone()
			}
		}

		override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
			main.post {
				zepp.mtu(mtu)
				g.discoverServices()
			}
		}

		override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
			main.post {
				chars = g.services.flatMap { it.characteristics }.associateBy { it.uuid.toString().lowercase() }
				if (Chunked.READ !in chars || Chunked.WRITE !in chars) return@post zepp.linkState("failed", "no Zepp OS channel")
				subscribe(Chunked.WRITE)
				subscribe(Chunked.READ)
				queue { main.postDelayed({ zepp.start(key) }, 400); false }
			}
		}

		override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = done().let { }

		override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = done().let { }

		@Deprecated("before Android 13")
		override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
			@Suppress("DEPRECATION") val value = c.value ?: return
			if (android.os.Build.VERSION.SDK_INT < 33) onCharacteristicChanged(g, c, value)
		}

		override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
			val uuid = c.uuid.toString().lowercase()
			val copy = value.copyOf()
			main.post { zepp.feed(uuid, copy) }
		}
	}
}
