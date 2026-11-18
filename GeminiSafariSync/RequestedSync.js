(function () {
    const url = new URL(window.location.href);
    const marker = url.hash.match(/^#aiusage-sync=([a-f0-9-]{36})$/i);
    if (!marker || url.origin !== "https://gemini.google.com" || !/^\/(?:u\/\d+\/)?usage\/?$/.test(url.pathname)) return;
    const requestID = marker[1];

    async function sync() {
        try {
            const response = await browser.runtime.sendMessage({ requestID, type: "check" });
            if (!response?.ok) return;

            const deadline = performance.now() + 15000;
            let usage = readGeminiUsage();
            while (!usage && performance.now() < deadline) {
                await new Promise(resolve => setTimeout(resolve, 400));
                usage = readGeminiUsage();
            }

            if (!usage) {
                notify("Gemini quota is unavailable. Check that you’re signed in and both limits are visible.");
                return;
            }

            const result = await browser.runtime.sendMessage({ requestID, type: "save", usage });
            if (location.hash === marker[0]) {
                const clean = new URL(location.href);
                clean.searchParams.delete("aiusage_sync");
                clean.hash = "";
                history.replaceState(history.state, "", clean);
            }
            notify(result?.ok ? "Gemini quota saved to AI Usage." : "Couldn’t save Gemini quota. Try again from AI Usage.");
        } catch {
            notify("Couldn’t sync Gemini quota. Try again from AI Usage.");
        }
    }

    function notify(message) {
        const status = document.createElement("div");
        status.setAttribute("role", "status");
        status.textContent = message;
        status.style.cssText = "position:fixed;z-index:2147483647;bottom:64px;left:50%;transform:translateX(-50%);width:max-content;max-width:85vw;box-sizing:border-box;background:#222;color:#fff;padding:10px 14px;border-radius:12px;text-align:center;font:14px system-ui,sans-serif";
        document.body.append(status);
        setTimeout(() => status.remove(), 4500);
    }

    sync();
})();
