pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    function icon(name) {
        const paths = {"view-app-grid-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg","audio-x-generic-symbolic":"/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg","preferences-system-notifications-symbolic":"/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-notifications-symbolic.svg","edit-paste-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg","network-wired-symbolic":"/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg","applications-graphics-symbolic":"/usr/share/icons/Adwaita/symbolic/categories/applications-graphics-symbolic.svg","system-shutdown-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg","media-playback-pause-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg","media-playback-start-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg","media-skip-backward-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg","media-skip-forward-symbolic":"/usr/share/icons/Adwaita/symbolic/actions/media-skip-forward-symbolic.svg","audio-volume-muted-symbolic":"/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg","audio-volume-high-symbolic":"/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg","weather-clear-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-clear-symbolic.svg","weather-few-clouds-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-few-clouds-symbolic.svg","weather-overcast-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-overcast-symbolic.svg","weather-showers-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-showers-symbolic.svg","weather-snow-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-snow-symbolic.svg","weather-storm-symbolic":"/usr/share/icons/Adwaita/symbolic/status/weather-storm-symbolic.svg"};
        return paths[name] || paths[name + "-symbolic"] || paths["view-app-grid-symbolic"];
    }

    id: theme
    property var palette: ({special:{background:"#1a1e20",foreground:"#b7c0ba"},colors:{color2:"#583832",color3:"#894537",color5:"#d45a44",color6:"#c57a76"}})
    function mix(a, b, amount) {
        return Qt.rgba(a.r*(1-amount)+b.r*amount,a.g*(1-amount)+b.g*amount,a.b*(1-amount)+b.b*amount,1);
    }
    function luminance(c) {
        function channel(v) { return v<=0.04045 ? v/12.92 : Math.pow((v+0.055)/1.055,2.4); }
        return channel(c.r)*0.2126+channel(c.g)*0.7152+channel(c.b)*0.0722;
    }
    function contrast(a,b) { const x=luminance(a),y=luminance(b); return (Math.max(x,y)+0.05)/(Math.min(x,y)+0.05); }
    function chroma(c) { return Math.max(c.r,c.g,c.b)-Math.min(c.r,c.g,c.b); }
    function on(surfaceColor) { return contrast(Qt.color("#ffffff"),surfaceColor)>contrast(Qt.color("#000000"),surfaceColor)?Qt.color("#ffffff"):Qt.color("#000000"); }
    // Rank the Wallust colours by how much hue they carry and how legible they
    // stay on the current canvas, so the accent follows the wallpaper instead
    // of a fixed slot that can land on a washed-out entry.
    function ranked(base) {
        const source=palette.colors||{}, list=[];
        for(let index=1;index<=6;index++){
            const raw=source["color"+index];
            if(!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
            const color=Qt.color(raw), tint=chroma(color);
            if(tint<0.04) continue;
            list.push({color:color,score:tint*Math.min(1,contrast(color,base)/3)});
        }
        list.sort((a,b)=>b.score-a.score);
        return list.map(entry=>entry.color);
    }
    function alert(fallback) {
        const source=palette.colors||{};
        let best=null,bestScore=-1;
        for(let index=1;index<=15;index++){
            const raw=source["color"+index];
            if(!/^#[0-9a-f]{6}$/i.test(String(raw))) continue;
            const color=Qt.color(raw),tint=chroma(color);
            if(tint<0.08) continue;
            const hue=color.hslHue<0?0.5:color.hslHue;
            if(Math.min(hue,1-hue)>0.055) continue;
            if(tint>bestScore){bestScore=tint;best=color;}
        }
        return best||Qt.color(fallback);
    }
    function parsed(value, fallback) { return /^#[0-9a-f]{6}$/i.test(String(value)) ? Qt.color(value) : Qt.color(fallback); }
    function readable(color, background, ratio) {
        const end=contrast(Qt.color("#ffffff"),background)>contrast(Qt.color("#000000"),background)?Qt.color("#ffffff"):Qt.color("#000000");
        if(contrast(color,background)>=ratio)return color;
        let low=0,high=1;
        for(let i=0;i<16;i++){const mid=(low+high)/2;if(contrast(mix(color,end,mid),background)>=ratio)high=mid;else low=mid;}
        return mix(color,end,high);
    }
    function load(raw) {
        try {
            const next=JSON.parse(raw);
            if(!next.special || !/^#[0-9a-f]{6}$/i.test(next.special.background) || !/^#[0-9a-f]{6}$/i.test(next.special.foreground)) return;
            theme.palette=next;
        } catch(error) { /* Keep the last valid palette during atomic replacements. */ }
    }
    property FileView colorsFile: FileView {
        path: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME")+"/.cache") + "/wal/colors.json"
        watchChanges: true
        blockLoading: true
        printErrors: false
        onLoaded: theme.load(text())
        onFileChanged: reload()
    }
    readonly property color canvas: parsed(palette.special.background,"#1a1e20")
    // A light Wallust palette gets light chrome; only a dark palette gets dark
    // chrome. The rail must not invert the mode the wallpaper established.
    readonly property bool light: luminance(canvas)>0.42
    readonly property color text: readable(parsed(palette.special.foreground,"#b7c0ba"),canvas,7)
    readonly property color ink: light?mix(canvas,Qt.color("#ffffff"),0.5):mix(canvas,Qt.color("#000000"),0.28)
    readonly property color paper: readable(text,ink,7)
    readonly property color scrim: mix(canvas,Qt.color("#000000"),0.86)
    readonly property color muted: readable(mix(canvas,text,0.58),canvas,4.5)
    readonly property var accents: ranked(canvas)
    readonly property color accent: readable(accents.length>0?accents[0]:parsed(palette.colors?.color5,"#d45a44"),canvas,3)
    readonly property color onAccent: on(accent)
    readonly property color surface: mix(canvas,text,0.08)
    readonly property color selectedSurface: mix(canvas,accent,0.22)
    readonly property color rule: mix(canvas,text,0.25)
    readonly property color sage: readable(accents.length>1?accents[1]:parsed(palette.colors?.color2,"#583832"),canvas,3)
    readonly property color gold: readable(accents.length>2?accents[2]:accents.length>0?accents[0]:parsed(palette.colors?.color6,"#c57a76"),ink,4.5)
    readonly property color danger: readable(alert("#c8453c"),canvas,4.5)
    readonly property string sans: "Adwaita Sans"
    readonly property string display: "C059"
    readonly property string mono: "Adwaita Mono"
}
