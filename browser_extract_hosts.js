(() => {
  const setupUrl = "https://raw.githubusercontent.com/yinchun6969/bohrium-sg-vpn/main/bohrium_sg_vpn_setup.sh";
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

  Promise.all(fetchTexts).then(async () => {
    const hosts = [...new Set(texts.join("\n").match(hostRe) || [])].sort();
    if (!hosts.length) {
      alert("No *.bohrium.tech host found. Open the BohrClaw connection dialog, then run this again.");
      return;
    }

    const sshCommands = hosts.map((host) => `ssh root@${host}`).join("\n");
    const perNodeCommands = hosts
      .map((host) => `bash <(curl -fsSL --retry 5 --connect-timeout 20 ${setupUrl}) 'ssh root@${host}'`)
      .join("\n");
    const subscriptionUrls = hosts.map((host) => `http://${host}:50002/v2ray.txt`).join("\n");
    const output = [
      "# Bohrium SSH hosts",
      sshCommands,
      "",
      "# Run inside each node web shell if not using fleet SSH deploy",
      perNodeCommands,
      "",
      "# Subscription URLs after deployment",
      subscriptionUrls,
    ].join("\n");

    try {
      await navigator.clipboard.writeText(output);
      alert(`Copied ${hosts.length} Bohrium host(s), deploy commands, and subscription URLs.`);
    } catch (_) {
      console.log(output);
      alert(`Found ${hosts.length} host(s). Clipboard failed, so the output was printed to Console.`);
    }
  });
})();
