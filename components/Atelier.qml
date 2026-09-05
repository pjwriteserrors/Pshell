pragma Singleton
import QtQuick

QtObject {
    function icon(name) {
        const paths = {"view-app-grid-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg","audio-x-generic-symbolic":"/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg","preferences-system-notifications-symbolic":"/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-notifications-symbolic.svg","edit-paste-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg","network-wired-symbolic":"/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg","applications-graphics-symbolic":"/usr/share/icons/Adwaita/symbolic/categories/applications-graphics-symbolic.svg","system-shutdown-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg","media-playback-pause-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg","media-playback-start-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg","media-skip-backward-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg","media-skip-forward-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-skip-forward-symbolic.svg","audio-volume-muted-symbolic":"/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg","audio-volume-high-symbolic":"/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg","weather-clear-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-clear-symbolic.svg","weather-few-clouds-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-few-clouds-symbolic.svg","weather-overcast-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-overcast-symbolic.svg","weather-showers-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-showers-symbolic.svg","weather-snow-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-snow-symbolic.svg","weather-storm-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-storm-symbolic.svg"};
        return paths[name] || paths[name + "-symbolic"] || paths["view-app-grid-symbolic"];
    }
    readonly property color ink: "#232b2b"
    readonly property color paper: "#f4efdf"
    readonly property color canvas: "#f4efdf"
    readonly property color text: "#232b2b"
    readonly property color muted: "#727568"
    readonly property color accent: "#b44939"
    readonly property color surface: "#e8e0cd"
    readonly property color rule: "#c9bea6"
    readonly property color sage: "#788971"
    readonly property color gold: "#c9a966"
    readonly property string sans: "Adwaita Sans"
    readonly property string display: "C059"
    readonly property string mono: "Adwaita Mono"
}
