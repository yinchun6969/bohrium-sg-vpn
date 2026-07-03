#!/usr/bin/env bash
set -Eeuo pipefail

# Rebuild the working Bohrium SG TCP VPN setup from a fresh Ubuntu/Debian-ish box.
# Usage on the VPS:
#   PUBLIC_HOST=pjqk1492005.bohrium.tech bash scripts/bohrium_sg_vpn_setup.sh
#
# Outputs:
#   VMess-WS      : $PUBLIC_HOST:50001
#   V2Ray sub URL : http://$PUBLIC_HOST:50002/v2ray.txt
#   VLESS Reality : $PUBLIC_HOST:50003
#   Shadowsocks   : $PUBLIC_HOST:50004
#   Trojan        : $PUBLIC_HOST:50005
#
# ponytail: TCP only because this Bohrium mapping does not forward UDP; HY2/TUIC need UDP.

SBOX_DIR=${SBOX_DIR:-/etc/s-box}
SING_BOX_VERSION=${SING_BOX_VERSION:-1.10.7}
UUID=${UUID:-}
PUBLIC_HOST=${PUBLIC_HOST:-}
SG_HTTP_PROXY=${SG_HTTP_PROXY:-${HTTPS_PROXY:-${HTTP_PROXY:-http://gemini.op.xdptech.com:8118}}}
SUPERVISOR_CONF=${SUPERVISOR_CONF:-}

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

detect_public_host() {
  if [ -n "$PUBLIC_HOST" ]; then
    return
  fi

  PUBLIC_HOST=$(hostname -f 2>/dev/null || true)
  case "$PUBLIC_HOST" in
    ""|localhost|*.local|bohrium-*) PUBLIC_HOST="" ;;
  esac

  if [ -z "$PUBLIC_HOST" ]; then
    PUBLIC_HOST=$(curl --noproxy '*' -fsS4m 8 https://api.ipify.org || true)
  fi

  if [ -z "$PUBLIC_HOST" ]; then
    echo "Set PUBLIC_HOST, e.g. PUBLIC_HOST=pjqk1492005.bohrium.tech bash $0" >&2
    exit 1
  fi
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
  svctl stop sing-box >/dev/null 2>&1 || true
  svctl stop v2ray-sub >/dev/null 2>&1 || true
  fuser -k 50001/tcp 50002/tcp 50003/tcp 50004/tcp 50005/tcp >/dev/null 2>&1 || true
}

stop_openclaw_and_free_ports() {
  svctl stop openclaw-gateway >/dev/null 2>&1 || true
  if [ -f /etc/supervisor/conf.d/openclaw-gateway.conf ]; then
    mv /etc/supervisor/conf.d/openclaw-gateway.conf /etc/supervisor/conf.d/openclaw-gateway.conf.disabled
  fi
  pidof openclaw 2>/dev/null | xargs -r kill || true
  fuser -k 50001/tcp 2>/dev/null || true
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

generate_identity() {
  if [ -z "$UUID" ]; then
    if [ -f "$SBOX_DIR/uuid" ]; then
      UUID=$(cat "$SBOX_DIR/uuid")
    else
      UUID=$("$SBOX_DIR/sing-box" generate uuid)
    fi
  fi
  printf '%s\n' "$UUID" > "$SBOX_DIR/uuid"

  if [ ! -f "$SBOX_DIR/private.key" ] || [ ! -f "$SBOX_DIR/public.key" ]; then
    "$SBOX_DIR/sing-box" generate reality-keypair > "$SBOX_DIR/reality-keypair.txt"
    awk '/PrivateKey:/ {print $2}' "$SBOX_DIR/reality-keypair.txt" > "$SBOX_DIR/private.key"
    awk '/PublicKey:/ {print $2}' "$SBOX_DIR/reality-keypair.txt" > "$SBOX_DIR/public.key"
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
  private_key=$(cat "$SBOX_DIR/private.key")
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
          transport: { type: "ws", path: ($uuid + "-vm") }
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
  public_key=$(cat "$SBOX_DIR/public.key")
  path="${UUID}-vm"

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

write_supervisor() {
  mkdir -p /etc/supervisor/conf.d
  free_vpn_ports

  cat > /etc/supervisor/conf.d/sing-box.conf <<EOF
[program:sing-box]
command=$SBOX_DIR/sing-box run -c $SBOX_DIR/sb.json
directory=$SBOX_DIR
autostart=true
autorestart=true
startsecs=2
startretries=3
user=root
redirect_stderr=true
stdout_logfile=/var/log/sing-box-supervisor.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=2
stopasgroup=true
killasgroup=true
EOF

  cat > /etc/supervisor/conf.d/v2ray-sub.conf <<EOF
[program:v2ray-sub]
command=python3 -m http.server 50002 --bind 0.0.0.0 --directory $SBOX_DIR/sub
directory=$SBOX_DIR/sub
autostart=true
autorestart=true
startsecs=1
startretries=3
user=root
redirect_stderr=true
stdout_logfile=/var/log/v2ray-sub-supervisor.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=1
stopasgroup=true
killasgroup=true
EOF

  service supervisor start >/dev/null 2>&1 || /etc/init.d/supervisor start >/dev/null 2>&1 || true
  if ! svctl status >/dev/null 2>&1; then
    supervisord -c "$SUPERVISOR_CONF" >/dev/null 2>&1 || true
    sleep 1
  fi
  svctl reread
  svctl update
  sleep 2
  svctl status sing-box | grep -q RUNNING || svctl start sing-box
  svctl status v2ray-sub | grep -q RUNNING || svctl start v2ray-sub
}

verify() {
  echo
  echo "== supervisor =="
  svctl status || true
  echo
  echo "== listening =="
  ss -ltnp | grep -E ':(50001|50002|50003|50004|50005) ' || true
  echo
  echo "== subscription =="
  echo "http://${PUBLIC_HOST}:50002/v2ray.txt"
  echo
  echo "== nodes =="
  cat "$SBOX_DIR/sub/nodes.txt"
  echo
  echo "Run from your Mac to verify SG egress after import, or use the subscription URL directly in V2Ray/V2Box."
}

main() {
  need_root
  install_deps
  detect_public_host
  proxy_host_port
  detect_supervisor_conf
  stop_openclaw_and_free_ports
  install_sing_box
  generate_identity
  write_config
  write_subscription
  write_supervisor
  verify
}

main "$@"
