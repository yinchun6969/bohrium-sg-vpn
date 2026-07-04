# Bohrium SG VPN Setup

One-command rebuild script for the Bohrium free VPS/container after it shuts down.

It deploys the TCP protocols that were verified to work on Bohrium's public port mapping:

- VMess-WS on `50001`
- V2Ray subscription service on `50002`
- VLESS Reality on `50003`
- Shadowsocks on `50004`
- Trojan on `50005`

HY2/TUIC are intentionally skipped because this Bohrium environment did not forward UDP.

## Option A: Phone/Web Shell Single Node

Use this when you are on your phone or only need one node.

1. Start the VPS in BohrClaw.
2. Copy the domain shown on the instance card or connection dialog, for example
   `qqvv1491881.bohrium.tech`.
3. Open the VPS Web Shell.
4. Run this inside the VPS:

```bash
bash <(curl -fsSL --retry 5 --connect-timeout 20 https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) qqvv1491881.bohrium.tech
```

Pasting the full SSH command also works:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh) 'ssh root@qqvv1491881.bohrium.tech'
```

After it finishes, import:

```text
http://qqvv1491881.bohrium.tech:50002/v2ray.txt
```

## Option B: Mac Batch Deploy

Use this when you started several nodes and want to deploy all of them at once.
You do not need to keep six browser windows open. Open one BohrClaw dashboard
after you manually start the nodes, extract the visible card domains once, then
deploy from your Mac.

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

The fleet deploy script writes all subscription URLs to:

```text
bohrium_subscriptions.txt
```

## Option C: Argo Tunnel Variant

Use this experimental variant when the direct Bohrium public ports are unstable
or you want one VMess-WS node exposed through a temporary Cloudflare Tunnel.
This keeps the direct VMess/VLESS/SS/Trojan nodes and adds one extra
`sg-vmess-ws-argo-443` node to the same subscription.

This is for connectivity compatibility, not for bypassing platform rules or
avoiding provider detection. The provider can still see processes and outbound
traffic from the VPS.

Run inside the VPS Web Shell:

```bash
bash <(curl -fsSL --retry 5 --connect-timeout 20 https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_argo_setup.sh) elcy1491891.bohrium.tech
```

Then import the normal subscription:

```text
http://elcy1491891.bohrium.tech:50002/v2ray.txt
```

The script also prints the temporary `trycloudflare.com` domain if Cloudflare
Tunnel starts successfully.

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
- `ARGO_ENABLE=0` disables Cloudflare Tunnel in the Argo variant.

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
