#!/usr/bin/env bash
# Lets the seated desktop user open Sennheiser/EPOS (USB 1395) headsets'
# hidraw node (buttons, LEDs, vendor reports) and their input devices (to take
# a button over while the shell answers it). Run as root (pkexec or sudo).
set -euo pipefail

rule_path="/etc/udev/rules.d/70-pshell-headset.rules"

printf '%s\n' \
  '# Pshell headset page: the seated user may use Sennheiser/EPOS headsets (USB 1395).' \
  'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1395", TAG+="uaccess"' \
  'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="1395", TAG+="uaccess"' \
  > "${rule_path}"

udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=hidraw
udevadm trigger --action=change --subsystem-match=input
printf 'Installed %s\n' "${rule_path}"
