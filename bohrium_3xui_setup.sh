#!/usr/bin/env bash
set -Eeuo pipefail

# Install 3x-ui on a fresh Bohrium node and create one HTTP/SOCKS mixed proxy.
# Usage inside the VPS:
#   bash bohrium_3xui_setup.sh 'ssh root@qqvv1491881.bohrium.tech'
#   PUBLIC_HOST=qqvv1491881.bohrium.tech bash bohrium_3xui_setup.sh

PUBLIC_HOST=${PUBLIC_HOST:-}
PUBLIC_HOST_SOURCE=${PUBLIC_HOST_SOURCE:-}
PANEL_PORT=${PANEL_PORT:-50002}
MIXED_PORT=${MIXED_PORT:-50001}
XUI_VERSION=${XUI_VERSION:-v3.4.2}
XUI_INSTALL_URL=${XUI_INSTALL_URL:-https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh}
XUI_USERNAME=${XUI_USERNAME:-}
XUI_PASSWORD=${XUI_PASSWORD:-}
XUI_WEB_BASE_PATH=${XUI_WEB_BASE_PATH:-}
MIXED_USER=${MIXED_USER:-}
MIXED_PASS=${MIXED_PASS:-}
SG_HTTP_PROXY=${SG_HTTP_PROXY:-http://gemini.op.xdptech.com:8118}
RESULT_FILE=${RESULT_FILE:-/etc/x-ui/bohrium-proxy.env}
SUPERVISOR_CONF=${SUPERVISOR_CONF:-/etc/supervisor/bohrium-3xui-supervisord.conf}
SUPERVISOR_SOCKET=${SUPERVISOR_SOCKET:-/run/bohrium-3xui-supervisor.sock}

log() {
  printf '==> %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  bash bohrium_3xui_setup.sh [PUBLIC_HOST]
  bash bohrium_3xui_setup.sh --host PUBLIC_HOST
  bash bohrium_3xui_setup.sh 'ssh root@qqvv1491881.bohrium.tech'

Optional env:
  PUBLIC_HOST=qqvv1491881.bohrium.tech
  PANEL_PORT=50002
  MIXED_PORT=50001
  XUI_VERSION=v3.4.2
  SG_HTTP_PROXY=http://gemini.op.xdptech.com:8118

Outputs:
  3x-ui panel: http://PUBLIC_HOST:50002/RANDOM_PATH
  HTTP proxy : PUBLIC_HOST:50001
  SOCKS5     : PUBLIC_HOST:50001

The random panel path and generated passwords are saved in:
  /etc/x-ui/install-result.env
  /etc/x-ui/bohrium-proxy.env
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --host)
        if [ "$#" -lt 2 ]; then
          echo "--host requires a value." >&2
          exit 1
        fi
        PUBLIC_HOST=$2
        shift 2
        ;;
      *)
        if [ -z "$PUBLIC_HOST" ]; then
          PUBLIC_HOST=$1
        else
          PUBLIC_HOST="$PUBLIC_HOST $1"
        fi
        shift
        ;;
    esac
  done
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
  fi
}

rand_alnum() {
  local length=$1
  openssl rand -base64 $((length * 2)) | tr -dc 'A-Za-z0-9' | head -c "$length"
}

normalize_host() {
  local value=$1
  value=$(printf '%s' "$value" | tr -d '[:space:]')
  value=${value#*://}
  value=${value%%/*}
  value=${value##*@}
  value=${value%%:*}
  printf '%s' "$value"
}

is_public_host_candidate() {
  local host=$1
  case "$host" in
    ""|localhost|localhost.*|*.local|0.0.0.0|127.*|10.*|192.168.*|169.254.*)
      return 1
      ;;
    bohrium-*)
      case "$host" in
        *.*) ;;
        *) return 1 ;;
      esac
      ;;
  esac

  if printf '%s' "$host" | grep -Eq '^([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$|^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    return 0
  fi
  return 1
}

set_public_host_candidate() {
  local source=$1
  local value=${2:-}
  local host
  host=$(normalize_host "$value")
  if is_public_host_candidate "$host"; then
    PUBLIC_HOST=$host
    PUBLIC_HOST_SOURCE=$source
    return 0
  fi
  return 1
}

detect_public_host() {
  local candidate name typed_host

  if set_public_host_candidate "argument-or-env:PUBLIC_HOST" "$PUBLIC_HOST"; then
    log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
    return
  fi

  for name in \
    BOHRIUM_HOST BOHRIUM_DOMAIN BOHRIUM_PUBLIC_HOST \
    BOHRCLAW_HOST BOHRCLAW_DOMAIN BOHRCLAW_PUBLIC_HOST \
    PUBLIC_DOMAIN PUBLIC_HOSTNAME EXTERNAL_HOST INSTANCE_HOST SERVER_HOST; do
    candidate=${!name:-}
    if set_public_host_candidate "env:$name" "$candidate"; then
      log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
      return
    fi
  done

  if [ -t 0 ] || [ -r /dev/tty ]; then
    echo "Could not auto-detect the Bohrium public domain from inside the VPS." >&2
    echo "Paste the SSH command or host shown in the Bohrium web UI." >&2
    echo "Example: ssh root@qqvv1491881.bohrium.tech" >&2
    printf 'Bohrium SSH command or host: ' >&2
    if read -r typed_host </dev/tty; then
      if set_public_host_candidate "interactive-input" "$typed_host"; then
        log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
        return
      fi
    fi
  fi

  echo "Could not auto-detect PUBLIC_HOST." >&2
  echo "Run again with the current Bohrium SSH/public host, e.g.:" >&2
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_3xui_setup.sh) 'ssh root@qqvv1491881.bohrium.tech'" >&2
  exit 1
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl jq tar gzip openssl iproute2 procps psmisc supervisor
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl jq tar gzip openssl iproute procps-ng psmisc supervisor
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl jq tar gzip openssl iproute procps-ng psmisc supervisor
  else
    echo "Unsupported package manager. Need apt, dnf, or yum." >&2
    exit 1
  fi
}

free_port() {
  local port=$1
  local pids
  pids=$(ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $NF}' | grep -Eo 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
  if [ -n "$pids" ]; then
    log "Freeing TCP port $port"
    for pid in $pids; do
      kill "$pid" >/dev/null 2>&1 || true
    done
    sleep 1
    for pid in $pids; do
      kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
    done
  fi
}

stop_old_3xui() {
  if [ -S "$SUPERVISOR_SOCKET" ] && command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl -c "$SUPERVISOR_CONF" stop x-ui >/dev/null 2>&1 || true
    supervisorctl -c "$SUPERVISOR_CONF" shutdown >/dev/null 2>&1 || true
  fi
  stop_known_bohrium_services
  pkill -f '/usr/local/x-ui/x-ui' >/dev/null 2>&1 || true
  pkill -f 'xray-linux-.* -c /usr/local/x-ui' >/dev/null 2>&1 || true
  free_port "$PANEL_PORT"
  free_port "$MIXED_PORT"
}

stop_known_bohrium_services() {
  local conf
  for conf in /etc/supervisor/openclaw-supervisord.conf /etc/supervisor/supervisord.conf; do
    [ -f "$conf" ] || continue
    supervisorctl -c "$conf" stop sing-box v2ray-sub openclaw-gateway >/dev/null 2>&1 || true
    supervisorctl -c "$conf" remove sing-box v2ray-sub openclaw-gateway >/dev/null 2>&1 || true
  done
  pkill -f '/etc/s-box/sing-box' >/dev/null 2>&1 || true
  pkill -f 'python3 -m http.server .*50002' >/dev/null 2>&1 || true
  pkill -f 'openclaw.*gateway|openclaw-gateway' >/dev/null 2>&1 || true
}

generate_credentials() {
  XUI_USERNAME=${XUI_USERNAME:-u$(rand_alnum 9)}
  XUI_PASSWORD=${XUI_PASSWORD:-p$(rand_alnum 19)}
  XUI_WEB_BASE_PATH=${XUI_WEB_BASE_PATH:-b$(rand_alnum 17)}
  MIXED_USER=${MIXED_USER:-s$(rand_alnum 8)}
  MIXED_PASS=${MIXED_PASS:-m$(rand_alnum 18)}
}

install_3xui() {
  log "Installing 3x-ui $XUI_VERSION"
  export XUI_NONINTERACTIVE=1
  export XUI_DB_TYPE=sqlite
  export XUI_SSL_MODE=none
  export XUI_ENABLE_FAIL2BAN=false
  export XUI_PANEL_PORT="$PANEL_PORT"
  export XUI_USERNAME
  export XUI_PASSWORD
  export XUI_WEB_BASE_PATH
  export XUI_SERVER_IP="$PUBLIC_HOST"

  if [ -n "$XUI_VERSION" ]; then
    bash <(curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 "$XUI_INSTALL_URL") "$XUI_VERSION"
  else
    bash <(curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 "$XUI_INSTALL_URL")
  fi
}

enforce_panel_settings() {
  local api_token web_path
  web_path=$(printf '%s' "$XUI_WEB_BASE_PATH" | sed 's#^/*##; s#/*$##')
  /usr/local/x-ui/x-ui setting \
    -username "$XUI_USERNAME" \
    -password "$XUI_PASSWORD" \
    -port "$PANEL_PORT" \
    -webBasePath "$web_path" >/dev/null
  api_token=$(/usr/local/x-ui/x-ui setting -getApiToken true 2>/dev/null | awk '/apiToken:/ {print $2; exit}' || true)

  install -d -m 755 /etc/x-ui
  umask 077
  cat > /etc/x-ui/install-result.env <<EOF
XUI_USERNAME='$XUI_USERNAME'
XUI_PASSWORD='$XUI_PASSWORD'
XUI_PANEL_PORT='$PANEL_PORT'
XUI_WEB_BASE_PATH='$web_path'
XUI_ACCESS_URL='http://$PUBLIC_HOST:$PANEL_PORT/$web_path'
XUI_API_TOKEN='$api_token'
XUI_DB_TYPE='sqlite'
EOF
  chmod 600 /etc/x-ui/install-result.env
}

write_supervisor_config() {
  mkdir -p /var/log/bohrium-3xui /run /etc/supervisor
  cat > "$SUPERVISOR_CONF" <<EOF
[unix_http_server]
file=$SUPERVISOR_SOCKET
chmod=0700

[supervisord]
logfile=/var/log/bohrium-3xui/supervisord.log
pidfile=/run/bohrium-3xui-supervisord.pid
childlogdir=/var/log/bohrium-3xui
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$SUPERVISOR_SOCKET

[program:x-ui]
command=/usr/local/x-ui/x-ui
directory=/usr/local/x-ui
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/var/log/bohrium-3xui/x-ui.out.log
stderr_logfile=/var/log/bohrium-3xui/x-ui.err.log
environment=XRAY_VMESS_AEAD_FORCED="false"
EOF
}

start_3xui() {
  if [ ! -x /usr/local/x-ui/x-ui ]; then
    echo "3x-ui binary not found at /usr/local/x-ui/x-ui" >&2
    exit 1
  fi

  write_supervisor_config
  if [ -S "$SUPERVISOR_SOCKET" ]; then
    supervisorctl -c "$SUPERVISOR_CONF" reread >/dev/null 2>&1 || true
    supervisorctl -c "$SUPERVISOR_CONF" update >/dev/null 2>&1 || true
    supervisorctl -c "$SUPERVISOR_CONF" restart x-ui >/dev/null 2>&1 || true
  else
    supervisord -c "$SUPERVISOR_CONF"
  fi

  local i
  for i in $(seq 1 30); do
    if ss -ltn 2>/dev/null | awk -v p=":${PANEL_PORT}$" '$4 ~ p {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done

  echo "3x-ui panel did not start on port $PANEL_PORT." >&2
  tail -n 80 /var/log/bohrium-3xui/x-ui.err.log 2>/dev/null || true
  tail -n 80 /var/log/bohrium-3xui/x-ui.out.log 2>/dev/null || true
  exit 1
}

load_install_result() {
  if [ -r /etc/x-ui/install-result.env ]; then
    # shellcheck disable=SC1091
    . /etc/x-ui/install-result.env
  fi
  XUI_PANEL_PORT=${XUI_PANEL_PORT:-$PANEL_PORT}
  XUI_WEB_BASE_PATH=${XUI_WEB_BASE_PATH:-$XUI_WEB_BASE_PATH}
  XUI_USERNAME=${XUI_USERNAME:-$XUI_USERNAME}
  XUI_PASSWORD=${XUI_PASSWORD:-$XUI_PASSWORD}
}

panel_base_candidates() {
  local path
  path=$(printf '%s' "${XUI_WEB_BASE_PATH:-}" | sed 's#^/*##; s#/*$##')
  if [ -n "$path" ]; then
    printf 'http://127.0.0.1:%s/%s\n' "$PANEL_PORT" "$path"
  fi
  printf 'http://127.0.0.1:%s\n' "$PANEL_PORT"
}

login_panel() {
  COOKIE_FILE=$(mktemp)
  export COOKIE_FILE
  local response http_code url body ok token

  while IFS= read -r base; do
    curl -fsS -c "$COOKIE_FILE" -b "$COOKIE_FILE" --connect-timeout 5 --max-time 15 "${base%/}/" >/dev/null || true
    PANEL_BASE=$base
    token=$(get_csrf_token || true)
    [ -n "$token" ] || continue
    url="${base%/}/login"
    body=$(mktemp)
    http_code=$(curl -sS -o "$body" -w '%{http_code}' -c "$COOKIE_FILE" \
      -b "$COOKIE_FILE" \
      -H 'X-Requested-With: XMLHttpRequest' \
      -H "X-CSRF-Token: $token" \
      -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
      --connect-timeout 5 --max-time 15 \
      --data-urlencode "username=$XUI_USERNAME" \
      --data-urlencode "password=$XUI_PASSWORD" \
      --data-urlencode "twoFactorCode=" \
      "$url" || true)
    response=$(cat "$body")
    rm -f "$body"
    ok=$(printf '%s' "$response" | jq -r 'if type=="object" then .success // false else false end' 2>/dev/null || true)
    if [ "$http_code" = "200" ] && { [ "$ok" = "true" ] || printf '%s' "$response" | grep -qi '"success"[[:space:]]*:[[:space:]]*true'; }; then
      PANEL_BASE=$base
      export PANEL_BASE
      return 0
    fi
  done <<EOF
$(panel_base_candidates)
EOF

  echo "Could not log into 3x-ui local API." >&2
  echo "Check /etc/x-ui/install-result.env and /var/log/bohrium-3xui/." >&2
  exit 1
}

get_csrf_token() {
  curl -fsS -c "$COOKIE_FILE" -b "$COOKIE_FILE" \
    -H 'X-Requested-With: XMLHttpRequest' \
    --connect-timeout 5 --max-time 15 \
    "${PANEL_BASE%/}/csrf-token" | jq -r 'if .success == true then .obj // empty else empty end'
}

parse_http_proxy() {
  local proxy=$1 authority userinfo hostport
  proxy=${proxy#http://}
  proxy=${proxy#https://}
  authority=${proxy%%/*}
  if printf '%s' "$authority" | grep -q '@'; then
    userinfo=${authority%@*}
    SG_PROXY_USER=${userinfo%%:*}
    SG_PROXY_PASS=${userinfo#*:}
    [ "$SG_PROXY_PASS" = "$userinfo" ] && SG_PROXY_PASS=
    hostport=${authority##*@}
  else
    SG_PROXY_USER=
    SG_PROXY_PASS=
    hostport=$authority
  fi
  SG_PROXY_HOST=${hostport%:*}
  SG_PROXY_PORT=${hostport##*:}
  if [ -z "$SG_PROXY_HOST" ] || [ -z "$SG_PROXY_PORT" ] || [ "$SG_PROXY_HOST" = "$SG_PROXY_PORT" ]; then
    echo "Invalid SG_HTTP_PROXY. Expected http://host:port, got: $proxy" >&2
    exit 1
  fi
}

delete_existing_mixed_inbounds() {
  local list ids id token
  list=$(curl -fsS -b "$COOKIE_FILE" \
    -H 'X-Requested-With: XMLHttpRequest' \
    --connect-timeout 5 --max-time 15 \
    "${PANEL_BASE%/}/panel/api/inbounds/list" || true)
  [ -n "$list" ] || return 0
  ids=$(printf '%s' "$list" | jq -r --argjson p "$MIXED_PORT" '.obj[]? | select(.port == $p or .remark == "bohrium-mixed") | .id' 2>/dev/null || true)
  for id in $ids; do
    token=$(get_csrf_token || true)
    curl -fsS -X POST -b "$COOKIE_FILE" \
      -H 'X-Requested-With: XMLHttpRequest' \
      -H "X-CSRF-Token: $token" \
      --connect-timeout 5 --max-time 15 \
      "${PANEL_BASE%/}/panel/api/inbounds/del/${id}" >/dev/null || true
  done
}

add_mixed_inbound() {
  local payload response ok token
  payload=$(jq -nc \
    --arg remark "bohrium-mixed" \
    --arg host "$PUBLIC_HOST" \
    --arg user "$MIXED_USER" \
    --arg pass "$MIXED_PASS" \
    --argjson port "$MIXED_PORT" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      protocol: "mixed",
      expiryTime: 0,
      total: 0,
      settings: {
        auth: "password",
        accounts: [{user: $user, pass: $pass}],
        udp: false,
        ip: "127.0.0.1"
      },
      streamSettings: {
        network: "tcp",
        security: "none",
        tcpSettings: {
          acceptProxyProtocol: false,
          header: {type: "none"}
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls"],
        metadataOnly: false,
        routeOnly: false
      },
      trafficReset: "never",
      shareAddrStrategy: "custom",
      shareAddr: $host,
      subSortIndex: 1,
      tag: "bohrium-mixed"
    }')

  token=$(get_csrf_token || true)
  if [ -z "$token" ]; then
    echo "Could not fetch CSRF token before creating mixed inbound." >&2
    exit 1
  fi
  response=$(curl -fsS -X POST -b "$COOKIE_FILE" \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H "X-CSRF-Token: $token" \
    -H 'Content-Type: application/json' \
    --connect-timeout 5 --max-time 20 \
    -d "$payload" "${PANEL_BASE%/}/panel/api/inbounds/add")
  ok=$(printf '%s' "$response" | jq -r 'if type=="object" then .success // false else false end' 2>/dev/null || true)
  if [ "$ok" != "true" ] && ! printf '%s' "$response" | grep -qi '"success"[[:space:]]*:[[:space:]]*true'; then
    echo "Failed to create mixed inbound:" >&2
    printf '%s\n' "$response" >&2
    exit 1
  fi
}

configure_sg_outbound() {
  local token current_config updated_config response ok proxy_settings
  parse_http_proxy "$SG_HTTP_PROXY"
  log "Configuring Xray outbound through SG HTTP proxy: $SG_PROXY_HOST:$SG_PROXY_PORT"

  current_config=$(mktemp)
  updated_config=$(mktemp)
  token=$(get_csrf_token || true)
  curl -fsS -X POST -b "$COOKIE_FILE" \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H "X-CSRF-Token: $token" \
    --connect-timeout 5 --max-time 20 \
    "${PANEL_BASE%/}/panel/api/xray/" \
    | jq -r '.obj | fromjson | .xraySetting' > "$current_config"

  proxy_settings=$(jq -nc \
    --arg host "$SG_PROXY_HOST" \
    --argjson port "$SG_PROXY_PORT" \
    --arg user "$SG_PROXY_USER" \
    --arg pass "$SG_PROXY_PASS" \
    '{
      servers: [
        (
          {address: $host, port: $port}
          + (if $user != "" then {users: [{user: $user, pass: $pass}]} else {} end)
        )
      ]
    }')

  jq --argjson settings "$proxy_settings" '
    .outbounds = [
      {protocol: "http", tag: "direct", settings: $settings},
      {protocol: "blackhole", tag: "blocked", settings: {}}
    ]
    | .routing.rules = (
        ([.routing.rules[]? | select((.inboundTag // []) != ["api"])])
        | [{type: "field", inboundTag: ["api"], outboundTag: "api"}] + .
      )
  ' "$current_config" > "$updated_config"

  token=$(get_csrf_token || true)
  response=$(curl -fsS -X POST -b "$COOKIE_FILE" \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H "X-CSRF-Token: $token" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    --connect-timeout 5 --max-time 30 \
    --data-urlencode "xraySetting@$updated_config" \
    --data-urlencode "outboundTestUrl=https://ipinfo.io/ip" \
    "${PANEL_BASE%/}/panel/api/xray/update")
  rm -f "$current_config" "$updated_config"

  ok=$(printf '%s' "$response" | jq -r 'if type=="object" then .success // false else false end' 2>/dev/null || true)
  if [ "$ok" != "true" ]; then
    echo "Failed to configure SG outbound:" >&2
    printf '%s\n' "$response" >&2
    exit 1
  fi
  sleep 2
}

wait_mixed_port() {
  local i
  for i in $(seq 1 20); do
    if ss -ltn 2>/dev/null | awk -v p=":${MIXED_PORT}$" '$4 ~ p {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 1
  done
  echo "Mixed proxy inbound was created, but port $MIXED_PORT is not listening yet." >&2
  supervisorctl -c "$SUPERVISOR_CONF" status 2>/dev/null || true
  exit 1
}

write_result() {
  local web_path panel_url
  web_path=$(printf '%s' "$XUI_WEB_BASE_PATH" | sed 's#^/*##; s#/*$##')
  panel_url="http://${PUBLIC_HOST}:${PANEL_PORT}/${web_path}"
  install -d -m 755 /etc/x-ui
  umask 077
  cat > "$RESULT_FILE" <<EOF
PUBLIC_HOST='$PUBLIC_HOST'
PANEL_URL='$panel_url'
PANEL_PORT='$PANEL_PORT'
PANEL_PATH='$web_path'
PANEL_USERNAME='$XUI_USERNAME'
PANEL_PASSWORD='$XUI_PASSWORD'
MIXED_PORT='$MIXED_PORT'
MIXED_USER='$MIXED_USER'
MIXED_PASS='$MIXED_PASS'
SG_HTTP_PROXY='$SG_HTTP_PROXY'
HTTP_PROXY_URL='http://$MIXED_USER:$MIXED_PASS@$PUBLIC_HOST:$MIXED_PORT'
SOCKS5_PROXY_URL='socks5://$MIXED_USER:$MIXED_PASS@$PUBLIC_HOST:$MIXED_PORT'
EOF
  chmod 600 "$RESULT_FILE"
}

print_result() {
  local web_path panel_url
  web_path=$(printf '%s' "$XUI_WEB_BASE_PATH" | sed 's#^/*##; s#/*$##')
  panel_url="http://${PUBLIC_HOST}:${PANEL_PORT}/${web_path}"
  cat <<EOF

== 3x-ui panel ==
URL      : $panel_url
Username : $XUI_USERNAME
Password : $XUI_PASSWORD

== HTTP / SOCKS5 mixed proxy ==
Host     : $PUBLIC_HOST
Port     : $MIXED_PORT
Username : $MIXED_USER
Password : $MIXED_PASS
HTTP URL : http://$MIXED_USER:$MIXED_PASS@$PUBLIC_HOST:$MIXED_PORT
SOCKS5   : socks5://$MIXED_USER:$MIXED_PASS@$PUBLIC_HOST:$MIXED_PORT
Egress   : SG via $SG_HTTP_PROXY

Saved to : $RESULT_FILE
Recover  : cat $RESULT_FILE
EOF
}

main() {
  parse_args "$@"
  need_root
  detect_public_host
  generate_credentials
  install_deps
  log "Cleaning old 3x-ui processes and ports: $PANEL_PORT $MIXED_PORT"
  stop_old_3xui
  install_3xui
  enforce_panel_settings
  load_install_result
  start_3xui
  login_panel
  delete_existing_mixed_inbounds
  add_mixed_inbound
  configure_sg_outbound
  wait_mixed_port
  write_result
  print_result
}

main "$@"
