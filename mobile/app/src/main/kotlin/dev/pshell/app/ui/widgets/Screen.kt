package dev.pshell.app.ui.widgets

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.theme.Theme

/** Space the floating tab bar and the gesture bar take at the bottom. */
val BottomSpace = 104.dp

/**
 * A screen below the home: the shell's PageHeader (a round back button,
 * title, subtitle, actions) above scrolling content.
 */
@Composable
fun Screen(
	title: String,
	subtitle: String = "",
	scroll: Boolean = true,
	actions: @Composable RowScope.() -> Unit = {},
	content: @Composable ColumnScope.() -> Unit,
) {
	val nav = LocalNav.current
	val root = nav.stack.size <= 1
	Column(Modifier.fillMaxSize().padding(WindowInsets.statusBars.asPaddingValues()).imePadding()) {
		Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
			if (!root) {
				IconButton("arrow_left", color = Theme.colors.layer2, onClick = { nav.back() })
				Spacer(Modifier.width(12.dp))
			}
			Column(Modifier.weight(1f)) {
				Label(title, style = if (root) Theme.Type.display else Theme.Type.heading)
				if (subtitle.isNotEmpty()) Label(subtitle, style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			actions()
		}
		Column(
			Modifier
				.fillMaxSize()
				.then(if (scroll) Modifier.verticalScroll(rememberScrollState()) else Modifier)
				.padding(PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = if (scroll) BottomSpace else 0.dp)),
			verticalArrangement = Arrangement.spacedBy(Theme.Gap.md),
			content = content,
		)
	}
}

@Composable
fun Gap(height: Int) = Spacer(Modifier.height(height.dp))
