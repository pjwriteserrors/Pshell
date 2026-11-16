#!/usr/bin/env bash
# Puts pshell-core on the Pi and (re)starts it. Safe to run again any time.
#
#   pcore/deploy.sh                 copy pcore/server, pcore/client, pcore/web; build; up
#   pcore/deploy.sh import-nas      users and devices from the NAS's nas.db into core (once; repeatable)
#   pcore/deploy.sh status
#
# The code is bind-mounted into the container, so a code change is a restart, not a rebuild.
set -euo pipefail

PI="${CORE_PI:-lu@192.168.178.22}"
DIR="pshell-core"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -p pshell-core -f server/docker-compose.yml"

copy() {
    ssh "$PI" "mkdir -p ~/$DIR/server ~/$DIR/client ~/$DIR/web && sudo mkdir -p /mnt/storage/pshell-core"
    local out
    out=$(
        rsync -rlptzi --delete --exclude __pycache__ --exclude tests --exclude '*.pyc' \
            "$REPO/pcore/server/" "$PI:$DIR/server/"
        rsync -rlptzi --delete --exclude __pycache__ "$REPO/pcore/client/" "$PI:$DIR/client/"
        if [ -d "$REPO/pcore/web" ]; then
            rsync -rlptzi --delete "$REPO/pcore/web/" "$PI:$DIR/web/"
        fi
    )
    [ -n "$out" ] && echo "$out" | sed 's/^/  /'
    CHANGED_CODE=$(echo "$out" | grep -Ec '^([<>]f|\*deleting).*\.py$' || true)
    CHANGED_IMAGE=$(echo "$out" | grep -Ec '^[<>]f.*(Dockerfile|docker-compose\.yml|corectl)$' || true)
}

up() {
    copy
    echo "building and starting …"
    ssh "$PI" "cd ~/$DIR && $COMPOSE up -d --build --remove-orphans"
    if [ "${CHANGED_CODE:-0}" != "0" ] && [ "${CHANGED_IMAGE:-0}" = "0" ]; then
        ssh "$PI" "docker restart pshell-core >/dev/null"
        echo "restarted for the new code"
    fi
    firewall_hint
    for _ in $(seq 1 30); do
        if ssh "$PI" "curl -fsS http://127.0.0.1:8097/api/health" 2>/dev/null; then
            echo
            ssh "$PI" "sudo ls /mnt/storage/pshell-core/keys/ 2>/dev/null | sed 's/^/  key: /'" || true
            return 0
        fi
        sleep 2
    done
    echo "pshell-core does not answer – docker logs pshell-core" >&2
    return 1
}

firewall_hint() {
    # the Pi's ufw drops what it does not know; opening it is the user's call, so only say how
    if ssh "$PI" "sudo -n /usr/sbin/ufw status 2>/dev/null | grep -q 'Status: active' && ! sudo -n /usr/sbin/ufw status | grep -q 8097"; then
        echo "ufw blocks 8097. To reach core from the LAN and through the VPN (wg-easy's DNAT), run on the Pi:"
        echo "  sudo ufw allow in on eth0 to any port 8097 proto tcp"
        echo "  sudo ufw allow proto tcp from 172.16.0.0/12 to any port 8097"
    fi
}

case "${1:-}" in
"") up ;;
import-nas) ssh "$PI" "docker exec pshell-core corectl import-nas /storage/pshell-nas/nas.db" ;;
status) ssh "$PI" "docker ps --filter name=pshell-core --format '{{.Names}}  {{.Status}}'; curl -s http://127.0.0.1:8097/api/health; echo" ;;
*)
    echo "deploy.sh [import-nas|status]" >&2
    exit 2
    ;;
esac
