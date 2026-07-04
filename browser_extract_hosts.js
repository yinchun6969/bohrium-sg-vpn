(() => {
  const setupUrl = "https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh";
  const fleetUrl = "https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_fleet_deploy.sh";
  const fleetCdnUrl = "https://cdn.jsdelivr.net/gh/yinchun6969/bohrium-sg-vpn@main/bohrium_fleet_deploy.sh";
  const localFleetPath = "/Users/nfts2968/Documents/openai_cudex/bohrium-sg-vpn/bohrium_fleet_deploy.sh";
  const hostRe = /[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.bohrium\.tech/g;
  const texts = [];

  const addText = (value) => {
    if (value) texts.push(String(value));
  };

  addText(document.body && document.body.innerText);
  addText(document.documentElement && document.documentElement.outerHTML);

  document.querySelectorAll("input, textarea, [title], [aria-label], [data-clipboard-text]").forEach((el) => {
    addText(el.value);
    addText(el.textContent);
    addText(el.getAttribute("title"));
    addText(el.getAttribute("aria-label"));
    addText(el.getAttribute("data-clipboard-text"));
  });

  const urls = ["/api/instances", "/api/node-info", "/api/nodes"];
  const fetchTexts = urls.map(async (url) => {
    try {
      const response = await fetch(url, { credentials: "include" });
      if (response.ok) addText(await response.text());
    } catch (_) {
      // Ignore missing read-only endpoints; DOM extraction may still work.
    }
  });

  const showCopyBox = (output, hosts) => {
    const old = document.getElementById("bohrium-host-copy-box");
    if (old) old.remove();

    const wrap = document.createElement("div");
    wrap.id = "bohrium-host-copy-box";
    wrap.style.cssText = [
      "position:fixed",
      "z-index:2147483647",
      "inset:24px",
      "background:#0f172a",
      "color:#e5e7eb",
      "border:1px solid #334155",
      "border-radius:8px",
      "box-shadow:0 24px 80px rgba(0,0,0,.45)",
      "padding:16px",
      "font:14px system-ui,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif",
    ].join(";");

    const title = document.createElement("div");
    title.textContent = `Found ${hosts.length} Bohrium host(s). Paste this one command into Mac Terminal.`;
    title.style.cssText = "font-weight:700;margin-bottom:10px";

    const textarea = document.createElement("textarea");
    textarea.value = output;
    textarea.style.cssText = [
      "width:100%",
      "height:calc(100% - 56px)",
      "box-sizing:border-box",
      "background:#020617",
      "color:#e5e7eb",
      "border:1px solid #475569",
      "border-radius:6px",
      "padding:12px",
      "font:13px ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace",
      "white-space:pre",
    ].join(";");

    const close = document.createElement("button");
    close.textContent = "Close";
    close.style.cssText = "float:right;margin-top:10px;padding:8px 14px;border:0;border-radius:6px;background:#4f46e5;color:white;font-weight:700";
    close.onclick = () => wrap.remove();

    wrap.append(title, textarea, close);
    document.body.appendChild(wrap);
    textarea.focus();
    textarea.select();
  };

  const copyOutput = async (output, hosts) => {
    window.__bohriumHosts = hosts;
    window.__bohriumHostsOutput = output;

    try {
      if (typeof copy === "function") {
        copy(output);
        alert(`Copied one deploy command for ${hosts.length} Bohrium host(s). Paste it into Mac Terminal and replace the password placeholder.`);
        return;
      }
    } catch (_) {
      // DevTools copy() may be unavailable outside the Console.
    }

    try {
      await navigator.clipboard.writeText(output);
      alert(`Copied one deploy command for ${hosts.length} Bohrium host(s). Paste it into Mac Terminal and replace the password placeholder.`);
      return;
    } catch (_) {
      console.log(output);
      showCopyBox(output, hosts);
      alert(`Found ${hosts.length} Bohrium host(s). Clipboard failed, so a copy box was opened on the page.`);
    }
  };

  Promise.all(fetchTexts).then(async () => {
    const hosts = [...new Set(texts.join("\n").match(hostRe) || [])].sort();
    if (!hosts.length) {
      alert("No *.bohrium.tech host found. Open the BohrClaw connection dialog, then run this again.");
      return;
    }

    const hostList = hosts.join(" ");
    const output = [
      `BOHRIUM_HOSTS='${hostList}'`,
      `BOHRIUM_SSH_PASSWORD='把密码填这里'`,
      `F='${localFleetPath}'`,
      `if [ -x "$F" ]; then "$F"; else bash <(curl -fsSL --retry 5 --connect-timeout 20 ${fleetCdnUrl} || curl -fsSL --retry 5 --connect-timeout 20 ${fleetUrl}); fi`,
    ].join(" ");

    window.__bohriumSubscriptions = hosts.map((host) => `http://${host}:50002/v2ray.txt`);
    window.__bohriumSingleNodeCommands = hosts.map(
      (host) => `bash <(curl -fsSL --retry 5 --connect-timeout 20 ${setupUrl}) 'ssh root@${host}'`
    );

    await copyOutput(output, hosts);
  });
})();
