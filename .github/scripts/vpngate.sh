#!/usr/bin/env bash
# The JP game servers refuse addresses outside Japan, GitHub's runners included. `start` connects
# to a VPN Gate (https://www.vpngate.net) server in Japan and serves an HTTP proxy on
# 127.0.0.1:$PORT whose outgoing connections leave through the tunnel; it writes proxy=<url> to
# $GITHUB_OUTPUT. Only the proxy uses the tunnel: the runner's own routes stay as they are, so
# whatever does not go through the proxy (S3, GitHub) stays direct. `stop` disconnects.
set -euo pipefail

PORT=${PORT:-3128}
CANDIDATES=${CANDIDATES:-10}
TABLE=100
work=${RUNNER_TEMP:-/tmp}/vpngate

stop() {
  if [[ -f $work/tinyproxy.pid ]]; then
    kill "$(cat "$work/tinyproxy.pid")" 2>/dev/null || true
    rm -f "$work/tinyproxy.pid"
  fi
  if [[ -f $work/openvpn.pid ]]; then
    local pid
    pid=$(cat "$work/openvpn.pid")
    sudo kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      sudo kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    sudo rm -f "$work/openvpn.pid"
  fi
  while sudo ip rule del table "$TABLE" 2>/dev/null; do :; done
}

# Brings up the tunnel from $work/vpngate.ovpn and the proxy behind it; fails if the proxy does not
# come out in Japan.
connect() {
  sudo rm -f "$work/openvpn.log"
  # --route-noexec: neither the server's redirect-gateway nor its routes are applied.
  # VPN Gate servers (SoftEther) only speak AES-128-CBC and have old certificates.
  sudo openvpn --config "$work/vpngate.ovpn" --dev tun0 --route-noexec \
    --data-ciphers AES-256-GCM:AES-128-GCM:AES-128-CBC --data-ciphers-fallback AES-128-CBC \
    --tls-cipher 'DEFAULT:@SECLEVEL=0' --connect-timeout 10 --connect-retry-max 1 \
    --ping 10 --ping-restart 60 --persist-tun \
    --daemon --writepid "$work/openvpn.pid" --log "$work/openvpn.log"
  local up=false
  for _ in {1..30}; do
    if sudo grep -q 'Initialization Sequence Completed' "$work/openvpn.log" 2>/dev/null; then
      up=true
      break
    fi
    sleep 1
  done
  if [[ $up != true ]]; then
    sudo tail -n 3 "$work/openvpn.log" 2>/dev/null | sed 's/^/  openvpn: /' || true
    return 1
  fi

  # Packets from the tunnel's address (only the proxy binds to it) take the tunnel.
  local tun_ip
  tun_ip=$(ip -4 -o addr show dev tun0 | awk '{print $4}' | cut -d/ -f1)
  [[ -n $tun_ip ]] || return 1
  sudo ip route replace default dev tun0 table "$TABLE"
  sudo ip rule add from "$tun_ip" table "$TABLE"
  sudo sysctl -qw net.ipv4.conf.tun0.rp_filter=2

  cat >"$work/tinyproxy.conf" <<EOF
Port $PORT
Listen 127.0.0.1
Bind $tun_ip
Allow 127.0.0.1
ConnectPort 443
Timeout 600
MaxClients 100
DisableViaHeader Yes
LogLevel Warning
LogFile "$work/tinyproxy.log"
PidFile "$work/tinyproxy.pid"
EOF
  tinyproxy -c "$work/tinyproxy.conf"

  local trace loc
  trace=$(curl -fsS --max-time 20 --retry 2 --retry-connrefused --proxy "http://127.0.0.1:$PORT" \
    https://www.cloudflare.com/cdn-cgi/trace) || return 1
  loc=$(sed -n 's/^loc=//p' <<<"$trace")
  echo "  exit address in ${loc:-?}"
  [[ $loc == JP ]]
}

start() {
  mkdir -p "$work"
  sudo apt-get update -q >/dev/null
  sudo apt-get install -yq --no-install-recommends openvpn tinyproxy >/dev/null
  sudo systemctl disable --now tinyproxy >/dev/null 2>&1 || true

  # CSV after a "*vpn_servers" line: HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,
  # NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64
  # Lines end in CRLF, which GNU base64 refuses.
  curl -fsS --retry 3 --max-time 60 https://www.vpngate.net/api/iphone/ | tr -d '\r' >"$work/servers.csv"
  local servers
  mapfile -t servers < <(awk -F, '$7 == "JP" && NF >= 15 && $NF != "" { print $3 "," $2 "," $5 "," $NF }' \
    "$work/servers.csv" | sort -t, -k1,1nr | sed -n "1,${CANDIDATES}p")
  echo "${#servers[@]} VPN Gate servers in Japan to try"

  local line score ip speed config
  for line in "${servers[@]}"; do
    IFS=, read -r score ip speed config <<<"$line"
    echo "$ip (score $score, $((speed / 1000000)) Mbps)"
    if ! base64 -d <<<"$config" 2>/dev/null | tr -d '\r' >"$work/vpngate.ovpn"; then
      echo "  bad config"
      continue
    fi
    if connect; then
      # For the log only: what the game's version API answers through the proxy.
      echo "  game-version.sekai.colorfulpalette.org: HTTP $(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 20 --proxy "http://127.0.0.1:$PORT" https://game-version.sekai.colorfulpalette.org/ || true)"
      echo "proxy=http://127.0.0.1:$PORT" >>"$GITHUB_OUTPUT"
      return 0
    fi
    stop
  done
  echo "::error::no VPN Gate server in Japan could be used"
  return 1
}

case ${1:-start} in
  start) start ;;
  stop) stop ;;
  *)
    echo "usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac
