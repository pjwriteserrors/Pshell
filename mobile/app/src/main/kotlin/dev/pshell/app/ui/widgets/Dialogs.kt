package dev.pshell.app.ui.widgets

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import dev.pshell.app.ui.theme.Theme
import kotlinx.coroutines.launch

/** A sheet from the bottom edge, in the shell's colours. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sheet(onDismiss: () -> Unit, title: String = "", content: @Composable ColumnScope.(close: () -> Unit) -> Unit) {
	val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
	val scope = rememberCoroutineScope()
	val close: () -> Unit = { scope.launch { state.hide() }.invokeOnCompletion { onDismiss() } }
	ModalBottomSheet(
		onDismissRequest = onDismiss,
		sheetState = state,
		containerColor = Theme.colors.layer1,
		contentColor = Theme.colors.text,
		scrimColor = Theme.colors.scrim,
		shape = RoundedCornerShape(topStart = 32.dp, topEnd = 32.dp),
		dragHandle = {
			Column(Modifier.padding(top = 10.dp, bottom = 6.dp)) {
				androidx.compose.foundation.layout.Box(Modifier.size(36.dp, 4.dp).clip(CircleShape).background(Theme.colors.textFaint))
			}
		},
	) {
		Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 20.dp, end = 20.dp, bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
			if (title.isNotEmpty()) Label(title, style = Theme.Type.heading)
			androidx.compose.runtime.CompositionLocalProvider(LocalRaised provides true) { content(close) }
		}
	}
}

/** Asks before something that cannot be taken back. */
@Composable
fun Confirm(title: String, text: String, confirm: String, danger: Boolean = false, onDismiss: () -> Unit, onConfirm: () -> Unit) {
	Sheet(onDismiss, title) { close ->
		Label(text, color = Theme.colors.textMuted, maxLines = 6)
		Gap(4)
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
			SoftButton("Cancel", Modifier.weight(1f).padding(vertical = 4.dp), onClick = close)
			PrimaryButton(confirm, Modifier.weight(1f), danger = danger) {
				onConfirm()
				close()
			}
		}
	}
}
