#!/usr/bin/env bash
# Read-only system maintenance scan (never needs root), as tagged TSV lines:
#   kernel  <TAB> running <TAB> installed <TAB> reboot (0|1)
#   upgrade <TAB> epoch seconds of the last full system upgrade
#   pacnew  <TAB> path                  (.pacnew / .pacsave files under /etc)
#   orphan  <TAB> package
#   cache   <TAB> pacman|yay <TAB> bytes
#   tool    <TAB> pacdiff|paccache      (only when installed)
set -uo pipefail

# ── kernel ────────────────────────────────────────────────────────────────
# The kernel package that booted is found through the modules directory of
# the running kernel; once that is gone (upgraded) the flavour suffix of
# `uname -r` (…-lts, …-zen) names it. The installed version is the modules
# directory that package owns now – a reboot is due when it differs.
running=$(uname -r)
pkgbase=linux
[[ $running =~ -([a-z]+)$ ]] && pkgbase="linux-${BASH_REMATCH[1]}"
[[ -r "/usr/lib/modules/$running/pkgbase" ]] && pkgbase=$(<"/usr/lib/modules/$running/pkgbase")
installed=$(pacman -Qlq "$pkgbase" 2>/dev/null | sed -n 's|^/usr/lib/modules/\([^/]*\)/vmlinuz$|\1|p' | head -n 1)
reboot=0
if [[ -n "$installed" ]]; then
	[[ "$installed" == "$running" ]] || reboot=1
elif [[ ! -d "/usr/lib/modules/$running" ]]; then
	reboot=1
fi
printf 'kernel\t%s\t%s\t%s\n' "$running" "${installed:-$running}" "$reboot"

# ── last full system upgrade ──────────────────────────────────────────────
stamp=$(tac /var/log/pacman.log 2>/dev/null | grep -m 1 'starting full system upgrade' | sed -n 's/^\[\([^]]*\)\].*/\1/p')
[[ -n "$stamp" ]] && printf 'upgrade\t%s\n' "$(date -d "$stamp" +%s 2>/dev/null || echo 0)"

# ── config files left by pacman ───────────────────────────────────────────
find /etc -xdev \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort | sed 's/^/pacnew\t/'

# ── orphans ───────────────────────────────────────────────────────────────
pacman -Qdtq 2>/dev/null | sed 's/^/orphan\t/'

# ── caches ────────────────────────────────────────────────────────────────
size() { du -sb "$@" 2>/dev/null | awk '{ sum += $1 } END { print sum + 0 }'; }
mapfile -t pkgcache < <(pacman-conf CacheDir 2>/dev/null)
((${#pkgcache[@]})) || pkgcache=(/var/cache/pacman/pkg)
printf 'cache\tpacman\t%s\n' "$(size "${pkgcache[@]}")"
printf 'cache\tyay\t%s\n' "$(size "${XDG_CACHE_HOME:-$HOME/.cache}/yay")"

for tool in pacdiff paccache; do
	command -v "$tool" >/dev/null && printf 'tool\t%s\n' "$tool"
done

exit 0
