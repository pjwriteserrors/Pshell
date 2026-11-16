#!/usr/bin/env bash
# Puts pshell-nas on the Pi and (re)starts it. Safe to run again any time.
#
#   nas/deploy.sh              copy nas/server, nas/web, scripts/files, scripts/host.py; build; up
#   nas/deploy.sh public on    Caddy on 443 for the public share links (only /s/, /u/ and their assets)
#   nas/deploy.sh public off
#   nas/deploy.sh status
#
# The code is bind-mounted into the container, so a code change is a restart, not a rebuild.
set -euo pipefail

PI="${NAS_PI:-lu@192.168.178.22}"
DIR="pshell-nas"
HOST_NAME="${NAS_PUBLIC_HOST:-netcore-iseeu.duckdns.org}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -p pshell-nas -f server/docker-compose.yml"

copy() {
    ssh "$PI" "mkdir -p ~/$DIR/server ~/$DIR/web ~/$DIR/files && sudo mkdir -p /mnt/storage/pshell-nas/ollama"
    local out
    out=$(
        rsync -rlptzi --delete --exclude __pycache__ --exclude tests --exclude '*.pyc' \
            "$REPO/nas/server/" "$PI:$DIR/server/"
        if [ -d "$REPO/nas/web" ]; then
            rsync -rlptzi --delete "$REPO/nas/web/" "$PI:$DIR/web/"
        fi
        rsync -rlptzi --delete --exclude __pycache__ --exclude '*.pyc' "$REPO/scripts/files/" "$PI:$DIR/files/"
        rsync -rlptzi "$REPO/scripts/host.py" "$PI:$DIR/host.py"
    )
    [ -n "$out" ] && echo "$out" | sed 's/^/  /'
    CHANGED_CODE=$(echo "$out" | grep -Ec '^([<>]f|\*deleting).*\.py$' || true)
    CHANGED_IMAGE=$(echo "$out" | grep -Ec '^[<>]f.*(Dockerfile|docker-compose\.yml|nasctl)$' || true)
}

profiles() {
    # the ollama container exists only while the setting pi_ai is on (default off)
    local ai
    ai=$(ssh "$PI" "python3 -c \"import json;print(json.load(open('/mnt/storage/pshell-nas/settings.json')).get('pi_ai', False))\" 2>/dev/null || echo False")
    [ "$ai" = "True" ] && echo "--profile ai" || echo ""
}

up() {
    copy
    local profile
    profile=$(profiles)
    echo "building and starting (profile: ${profile:-none}) …"
    ssh "$PI" "cd ~/$DIR && $COMPOSE $profile up -d --build --remove-orphans"
    if [ "${CHANGED_CODE:-0}" != "0" ] && [ "${CHANGED_IMAGE:-0}" = "0" ]; then
        ssh "$PI" "docker restart pshell-nas >/dev/null"
        echo "restarted for the new code"
    fi
    firewall_hint
    for _ in $(seq 1 30); do
        if ssh "$PI" "curl -fsS http://127.0.0.1:8096/api/hello" 2>/dev/null; then
            echo
            return 0
        fi
        sleep 2
    done
    echo "pshell-nas does not answer – docker logs pshell-nas" >&2
    return 1
}

firewall_hint() {
    # the Pi's ufw drops what it does not know; opening it is the user's call, so only say how
    if ssh "$PI" "sudo -n /usr/sbin/ufw status 2>/dev/null | grep -q 'Status: active' && ! sudo -n /usr/sbin/ufw status | grep -q 8096"; then
        echo "ufw blocks 8096. To reach the NAS from the LAN and through the VPN (wg-easy's DNAT), run on the Pi:"
        echo "  sudo ufw allow in on eth0 to any port 8096 proto tcp"
        echo "  sudo ufw allow proto tcp from 172.16.0.0/12 to any port 8096"
    fi
}

public() {
    case "${1:-}" in
    on)
        ssh "$PI" "mkdir -p ~/$DIR/caddy/data ~/$DIR/caddy/config && cat > ~/$DIR/caddy/Caddyfile" <<EOF
{
	http_port 8099
	auto_https disable_redirects
}

$HOST_NAME {
	@public path /s/* /u/* /api/public/* /api/theme /share.html /css/* /js/* /vendor/* /icon.svg /favicon.ico
	handle @public {
		reverse_proxy 127.0.0.1:8096 {
			header_up X-Forwarded-For {remote_host}
		}
	}
	handle {
		respond 404
	}
}
EOF
        ssh "$PI" "docker rm -f pshell-nas-caddy >/dev/null 2>&1 || true; docker run -d --name pshell-nas-caddy \
            --network host --restart unless-stopped \
            -v ~/$DIR/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v ~/$DIR/caddy/data:/data -v ~/$DIR/caddy/config:/config \
            caddy:2.10.2-alpine >/dev/null && docker exec pshell-nas nasctl settings set public_shares true"
        echo "Caddy runs on 443 for $HOST_NAME. Your steps: forward TCP 443 on the Fritzbox to 192.168.178.22,"
        echo "and open it on the Pi: sudo ufw allow in on eth0 to any port 443 proto tcp"
        ;;
    off)
        ssh "$PI" "docker rm -f pshell-nas-caddy >/dev/null 2>&1 || true; docker exec pshell-nas nasctl settings set public_shares false"
        echo "public links are off"
        ;;
    *)
        echo "deploy.sh public on|off" >&2
        exit 2
        ;;
    esac
}

case "${1:-}" in
"") up ;;
public) public "${2:-}" ;;
status) ssh "$PI" "docker ps --filter name=pshell-nas --format '{{.Names}}  {{.Status}}'; curl -s http://127.0.0.1:8096/api/hello; echo" ;;
*)
    echo "deploy.sh [public on|off|status]" >&2
    exit 2
    ;;
esac
