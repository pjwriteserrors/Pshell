#!/usr/bin/env bash
set -euo pipefail

rule_path="/etc/udev/rules.d/70-quickshell-rpg-input.rules"

printf '%s\n' \
  '# Allow the active local desktop session to read only keyboard/mouse event devices.' \
  'SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess"' \
  'SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_MOUSE}=="1", TAG+="uaccess"' \
  | sudo tee "${rule_path}" >/dev/null

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input

printf 'Installed %s\n' "${rule_path}"
printf 'If access is not active immediately, log out and back in once.\n'
