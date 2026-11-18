browser.runtime.onMessage.addListener((message, sender) => {
    if (!sender.url || sender.frameId !== 0 || !["check", "save"].includes(message?.type)) return;

    const url = new URL(sender.url);
    if (url.origin !== "https://gemini.google.com" || !/^\/(?:u\/\d+\/)?usage\/?$/.test(url.pathname)) return;

    // Safari may omit the URL fragment from the sender. The native handler validates the request.
    return browser.runtime.sendNativeMessage("aiusage.gamojo.com", message);
});
