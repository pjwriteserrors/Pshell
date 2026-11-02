import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The keys it can use. Twitch cannot be asked without an app of one's own; a
// YouTube key is optional and makes older videos come quickly. All kept in
// the keyring.
Item {
	id: root

	property bool shown: false

	implicitHeight: root.shown ? box.implicitHeight : 0
	clip: true
	opacity: root.shown ? 1 : 0

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.long
		}
	}
	Behavior on opacity {
		Anim {}
	}

	Rectangle {
		id: box

		width: parent.width
		implicitHeight: column.implicitHeight + 32
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: column

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 16
			spacing: 8

			RowLayout {
				SectionHeading {
					text: "Twitch"
					font.pixelSize: Theme.size.title
				}
				Glyph {
					visible: Streams.keys.twitch ?? false
					icon: "check_circle_outline"
					size: 16
					color: Theme.success
				}
				Item {
					Layout.fillWidth: true
				}
				TextButton {
					text: "Create an app"
					icon: "open_in_new"
					variant: "ghost"
					onActivated: Browser.open("https://dev.twitch.tv/console/apps/create")
				}
			}
			StyledText {
				Layout.fillWidth: true
				text: "Name it anything, OAuth Redirect URL http://localhost, category Other, client type Confidential. Then paste its Client ID and a new secret here."
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				wrapMode: Text.Wrap
			}
			RowLayout {
				Layout.fillWidth: true
				Field {
					id: twitchId

					Layout.fillWidth: true
					placeholder: Streams.keys.twitch ? "Client ID (saved)" : "Client ID"
				}
				Field {
					id: twitchSecret

					Layout.fillWidth: true
					password: true
					placeholder: Streams.keys.twitch ? "Secret (saved)" : "Secret"
				}
				TextButton {
					text: "Save"
					variant: "tonal"
					enabled: twitchId.text.trim() !== "" && twitchSecret.text.trim() !== ""
					onActivated: {
						Streams.call("secrets", { "twitch-id": twitchId.text, "twitch-secret": twitchSecret.text }, Streams.report());
						twitchId.text = "";
						twitchSecret.text = "";
					}
				}
			}
			StyledText {
				Layout.fillWidth: true
				visible: !!Streams.keys.twitchError
				text: Streams.keys.twitchError ?? ""
				color: Theme.danger
				font.pixelSize: Theme.size.small
			}
			RowLayout {
				visible: Streams.keys.twitch ?? false
				spacing: 8
				TextButton {
					text: Streams.keys.twitchUser ? "Signed in" : "Sign in for follows and raids"
					icon: "account"
					variant: "tonal"
					enabled: !Streams.keys.twitchUser
					onActivated: Streams.call("signin", {}, Streams.report(data => {
						if (data?.url) Browser.open(data.url);
					}))
				}
				TextButton {
					visible: Streams.keys.twitchUser ?? false
					text: "Follow everyone I follow"
					icon: "account_multiple_plus"
					variant: "tonal"
					onActivated: Streams.call("importFollows", {}, Streams.report(data => {
						if (data) Notifs.pushInternal("done", `${data.added} channels added`, "", { icon: "check" });
					}))
				}
				StyledText {
					visible: !!Streams.signin?.code
					text: `Enter ${Streams.signin?.code ?? ""} on the page that opened`
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
					color: Theme.primary
				}
			}

			RowLayout {
				Layout.topMargin: 8
				SectionHeading {
					text: "YouTube (optional)"
					font.pixelSize: Theme.size.title
				}
				Glyph {
					visible: Streams.keys.youtube ?? false
					icon: "check_circle_outline"
					size: 16
					color: Theme.success
				}
				Item {
					Layout.fillWidth: true
				}
				TextButton {
					text: "Get a key"
					icon: "open_in_new"
					variant: "ghost"
					onActivated: Browser.open("https://console.cloud.google.com/apis/library/youtube.googleapis.com")
				}
			}
			StyledText {
				Layout.fillWidth: true
				text: "Everything works without one. With one, older videos come with their descriptions at once, not one by one."
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
				wrapMode: Text.Wrap
			}
			RowLayout {
				Layout.fillWidth: true
				Field {
					id: youtubeKey

					Layout.fillWidth: true
					password: true
					placeholder: Streams.keys.youtube ? "API key (saved)" : "API key"
				}
				TextButton {
					text: "Save"
					variant: "tonal"
					enabled: youtubeKey.text.trim() !== ""
					onActivated: {
						Streams.call("secrets", { "youtube-key": youtubeKey.text }, Streams.report());
						youtubeKey.text = "";
					}
				}
			}
		}
	}
}
