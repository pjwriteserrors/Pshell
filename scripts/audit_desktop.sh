#!/usr/bin/env bash
set -euo pipefail
atelier_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
audit_dir=/tmp/atelier-audit
mkdir -p "$audit_dir"
case "${1:-status}" in
  capture)
    output="$(niri msg -j focused-output | jq -r .name)"
    for panel in launcher calendar weather notifications media resources network bluetooth clipboard power wallpaper interface animations presets; do
      quickshell ipc -p "$atelier_dir" call designReview open "$panel"
      sleep 1
      grim -o "$output" "$audit_dir/$output-$panel.png"
    done
    quickshell ipc -p "$atelier_dir" call designReview close
    ;;
  open)
    quickshell ipc -p "$atelier_dir" call designReview open "$2"
    ;;
  shot)
    output="$(niri msg -j focused-output | jq -r .name)"
    grim -o "$output" "$audit_dir/current.png"
    ;;
  close)
    quickshell ipc -p "$atelier_dir" call designReview close
    ;;
  status)
    quickshell list --all
    quickshell ipc -p "$atelier_dir" call designReview state
    busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetServerInformation
    quickshell log -p "$atelier_dir" -t 100
    ;;
  small)
    original_output="$(niri msg -j focused-output | jq -r .name)"
    trap 'niri msg action focus-monitor "$original_output"' EXIT
    niri msg action focus-monitor HDMI-A-1
    bash "$atelier_dir/scripts/audit_desktop.sh" capture
    ;;
  keyboard)
    output="$(niri msg -j focused-output | jq -r .name)"
    for query in '>c 12*7' '>file ' '>chat ' '>ollama ' '>'; do
      quickshell ipc -p "$atelier_dir" call designReview open launcher
      sleep 0.6
      wtype -M ctrl -k a -m ctrl
      wtype "$query"
      sleep 1
      key_name="$(printf '%s' "$query" | tr -cd '[:alnum:]')"
      grim -o "$output" "$audit_dir/keyboard-$key_name.png"
      wtype -k Escape
    done
    quickshell ipc -p "$atelier_dir" call designReview close
    ;;
  notification)
    notify-send -a "Atelier Review" -t 6000 "A little room to breathe" "Visueller Funktionstest: Nachricht, Verlauf und Schließen."
    sleep 0.8
    bash "$atelier_dir/scripts/audit_desktop.sh" shot
    quickshell ipc -p "$atelier_dir" call designReview open notifications
    ;;
  restart)
    locked="$(quickshell ipc -p "$atelier_dir" call designReview state | jq -r .locked)"
    [[ "$locked" == "false" ]] || { echo "Refusing to restart a locked or unknown session."; exit 1; }
    quickshell kill -p "$atelier_dir"
    sleep 1
    quickshell -p "$atelier_dir" --daemonize --no-duplicate
    ;;
  start)
    quickshell -p "$atelier_dir" --daemonize --no-duplicate
    ;;
  *) exit 2 ;;
esac
