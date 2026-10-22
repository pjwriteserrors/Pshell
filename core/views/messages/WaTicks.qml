import QtQuick
import qs.style.theme
import qs.style.widgets

// How far a message of one's own got: on its way, sent, delivered, read.
Glyph {
	// -1 failed, 0 on its way, 1 sent, 2 delivered, 3 read, 4 played
	property int status: 0

	icon: status < 0 ? "alert_circle" : (status === 0 ? "clock_outline" : (status === 1 ? "check" : "check_all"))
	size: 13
	color: status < 0 ? Theme.danger : (status >= 3 ? Theme.primary : Theme.textSubtle)
}
