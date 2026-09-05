#!/usr/bin/env bash
set -u

emit() {
  local name="${1:-Mouse}"
  local percent="${2:-}"
  local status="${3:-}"
  local normalized=""

  percent="${percent%%%}"
  if [[ ! "$percent" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    return 1
  fi

  normalized="$(awk -v value="$percent" 'BEGIN {
    if (value > 100 && value <= 255) value = value * 100 / 255;
    if (value > 100) value = 100;
    if (value < 0) value = 0;
    printf "%d", value + 0.5;
  }')"

  if [[ "$status" =~ ^[0-9]+$ ]]; then
    status=""
  fi

  printf 'available=1\n'
  printf 'name=%s\n' "$name"
  printf 'percent=%s\n' "$normalized"
  printf 'status=%s\n' "$status"
  return 0
}

read_openrazer_sysfs() {
  local dir level status serial type product

  for dir in /sys/bus/hid/drivers/razermouse/*; do
    [[ -r "$dir/charge_level" ]] || continue

    level="$(cat "$dir/charge_level" 2>/dev/null || true)"
    [[ -n "$level" ]] || continue

    status="$(cat "$dir/charge_status" 2>/dev/null || true)"
    serial="$(cat "$dir/device_serial" 2>/dev/null || true)"
    type="$(cat "$dir/device_type" 2>/dev/null || true)"
    product="$(basename "$dir")"

    emit "${type:-${serial:-Razer Naga V2 Pro}}" "$level" "$status" && return 0
  done

  return 1
}

read_openrazer_python() {
  python3 - <<'PY' 2>/dev/null
from openrazer.client import DeviceManager

try:
    devices = list(DeviceManager().devices)
except Exception:
    raise SystemExit(1)

def value(device, *names):
    for name in names:
        if not hasattr(device, name):
            continue
        try:
            item = getattr(device, name)
            return item() if callable(item) else item
        except Exception:
            pass
    return None

for device in devices:
    name = str(getattr(device, "name", "") or "Razer Mouse")
    dtype = str(getattr(device, "type", "") or "").lower()
    if not any(token in (name + " " + dtype).lower() for token in ("naga", "mouse", "razer")):
        continue

    percent = value(device, "battery_level", "battery", "charge_level")
    if percent is None:
        continue

    percent = float(percent)
    if percent > 100 and percent <= 255:
        percent = percent * 100 / 255
    percent = max(0, min(100, percent))

    charging = value(device, "is_charging", "charging")
    status = "Charging" if charging is True else ""
    print("available=1")
    print(f"name={name}")
    print(f"percent={int(round(percent))}")
    print(f"status={status}")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

read_upower() {
  local device info name percent status type

  while IFS= read -r device; do
    info="$(upower -i "$device" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue

    name="$(awk -F: '/model:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$info")"
    type="$(awk -F: '/type:/ {sub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<<"$info")"
    [[ "${name,,} ${type,,}" =~ (razer|naga|mouse) ]] || continue

    percent="$(awk -F: '/percentage:/ {gsub(/[ %\t]/, "", $2); print $2; exit}' <<<"$info")"
    status="$(awk -F: '/state:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$info")"
    emit "${name:-Mouse}" "$percent" "$status" && return 0
  done < <(timeout 2s upower -e 2>/dev/null)

  return 1
}

read_bluetoothctl() {
  local address name info percent status

  while read -r _ address name; do
    [[ -n "${address:-}" ]] || continue
    [[ "${name,,}" =~ (razer|naga|mouse) ]] || continue

    info="$(timeout 2s bluetoothctl info "$address" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue

    percent="$(awk '
      /Battery Percentage:/ {
        if (match($0, /\(([0-9]+)\)/, m)) {
          print m[1]
          exit
        }
        split($0, parts, ":")
        gsub(/[ %\t]/, "", parts[2])
        print parts[2]
        exit
      }
    ' <<<"$info")"
    status="$(awk -F: '/Connected:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$info")"
    emit "$name" "$percent" "$status" && return 0
  done < <(timeout 2s bluetoothctl devices 2>/dev/null)

  return 1
}

read_openrazer_sysfs && exit 0
read_openrazer_python && exit 0
read_upower && exit 0
read_bluetoothctl && exit 0

printf 'available=0\n'
