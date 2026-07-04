# Bohrium SG VPN Setup

One-command rebuild script for the Bohrium free VPS/container after it shuts down.

It deploys the TCP protocols that were verified to work on Bohrium's public port mapping:

- VMess-WS on `50001`
- V2Ray subscription service on `50002`
- VLESS Reality on `50003`
- Shadowsocks on `50004`
- Trojan on `50005`

HY2/TUIC are intentionally skipped because this Bohrium environment did not forward UDP.

## Phone Usage

SSH into the new VPS, then run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh)
```

The VPS usually cannot see the SSH host displayed in the BohrClaw web UI. If
auto-detection fails, the script asks you to paste the SSH command from the
connection dialog.

Most reliable phone usage: copy the SSH command from BohrClaw and pass it as the
first argument:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) 'ssh root@qqvv1491881.bohrium.tech'
```

Host-only style also works:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) pjqk1492005.bohrium.tech
```

Equivalent env style:

```bash
PUBLIC_HOST=pjqk1492005.bohrium.tech bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh)
```

## Six-Node Workflow

The VPS cannot discover the web UI SSH host by itself after a restart, because
that host is assigned and displayed by BohrClaw outside the machine. You do not
need to keep six browser windows open. Open one BohrClaw dashboard after you
manually start the nodes, extract the visible card domains once, then deploy
from your Mac.

1. In BohrClaw, manually start the nodes you want to use.
2. Keep the main instance list page open. If the card shows hosts like
   `sufx1491910.bohrium.tech`, that page is enough.
3. Open Chrome DevTools Console on the BohrClaw page and run:

```js
fetch("https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/browser_extract_hosts.js").then(r => r.text()).then(eval)
```

   If Chrome blocks pasting into Console, type `allow pasting` first.
4. The script copies one Mac Terminal command to your clipboard. It looks like:

```bash
BOHRIUM_HOSTS='sufx1491910.bohrium.tech ...' BOHRIUM_SSH_PASSWORD='把密码填这里' bash <(curl -fsSL --retry 5 --connect-timeout 20 https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_fleet_deploy.sh)
```

5. Paste it into Mac Terminal, replace `把密码填这里` with the BohrClaw SSH
   password, then press Enter.

If you do not want to use password automation, omit `BOHRIUM_SSH_PASSWORD` and
enter the password when SSH asks.

The fleet deploy script writes all subscription URLs to:

```text
bohrium_subscriptions.txt
```

After the script finishes, import this subscription into V2Ray/V2Box:

```text
http://PUBLIC_HOST:50002/v2ray.txt
```

Example:

```text
http://pjqk1492005.bohrium.tech:50002/v2ray.txt
```

## Optional Variables

```bash
PUBLIC_HOST=your-new-host.example.com \
UUID=your-fixed-uuid-if-needed \
SG_HTTP_PROXY=http://gemini.op.xdptech.com:8118 \
bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh)
```

Defaults:

- `SG_HTTP_PROXY` uses the VPS `HTTPS_PROXY` or `HTTP_PROXY`, falling back to `http://gemini.op.xdptech.com:8118`.
- `UUID` is generated automatically and persisted in `/etc/s-box/uuid`.
- `PUBLIC_HOST` is saved to `/etc/s-box/public_host` after a successful run.

## What It Does

1. Detects or asks for `PUBLIC_HOST` before installing packages.
2. Saves `PUBLIC_HOST` to `/etc/s-box/public_host`.
3. Installs dependencies.
4. Stops old `sing-box`/subscription processes and frees `50001-50005`.
5. Stops and disables OpenClaw so `50001` is free.
6. Installs `sing-box 1.10.7`.
7. Generates Reality keys, UUID, and a self-signed TLS cert.
8. Writes `/etc/s-box/sb.json`.
9. Starts `sing-box` and the subscription HTTP service as detached background processes.
10. Prints the node links and subscription URL.

## Verify

On your Mac or another client:

```bash
curl http://PUBLIC_HOST:50002/v2ray.txt
```

Import the subscription and test the four nodes. During the original setup, all four TCP nodes were verified as Singapore egress.
