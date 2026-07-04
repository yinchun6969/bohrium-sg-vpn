#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuild the working Bohrium SG TCP VPN setup and add an optional Cloudflare
# temporary tunnel for the VMess-WS node. This is a compatibility/reliability
# variant, not an anti-detection or policy-bypass mechanism.
# Usage on the VPS:
#   bash scripts/bohrium_sg_vpn_argo_setup.sh
#   bash scripts/bohrium_sg_vpn_argo_setup.sh pjqk1492005.bohrium.tech
#   PUBLIC_HOST=pjqk1492005.bohrium.tech bash scripts/bohrium_sg_vpn_argo_setup.sh
#
# Outputs:
#   VMess-WS      : $PUBLIC_HOST:50001
#   V2Ray sub URL : http://$PUBLIC_HOST:50002/v2ray.txt
#   VLESS Reality : $PUBLIC_HOST:50003
#   Shadowsocks   : $PUBLIC_HOST:50004
#   Trojan        : $PUBLIC_HOST:50005
#   Argo VMess-WS : generated trycloudflare.com:443, when cloudflared succeeds
#
# ponytail: TCP only because this Bohrium mapping does not forward UDP; HY2/TUIC need UDP.

SBOX_DIR=${SBOX_DIR:-/etc/s-box}
SING_BOX_VERSION=${SING_BOX_VERSION:-1.10.7}
UUID=${UUID:-}
PUBLIC_HOST=${PUBLIC_HOST:-}
PUBLIC_HOST_SOURCE=${PUBLIC_HOST_SOURCE:-}
SG_HTTP_PROXY=${SG_HTTP_PROXY:-${HTTPS_PROXY:-${HTTP_PROXY:-http://gemini.op.xdptech.com:8118}}}
SUPERVISOR_CONF=${SUPERVISOR_CONF:-}
VPN_PORTS=${VPN_PORTS:-"50001 50002 50003 50004 50005"}
ARGO_ENABLE=${ARGO_ENABLE:-1}
ARGO_DOMAIN=${ARGO_DOMAIN:-}

log() {
  printf '==> %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  bash bohrium_sg_vpn_argo_setup.sh [PUBLIC_HOST]
  bash bohrium_sg_vpn_argo_setup.sh --host PUBLIC_HOST
  bash bohrium_sg_vpn_argo_setup.sh 'ssh root@qqvv1491881.bohrium.tech'

Optional env:
  PUBLIC_HOST=pjqk1492005.bohrium.tech
  SG_HTTP_PROXY=http://gemini.op.xdptech.com:8118
  UUID=your-fixed-uuid

If PUBLIC_HOST is omitted, the script tries to discover a *.bohrium.tech host
from env, hostname, saved state, and local system files. If that fails, it asks
you to paste the SSH command shown in the Bohrium web UI.
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

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl jq tar gzip openssl iproute2 python3 supervisor procps psmisc
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl jq tar gzip openssl iproute python3 supervisor procps-ng psmisc
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl jq tar gzip openssl iproute python3 supervisor procps-ng psmisc
  else
    echo "Unsupported package manager. Need apt, dnf, or yum." >&2
    exit 1
  fi
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

extract_bohrium_host() {
  grep -Eao '[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.bohrium\.tech' 2>/dev/null | head -n 1 || true
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
  local candidate name file public_ip typed_host

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

  candidate=$(printenv 2>/dev/null | extract_bohrium_host)
  if set_public_host_candidate "env-scan:bohrium.tech" "$candidate"; then
    log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
    return
  fi

  candidate=$(hostname -f 2>/dev/null || true)
  if set_public_host_candidate "hostname -f" "$candidate"; then
    log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
    return
  fi

  candidate=$(hostname 2>/dev/null || true)
  if set_public_host_candidate "hostname" "$candidate"; then
    log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
    return
  fi

  for file in "$SBOX_DIR/public_host" /etc/hostname /etc/hosts /etc/motd /etc/issue /root/.bash_history /root/.zsh_history; do
    [ -r "$file" ] || continue
    candidate=$(extract_bohrium_host < "$file")
    if set_public_host_candidate "file:$file" "$candidate"; then
      log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
      return
    fi
  done

  public_ip=$(curl --noproxy '*' -fsS4m 8 https://api.ipify.org || true)
  if set_public_host_candidate "public-ip:fallback" "$public_ip"; then
    log "PUBLIC_HOST=$PUBLIC_HOST (source: $PUBLIC_HOST_SOURCE)"
    echo "Warning: only a public IPv4 was auto-detected. If clients cannot connect, rerun with the Bohrium host, e.g.:" >&2
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) pjqk1492005.bohrium.tech" >&2
    return
  fi

  if [ -t 0 ] || [ -r /dev/tty ]; then
    echo "Could not auto-detect the Bohrium host from inside the VPS." >&2
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
  echo "Run again with the Bohrium SSH/public host, e.g.:" >&2
  echo "  bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) 'ssh root@qqvv1491881.bohrium.tech'" >&2
  echo "or:" >&2
  echo "  PUBLIC_HOST=qqvv1491881.bohrium.tech bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh)" >&2
  exit 1
}

persist_public_host() {
  mkdir -p "$SBOX_DIR"
  printf '%s\n' "$PUBLIC_HOST" > "$SBOX_DIR/public_host"
}

terminate_pid() {
  local pid=$1
  [ -n "$pid" ] || return 0
  kill -0 "$pid" >/dev/null 2>&1 || return 0
  kill "$pid" >/dev/null 2>&1 || true
  sleep 1
  kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true
}

kill_pid_file() {
  local file=$1
  local pid
  [ -r "$file" ] || return 0
  pid=$(cat "$file" 2>/dev/null || true)
  if printf '%s' "$pid" | grep -Eq '^[0-9]+$'; then
    terminate_pid "$pid"
  fi
  rm -f "$file"
}

kill_known_vpn_processes() {
  kill_pid_file "$SBOX_DIR/sing-box.pid"
  kill_pid_file "$SBOX_DIR/v2ray-sub.pid"
  kill_pid_file "$SBOX_DIR/cloudflared.pid"
  pkill -TERM -f "$SBOX_DIR/sing-box run -c $SBOX_DIR/sb.json" >/dev/null 2>&1 || true
  pkill -TERM -f "python3 -m http.server 50002 .*--directory $SBOX_DIR/sub" >/dev/null 2>&1 || true
  pkill -TERM -f "$SBOX_DIR/cloudflared tunnel --url http://127.0.0.1:50001" >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f "$SBOX_DIR/sing-box run -c $SBOX_DIR/sb.json" >/dev/null 2>&1 || true
  pkill -KILL -f "python3 -m http.server 50002 .*--directory $SBOX_DIR/sub" >/dev/null 2>&1 || true
  pkill -KILL -f "$SBOX_DIR/cloudflared tunnel --url http://127.0.0.1:50001" >/dev/null 2>&1 || true
}

kill_port_listeners() {
  local ports=${*:-$VPN_PORTS}
  local port pids pid

  if command -v fuser >/dev/null 2>&1; then
    for port in $ports; do
      fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    done
  fi

  sleep 1
  if command -v ss >/dev/null 2>&1; then
    for port in $ports; do
      pids=$(ss -H -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" {print}' | grep -Eo 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
      for pid in $pids; do
        terminate_pid "$pid"
      done
    done
  fi

  if command -v lsof >/dev/null 2>&1; then
    for port in $ports; do
      pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)
      for pid in $pids; do
        terminate_pid "$pid"
      done
    done
  fi

  for port in $ports; do
    if command -v ss >/dev/null 2>&1 && ss -H -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" {found=1} END {exit found ? 0 : 1}'; then
      echo "Port $port is still occupied after cleanup:" >&2
      ss -ltnp 2>/dev/null | grep ":$port " >&2 || true
      exit 1
    fi

    if command -v lsof >/dev/null 2>&1 && lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "Port $port is still occupied after cleanup:" >&2
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
      exit 1
    fi
  done
}

proxy_host_port() {
  local p=${SG_HTTP_PROXY#http://}
  p=${p#https://}
  p=${p%%/*}
  PROXY_HOST=${p%%:*}
  PROXY_PORT=${p##*:}
  if [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ] || [ "$PROXY_HOST" = "$PROXY_PORT" ]; then
    echo "SG_HTTP_PROXY must look like http://host:port or host:port; got: $SG_HTTP_PROXY" >&2
    exit 1
  fi
}

detect_supervisor_conf() {
  if [ -n "$SUPERVISOR_CONF" ]; then
    return
  fi
  if [ -f /etc/supervisor/openclaw-supervisord.conf ]; then
    SUPERVISOR_CONF=/etc/supervisor/openclaw-supervisord.conf
  else
    SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
  fi
}

svctl() {
  supervisorctl -c "$SUPERVISOR_CONF" "$@"
}

free_vpn_ports() {
  log "Cleaning VPN processes and ports: $VPN_PORTS"
  svctl stop sing-box >/dev/null 2>&1 || true
  svctl stop v2ray-sub >/dev/null 2>&1 || true
  svctl remove sing-box >/dev/null 2>&1 || true
  svctl remove v2ray-sub >/dev/null 2>&1 || true
  rm -f /etc/supervisor/conf.d/sing-box.conf /etc/supervisor/conf.d/v2ray-sub.conf
  svctl reread >/dev/null 2>&1 || true
  svctl update >/dev/null 2>&1 || true
  kill_known_vpn_processes
  kill_port_listeners $VPN_PORTS
}

stop_openclaw_and_free_ports() {
  local conf
  log "Stopping OpenClaw gateway if present"
  svctl stop openclaw-gateway >/dev/null 2>&1 || true
  for conf in /etc/supervisor/conf.d/*openclaw*.conf /etc/supervisor/conf.d/*bohrclaw*.conf; do
    [ -e "$conf" ] || continue
    mv "$conf" "$conf.disabled"
  done
  svctl reread >/dev/null 2>&1 || true
  svctl update >/dev/null 2>&1 || true
  pidof openclaw 2>/dev/null | xargs -r kill >/dev/null 2>&1 || true
  pkill -TERM -f 'openclaw-gateway|bohrclaw-gateway' >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -f 'openclaw-gateway|bohrclaw-gateway' >/dev/null 2>&1 || true
  kill_port_listeners 50001
}

install_sing_box() {
  mkdir -p "$SBOX_DIR"
  if [ -x "$SBOX_DIR/sing-box" ] && "$SBOX_DIR/sing-box" version | grep -q "version $SING_BOX_VERSION"; then
    return
  fi

  local arch name url tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  name="sing-box-${SING_BOX_VERSION}-linux-${arch}"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${name}.tar.gz"
  tmp=$(mktemp -d)
  curl -fL --retry 3 --connect-timeout 20 --max-time 180 -o "$tmp/sing-box.tar.gz" "$url"
  tar xzf "$tmp/sing-box.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/$name/sing-box" "$SBOX_DIR/sing-box"
  rm -rf "$tmp"
}

install_cloudflared() {
  mkdir -p "$SBOX_DIR"
  if [ -x "$SBOX_DIR/cloudflared" ]; then
    return
  fi

  local arch url
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported arch for cloudflared: $(uname -m)" >&2; return 1 ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  curl -fL --retry 3 --connect-timeout 20 --max-time 180 -o "$SBOX_DIR/cloudflared" "$url"
  chmod 0755 "$SBOX_DIR/cloudflared"
}

valid_reality_key_file() {
  local file=$1
  [ -s "$file" ] && grep -Eq '^[A-Za-z0-9_-]{43}$' "$file"
}

generate_reality_keypair() {
  "$SBOX_DIR/sing-box" generate reality-keypair > "$SBOX_DIR/reality-keypair.txt"
  awk -F': ' '/PrivateKey:/ {print $2}' "$SBOX_DIR/reality-keypair.txt" | tr -d '\r' > "$SBOX_DIR/reality_private.key"
  awk -F': ' '/PublicKey:/ {print $2}' "$SBOX_DIR/reality-keypair.txt" | tr -d '\r' > "$SBOX_DIR/reality_public.key"

  if ! valid_reality_key_file "$SBOX_DIR/reality_private.key" || ! valid_reality_key_file "$SBOX_DIR/reality_public.key"; then
    echo "Failed to generate valid Reality keys." >&2
    cat "$SBOX_DIR/reality-keypair.txt" >&2
    exit 1
  fi
}

generate_identity() {
  if [ -z "$UUID" ]; then
    if [ -f "$SBOX_DIR/uuid" ]; then
      UUID=$(cat "$SBOX_DIR/uuid")
    else
      UUID=$("$SBOX_DIR/sing-box" generate uuid)
    fi
  fi
  printf '%s\n' "$UUID" > "$SBOX_DIR/uuid"

  # Keep Reality keys separate from TLS private keys. sing-box-yg also uses
  # private.key for certificate material, which is not a valid Reality key.
  if ! valid_reality_key_file "$SBOX_DIR/reality_private.key" || ! valid_reality_key_file "$SBOX_DIR/reality_public.key"; then
    rm -f "$SBOX_DIR/reality_private.key" "$SBOX_DIR/reality_public.key"
    generate_reality_keypair
  fi

  if [ ! -f "$SBOX_DIR/tls.key" ] || [ ! -f "$SBOX_DIR/tls.crt" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$SBOX_DIR/tls.key" \
      -out "$SBOX_DIR/tls.crt" \
      -subj "/CN=www.bing.com" \
      -days 3650 >/dev/null 2>&1
  fi
}

write_config() {
  local private_key proxy_host proxy_port
  private_key=$(cat "$SBOX_DIR/reality_private.key")
  proxy_host=$PROXY_HOST
  proxy_port=$PROXY_PORT

  jq -n \
    --arg uuid "$UUID" \
    --arg private_key "$private_key" \
    --arg proxy_host "$proxy_host" \
    --argjson proxy_port "$proxy_port" \
    --arg cert "$SBOX_DIR/tls.crt" \
    --arg key "$SBOX_DIR/tls.key" \
    '{
      log: { level: "info", timestamp: true },
      inbounds: [
        {
          type: "vmess",
          tag: "vmess-ws",
          listen: "::",
          listen_port: 50001,
          users: [{ uuid: $uuid, alterId: 0 }],
          transport: { type: "ws", path: ("/" + $uuid + "-vm") }
        },
        {
          type: "vless",
          tag: "vless-reality",
          listen: "::",
          listen_port: 50003,
          users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
          tls: {
            enabled: true,
            server_name: "apple.com",
            reality: {
              enabled: true,
              handshake: { server: "apple.com", server_port: 443 },
              private_key: $private_key,
              short_id: ["95b6c721"]
            }
          }
        },
        {
          type: "shadowsocks",
          tag: "shadowsocks",
          listen: "::",
          listen_port: 50004,
          method: "chacha20-ietf-poly1305",
          password: $uuid
        },
        {
          type: "trojan",
          tag: "trojan",
          listen: "::",
          listen_port: 50005,
          users: [{ password: $uuid }],
          tls: {
            enabled: true,
            server_name: "www.bing.com",
            certificate_path: $cert,
            key_path: $key
          }
        }
      ],
      outbounds: [
        { type: "http", tag: "sg-http-proxy", server: $proxy_host, server_port: $proxy_port },
        { type: "direct", tag: "direct" }
      ],
      route: { final: "sg-http-proxy" }
    }' > "$SBOX_DIR/sb.json"

  "$SBOX_DIR/sing-box" check -c "$SBOX_DIR/sb.json"
}

write_subscription() {
  local public_key path vm_json vmess vless ss_user ss trojan
  public_key=$(cat "$SBOX_DIR/reality_public.key")
  path="/${UUID}-vm"

  mkdir -p "$SBOX_DIR/sub"
  vm_json=$(jq -nc \
    --arg add "$PUBLIC_HOST" \
    --arg id "$UUID" \
    --arg path "$path" \
    '{v:"2",ps:"sg-vmess-ws-50001",add:$add,port:"50001",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:"",path:$path,tls:""}')
  vmess="vmess://$(printf '%s' "$vm_json" | base64 -w0)"
  vless="vless://${UUID}@${PUBLIC_HOST}:50003?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${public_key}&sid=95b6c721&type=tcp&headerType=none#sg-vless-reality-50003"
  ss_user=$(printf 'chacha20-ietf-poly1305:%s' "$UUID" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  ss="ss://${ss_user}@${PUBLIC_HOST}:50004#sg-shadowsocks-50004"
  trojan="trojan://${UUID}@${PUBLIC_HOST}:50005?security=tls&sni=www.bing.com&allowInsecure=1&type=tcp#sg-trojan-50005"

  printf '%s\n%s\n%s\n%s\n' "$vmess" "$vless" "$ss" "$trojan" > "$SBOX_DIR/sub/nodes.txt"
  base64 -w0 "$SBOX_DIR/sub/nodes.txt" > "$SBOX_DIR/sub/v2ray.txt"
  printf '\n' >> "$SBOX_DIR/sub/v2ray.txt"
}

start_argo_tunnel() {
  case "$ARGO_ENABLE" in
    1|y|Y|yes|YES|true|TRUE) ;;
    *) return 0 ;;
  esac

  install_cloudflared || return 0
  rm -f "$SBOX_DIR/argo.log" "$SBOX_DIR/argo_domain"

  setsid "$SBOX_DIR/cloudflared" tunnel \
    --url http://127.0.0.1:50001 \
    --edge-ip-version auto \
    --protocol http2 \
    --no-autoupdate \
    </dev/null >"$SBOX_DIR/argo.log" 2>&1 &
  echo $! > "$SBOX_DIR/cloudflared.pid"

  local i domain
  for i in $(seq 1 45); do
    domain=$(grep -Eao 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$SBOX_DIR/argo.log" 2>/dev/null | head -n 1 || true)
    if [ -n "$domain" ]; then
      ARGO_DOMAIN=${domain#https://}
      printf '%s\n' "$ARGO_DOMAIN" > "$SBOX_DIR/argo_domain"
      return 0
    fi
    sleep 1
  done

  echo "Warning: cloudflared temporary tunnel did not return a trycloudflare.com domain." >&2
  tail -n 30 "$SBOX_DIR/argo.log" >&2 || true
  return 0
}

append_argo_subscription() {
  case "$ARGO_ENABLE" in
    1|y|Y|yes|YES|true|TRUE) ;;
    *) return 0 ;;
  esac

  local argo_host path vm_json vmess
  argo_host=${ARGO_DOMAIN:-}
  if [ -z "$argo_host" ] && [ -s "$SBOX_DIR/argo_domain" ]; then
    argo_host=$(cat "$SBOX_DIR/argo_domain")
  fi
  [ -n "$argo_host" ] || return 0

  path="/${UUID}-vm"
  vm_json=$(jq -nc \
    --arg add "$argo_host" \
    --arg id "$UUID" \
    --arg path "$path" \
    '{v:"2",ps:"sg-vmess-ws-argo-443",add:$add,port:"443",id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$add,path:$path,tls:"tls",sni:$add,fp:"chrome"}')
  vmess="vmess://$(printf '%s' "$vm_json" | base64 -w0)"

  printf '%s\n' "$vmess" >> "$SBOX_DIR/sub/nodes.txt"
  base64 -w0 "$SBOX_DIR/sub/nodes.txt" > "$SBOX_DIR/sub/v2ray.txt"
  printf '\n' >> "$SBOX_DIR/sub/v2ray.txt"
}

start_services() {
  free_vpn_ports

  sleep 2
  setsid "$SBOX_DIR/sing-box" run -c "$SBOX_DIR/sb.json" </dev/null >/var/log/sing-box.log 2>&1 &
  echo $! > "$SBOX_DIR/sing-box.pid"
  setsid python3 -m http.server 50002 --bind 0.0.0.0 --directory "$SBOX_DIR/sub" </dev/null >/var/log/v2ray-sub.log 2>&1 &
  echo $! > "$SBOX_DIR/v2ray-sub.pid"
  sleep 2
}

verify() {
  echo
  echo "== processes =="
  ps -ef | grep -E '[s]ing-box run|[h]ttp.server 50002' || true
  echo
  echo "== listening =="
  ss -ltnp | grep -E ':(50001|50002|50003|50004|50005) ' || true
  echo
  echo "== subscription =="
  echo "http://${PUBLIC_HOST}:50002/v2ray.txt"
  if [ -s "$SBOX_DIR/argo_domain" ]; then
    echo "Argo temporary domain: https://$(cat "$SBOX_DIR/argo_domain")"
  fi
  echo
  echo "== nodes =="
  cat "$SBOX_DIR/sub/nodes.txt"
  echo
  echo "Run from your Mac to verify SG egress after import, or use the subscription URL directly in V2Ray/V2Box."
}

main() {
  parse_args "$@"
  need_root
  detect_public_host
  persist_public_host
  install_deps
  proxy_host_port
  detect_supervisor_conf
  stop_openclaw_and_free_ports
  install_sing_box
  generate_identity
  write_config
  write_subscription
  start_services
  start_argo_tunnel
  append_argo_subscription
  verify
}

main "$@"
