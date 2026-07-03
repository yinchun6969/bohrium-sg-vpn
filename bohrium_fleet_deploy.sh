#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy the Bohrium SG VPN script to many restarted Bohrium nodes.
# Input can be a hosts file, pasted SSH commands, or stdin.

SETUP_URL=${SETUP_URL:-https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh}
SSH_USER=${SSH_USER:-root}
SSH_PORT=${SSH_PORT:-22}
OUT_FILE=${OUT_FILE:-bohrium_subscriptions.txt}
HOSTS_FILE=${1:-}

usage() {
  cat <<'EOF'
Usage:
  ./bohrium_fleet_deploy.sh hosts.txt
  pbpaste | ./bohrium_fleet_deploy.sh

Optional env:
  BOHRIUM_SSH_PASSWORD='password from BohrClaw'
  SSH_USER=root
  SSH_PORT=22
  SETUP_URL=https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh
  OUT_FILE=bohrium_subscriptions.txt

The input may contain raw hosts or full SSH commands, for example:
  ssh root@qqvv1491881.bohrium.tech
  qqvv1491881.bohrium.tech
EOF
}

extract_hosts() {
  grep -Eao '[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.bohrium\.tech' | awk '!seen[$0]++'
}

read_hosts() {
  if [ -n "${HOSTS_FILE:-}" ]; then
    extract_hosts < "$HOSTS_FILE"
  else
    extract_hosts
  fi
}

ssh_base_args() {
  printf '%s\n' \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3
}

deploy_with_sshpass() {
  local host=$1 script=$2
  SSHPASS=$BOHRIUM_SSH_PASSWORD sshpass -e ssh $(ssh_base_args) "${SSH_USER}@${host}" "bash -s -- '${host}'" < "$script"
}

deploy_with_expect() {
  local host=$1 script=$2
  BOHRIUM_DEPLOY_HOST=$host \
  BOHRIUM_DEPLOY_SCRIPT=$script \
  BOHRIUM_DEPLOY_SSH_USER=$SSH_USER \
  BOHRIUM_DEPLOY_SSH_PORT=$SSH_PORT \
  expect <<'EOF'
set timeout -1
set host $env(BOHRIUM_DEPLOY_HOST)
set script $env(BOHRIUM_DEPLOY_SCRIPT)
set user $env(BOHRIUM_DEPLOY_SSH_USER)
set port $env(BOHRIUM_DEPLOY_SSH_PORT)
set password $env(BOHRIUM_SSH_PASSWORD)
spawn sh -c "ssh -p $port -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=20 -o ServerAliveCountMax=3 $user@$host \"bash -s -- '$host'\" < '$script'"
expect {
  -re "(?i)are you sure you want to continue connecting" {
    send "yes\r"
    exp_continue
  }
  -re "(?i)password:" {
    send "$password\r"
    exp_continue
  }
  eof
}
catch wait result
exit [lindex $result 3]
EOF
}

deploy_interactive() {
  local host=$1 script=$2
  ssh $(ssh_base_args) "${SSH_USER}@${host}" "bash -s -- '${host}'" < "$script"
}

deploy_one() {
  local host=$1 script=$2
  echo
  echo "==> Deploying ${host}"

  if [ -n "${BOHRIUM_SSH_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    deploy_with_sshpass "$host" "$script"
  elif [ -n "${BOHRIUM_SSH_PASSWORD:-}" ] && command -v expect >/dev/null 2>&1; then
    deploy_with_expect "$host" "$script"
  else
    deploy_interactive "$host" "$script"
  fi

  printf 'http://%s:50002/v2ray.txt\n' "$host" >> "$OUT_FILE"
}

main() {
  local script host count=0

  if [ "${HOSTS_FILE:-}" = "-h" ] || [ "${HOSTS_FILE:-}" = "--help" ]; then
    usage
    exit 0
  fi

  if [ -z "${HOSTS_FILE:-}" ] && [ -t 0 ]; then
    usage >&2
    echo >&2
    echo "No hosts file or stdin input provided." >&2
    exit 1
  fi

  script=$(mktemp)
  trap 'rm -f "$script"' EXIT

  curl -fsSL --retry 5 --connect-timeout 20 -o "$script" "$SETUP_URL"
  bash -n "$script"

  : > "$OUT_FILE"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    deploy_one "$host" "$script"
    count=$((count + 1))
  done < <(read_hosts)

  if [ "$count" -eq 0 ]; then
    echo "No *.bohrium.tech hosts found in input." >&2
    exit 1
  fi

  echo
  echo "==> Done. Subscription URLs:"
  cat "$OUT_FILE"
}

main "$@"
