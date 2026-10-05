package dev.pshell.app.service

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.pshell.app.App
import dev.pshell.app.ShareActivity
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.bool
import dev.pshell.app.link.get

/** Quick settings tiles: things done to the PC without opening the app. */
abstract class PcTile : TileService() {
	protected val app get() = application as App
	protected val connected get() = app.link.state.value is LinkState.Connected

	protected open fun active(): Boolean = false

	override fun onStartListening() {
		qsTile?.apply {
			state = if (!connected) Tile.STATE_UNAVAILABLE else if (active()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
			updateTile()
		}
	}
}

/** Only an activity in front may read the clipboard, so the tile opens one that sends it and closes. */
class ClipboardTile : PcTile() {
	override fun onClick() {
		val intent = Intent(this, ShareActivity::class.java).setAction(ShareActivity.ACTION_CLIPBOARD).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
		else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
	}
}

class LockTile : PcTile() {
	override fun active() = app.link.topic("session").value["locked"].bool

	override fun onClick() = app.link.run("session", "lock")
}

class PlayTile : PcTile() {
	override fun active() = app.link.topic("media").value["playing"].bool

	override fun onClick() = app.link.run("media", "playPause")
}

/** Unlock the PC: opens the fingerprint prompt, nothing else. */
class UnlockTile : PcTile() {
	override fun active() = app.link.topic("session").value["locked"].bool

	override fun onClick() {
		val pc = app.link.active.value?.id.orEmpty()
		val intent = Unlocks.intent(this, pc)
		if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 2, intent, PendingIntent.FLAG_IMMUTABLE))
		else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
	}
}
