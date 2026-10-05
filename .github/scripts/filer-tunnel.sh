#!/usr/bin/env bash
# The SeaweedFS filer that stores the library speaks gRPC only inside its cluster. `start` opens an
# SSH dynamic tunnel (a SOCKS5 proxy on 127.0.0.1:$PORT) to the host the cluster runs on, as a user
# that may only forward ports, asks the master's ClusterIP which pod leads (its IP changes when the
# pod is recreated), and writes filer=<pod>:<grpc port> and proxy=127.0.0.1:$PORT to $GITHUB_OUTPUT.
# ripper then links library files the bucket already holds instead of uploading them
# (SekaiStoryRipper ADR-0019). `stop` closes the tunnel.
#
# Environment: SSH_KEY, KNOWN_HOSTS (secrets), SSH_HOST, SSH_USER, MASTER (host:port of the
# master's HTTP API, reached through the tunnel), FILER_GRPC_PORT (default 18888).
set -euo pipefail

PORT=${PORT:-1081}
FILER_GRPC_PORT=${FILER_GRPC_PORT:-18888}
work=${RUNNER_TEMP:-/tmp}/filer-tunnel

stop() {
  if [[ -f $work/ssh.pid ]]; then
    kill "$(cat "$work/ssh.pid")" 2>/dev/null || true
    rm -f "$work/ssh.pid"
  fi
  rm -rf "$work"
}

start() {
  for name in SSH_KEY KNOWN_HOSTS SSH_HOST SSH_USER MASTER; do
    if [[ -z ${!name:-} ]]; then
      echo "::error::$name is not set"
      return 1
    fi
  done
  (umask 077 && mkdir -p "$work" && printf '%s\n' "$SSH_KEY" >"$work/key" && printf '%s\n' "$KNOWN_HOSTS" >"$work/known_hosts")
  # The host key comes from the secret: never accept an unknown one.
  ssh -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o UserKnownHostsFile="$work/known_hosts" -o StrictHostKeyChecking=yes \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -o ControlMaster=no -N -D "127.0.0.1:$PORT" "$SSH_USER@$SSH_HOST" &
  echo $! >"$work/ssh.pid"
  local status=""
  for _ in {1..30}; do
    status=$(curl -fsS -m 5 --socks5-hostname "127.0.0.1:$PORT" "http://$MASTER/cluster/status" 2>/dev/null) && break
    kill -0 "$(cat "$work/ssh.pid")" 2>/dev/null || { echo "::error::the SSH tunnel to $SSH_HOST exited"; return 1; }
    sleep 1
  done
  local leader
  leader=$(jq -er '.Leader' <<<"$status" 2>/dev/null) || { echo "::error::no answer from the master $MASTER through the tunnel"; return 1; }
  local pod=${leader%%:*}
  echo "tunnel to $SSH_HOST up; leader pod $pod"
  echo "filer=$pod:$FILER_GRPC_PORT" >>"$GITHUB_OUTPUT"
  echo "proxy=127.0.0.1:$PORT" >>"$GITHUB_OUTPUT"
}

case ${1:-} in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
