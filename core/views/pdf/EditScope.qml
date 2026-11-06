pragma ComponentBehavior: Bound

import QtQuick
import qs.style.widgets
import qs.core.services

// Which pages a tool works on: this one, the chosen ones (in the page list or the organizer), all, odd, even.
Segmented {
	id: root

	property bool withOddEven: true

	width: parent?.width ?? 300
	options: [{ value: "this", label: "This" }].concat(Pdf.selectedPages.length > 0 ? [{ value: "selected", label: `${Pdf.selectedPages.length} chosen` }] : []).concat([{ value: "all", label: "All" }]).concat(root.withOddEven ? [{ value: "odd", label: "Odd" }, { value: "even", label: "Even" }] : [])
	current: Pdf.pageScope === "selected" && Pdf.selectedPages.length === 0 ? "this" : Pdf.pageScope
	onSelected: value => Pdf.pageScope = value
}
