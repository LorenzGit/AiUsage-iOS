const statusText = document.getElementById("status");

async function syncQuota() {
    try {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        const url = tab?.url ? new URL(tab.url) : null;
        if (url?.origin !== "https://gemini.google.com" || !/^\/(?:u\/\d+\/)?usage\/?$/.test(url.pathname)) {
            statusText.textContent = "Open Gemini Usage Limits in Safari, then tap AI Usage Gemini Sync.";
            return;
        }

        const [page] = await browser.scripting.executeScript({
            target: { tabId: tab.id },
            func: readGeminiUsage
        });
        if (!page?.result) {
            statusText.textContent = "Wait until both quota percentages appear, then tap AI Usage Gemini Sync again.";
            return;
        }

        const response = await browser.runtime.sendNativeMessage("aiusage.gamojo.com", page.result);
        statusText.textContent = response?.ok
            ? "Gemini quota saved to AI Usage."
            : "Couldn’t save Gemini quota. Try again.";
    } catch {
        statusText.textContent = "Couldn’t read Gemini quota. Check that Safari allows the extension on this website.";
    }
}

syncQuota();
