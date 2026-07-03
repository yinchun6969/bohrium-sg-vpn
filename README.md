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
PUBLIC_HOST=pjqk1492005.bohrium.tech bash <(curl -fsSL https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh)
```

Replace `pjqk1492005.bohrium.tech` with the new SSH/public host if Bohrium changes it.

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

## What It Does

1. Installs dependencies.
2. Stops and disables OpenClaw so `50001` is free.
3. Installs `sing-box 1.10.7`.
4. Generates Reality keys, UUID, and a self-signed TLS cert.
5. Writes `/etc/s-box/sb.json`.
6. Starts `sing-box` and the subscription HTTP service as detached background processes.
7. Prints the node links and subscription URL.

## Verify

On your Mac or another client:

```bash
curl http://PUBLIC_HOST:50002/v2ray.txt
```

Import the subscription and test the four nodes. During the original setup, all four TCP nodes were verified as Singapore egress.
