pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls

Item {
    id: root
    required property var host
    Rectangle {
        width: parent.width; height: 64; radius: 32; color: Atelier.ink
        AtelierText { x: 24; anchors.verticalCenter: parent.verticalCenter; text: root.host.notificationGroups.length + (root.host.notificationGroups.length === 1 ? " arrival" : " arrivals"); display: true; font.pixelSize: 26; color: Atelier.paper }
        AtelierText {
            anchors.right: parent.right; anchors.rightMargin: 24; anchors.verticalCenter: parent.verticalCenter; text: "Clear all"; color: Atelier.gold; font.pixelSize: 11
            MouseArea { anchors.fill: parent; anchors.margins: -10; onClicked: root.host.dismissAllNotificationGroups() }
        }
    }
    Column {
        anchors.centerIn: parent; spacing: 18; visible: timeline.count === 0
        FolioArtwork { width: 200; height: 180; tint: Atelier.sage }
        AtelierText { anchors.horizontalCenter: parent.horizontalCenter; text: "A quiet moment."; display: true; font.pixelSize: 28 }
        AtelierText { anchors.horizontalCenter: parent.horizontalCenter; text: "Nothing needs your attention."; color: Atelier.muted; font.pixelSize: 12 }
    }
    ListView {
        id: timeline
        y: 88; width: parent.width; height: parent.height - y; clip: true; spacing: 20
        model: root.host.notificationGroups
        delegate: Item {
            id: entry
            required property var modelData
            property var snapshot: modelData.latestSnapshot || ({})
            property var live: modelData.latestNotification
            width: timeline.width; height: story.height + 18
            Rectangle { x: 5; y: 4; width: 1; height: parent.height; color: Atelier.rule }
            Rectangle { x: 1; y: 4; width: 9; height: 9; radius: 5; color: Atelier.accent }
            Column {
                id: story
                x: 24; width: parent.width - 30; spacing: 10
                Row {
                    width: parent.width
                    AtelierText { width: parent.width - 32; text: (entry.snapshot.appName || "Notification") + "  /  " + root.host.formatNotificationTime(entry.snapshot.timestamp); color: Atelier.muted; font.family: Atelier.mono; font.pixelSize: 10; elide: Text.ElideRight }
                    AtelierText { text: "×"; font.pixelSize: 18; MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: root.host.dismissNotificationGroup(entry.modelData.key) } }
                }
                AtelierText { width: parent.width; text: entry.snapshot.summary || ""; display: true; font.pixelSize: 24; wrapMode: Text.WordWrap }
                Image { width: parent.width; height: visible ? 120 : 0; visible: source.toString() !== ""; source: entry.snapshot.image || ""; fillMode: Image.PreserveAspectFit; asynchronous: true }
                AtelierText { width: parent.width; text: entry.snapshot.body || ""; font.pixelSize: 13; wrapMode: Text.WordWrap; visible: text !== "" }
                Rectangle { width: parent.width; height: 3; color: Atelier.rule; visible: entry.snapshot.progressValue >= 0; Rectangle { width: parent.width * Math.max(0,Math.min(100,entry.snapshot.progressValue))/100; height: 3; color: Atelier.accent } }
                Flow {
                    width: parent.width; spacing: 8
                    Repeater {
                        model: entry.live ? entry.live.actions : []
                        delegate: Rectangle {
                            required property var modelData
                            width: actionText.implicitWidth + 28; height: 34; radius: 17; color: Atelier.surface
                            AtelierText { id: actionText; anchors.centerIn: parent; text: parent.modelData.text; font.pixelSize: 12 }
                            MouseArea { anchors.fill: parent; onClicked: parent.modelData.invoke() }
                        }
                    }
                }
                TextField {
                    id: reply
                    width: parent.width; visible: !!entry.live && entry.live.hasInlineReply
                    placeholderText: entry.live ? entry.live.inlineReplyPlaceholder || "Reply and press Enter" : ""
                    onAccepted: root.host.submitInlineReply(entry.live, reply)
                }
                AtelierText {
                    text: entry.modelData.expanded ? "Hide earlier arrivals ↑" : "Earlier arrivals (" + (entry.modelData.notifications.length - 1) + ") ↓"
                    visible: entry.modelData.notifications.length > 1; color: Atelier.accent; font.pixelSize: 11
                    MouseArea { anchors.fill: parent; onClicked: root.host.setNotificationGroupExpanded(entry.modelData.key,!entry.modelData.expanded) }
                }
                Repeater {
                    model: entry.modelData.expanded ? entry.modelData.notifications.slice(1) : []
                    delegate: Column {
                        required property var modelData
                        width: story.width; spacing: 6
                        Rectangle { width: parent.width; height: 1; color: Atelier.rule }
                        AtelierText { width: parent.width; text: parent.modelData.summary; font.pixelSize: 15; wrapMode: Text.WordWrap }
                        AtelierText { width: parent.width; text: parent.modelData.body; font.pixelSize: 12; wrapMode: Text.WordWrap; color: Atelier.muted }
                    }
                }
            }
        }
        ScrollBar.vertical: ScrollBar {}
    }
}
