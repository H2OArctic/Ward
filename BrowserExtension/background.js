// Единственная часть расширения, которая говорит с Ward (через помощника native messaging).
// Адрес и происхождение страницы берутся у Chrome (sender), а не из сообщения: страница их подделать не может.
// Состояние — только живое соединение с помощником: открытый порт и держит service worker (правило MV3),
// а сохранять что-либо в chrome.storage нельзя — через расширение идут пароли.

const HOST = "local.ward";
let port = null;
let nextID = 1;
const pending = new Map();
const MAX_PENDING = 32;
const REQUEST_TIMEOUT = 65_000;

function cancel(id, error = "cancelled") {
  const request = pending.get(id);
  if (!request) return;
  pending.delete(id);
  clearTimeout(request.timer);
  request.resolve({ ok: false, error });
  try {
    port?.postMessage({ type: "cancel", requestID: id, id: nextID++ });
  } catch {
    return;
  }
}

function connect() {
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  });
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError ? "hostMissing" : "disconnected";
    for (const waiter of pending.values()) {
      clearTimeout(waiter.timer);
      waiter.resolve({ ok: false, error: reason });
    }
    pending.clear();
    port = null;
  });
}

function ask(request, documentKey = null) {
  if (pending.size >= MAX_PENDING) return Promise.resolve({ ok: false, error: "busy" });
  if (!port) connect();
  const id = nextID++;
  return new Promise((resolve) => {
    const timer = setTimeout(() => cancel(id, "timeout"), REQUEST_TIMEOUT);
    pending.set(id, { resolve, timer, documentKey });
    try {
      port.postMessage({ ...request, id });
    } catch {
      pending.delete(id);
      clearTimeout(timer);
      resolve({ ok: false, error: "hostMissing" });
    }
  });
}

/// Адрес фрейма, где форма: форма в чужом iframe на знакомом сайте получает учётки своего сайта, а не страницы.
function frameURL(sender) {
  return sender.url || (sender.tab && sender.tab.url) || "";
}

/// Окно кнопки расширения присылает номер вкладки; её адрес узнаём у Chrome, а не из сообщения
/// (адрес доступен по host_permissions — отдельное разрешение tabs не нужно).
async function documentContext(tabId, documentId) {
  try {
    const context = await chrome.tabs.sendMessage(tabId, { type: "documentContext" }, { frameId: 0 });
    if (!context?.documentID || !context.url || (documentId && context.documentID !== documentId)) return null;
    return context;
  } catch {
    return null;
  }
}

async function handle(message, sender) {
  if (!sender.tab || sender.url === `chrome-extension://${chrome.runtime.id}/popup.html`) {
    switch (message.type) {
      case "popup.logins":
      {
        const context = await documentContext(message.tabId);
        if (!context) return { ok: false, error: "pageUnavailable" };
        const reply = await ask({ type: "logins", url: context.url });
        if (reply.ok) reply.result.documentID = context.documentID;
        return reply;
      }
      case "popup.fill": {
        if (typeof message.documentID !== "string") return { ok: false, error: "pageUnavailable" };
        const context = await documentContext(message.tabId, message.documentID);
        if (!context) return { ok: false, error: "pageUnavailable" };
        const reply = await ask({ type: "fill", entryID: message.entryID, url: context.url });
        if (reply.ok) {
          try {
            const applied = await chrome.tabs.sendMessage(message.tabId, { type: "applyFill", url: context.url, data: reply.result },
              { documentId: context.documentID });
            if (!applied?.ok) return { ok: false, error: "pageUnavailable" };
          } catch {
            return { ok: false, error: "pageUnavailable" };
          }
        }
        return { ok: reply.ok, error: reply.error };
      }
      default:
        return null;
    }
  }
  switch (message.type) {
    case "documentContext":
      if (sender.frameId !== 0) return null;
      return { url: sender.url, documentID: sender.documentId };
    case "logins":
      return ask({ type: "logins", url: frameURL(sender) });
    case "fill":
      return ask({ type: "fill", entryID: message.entryID, url: frameURL(sender) });
    case "passkey.create":
    case "passkey.get":
      // Происхождение — от Chrome (sender.origin), rpID и challenge — от сайта.
      if (!sender.origin || sender.frameId !== 0 || !sender.documentId) return { ok: false, error: "unsupportedFrame" };
      return ask({ ...message.payload, type: message.type, origin: sender.origin }, `${sender.documentId}|${message.requestID}`);
    case "passkey.cancel":
      if (!sender.documentId) return null;
      for (const [id, request] of pending) {
        if (request.documentKey === `${sender.documentId}|${message.requestID}`) cancel(id);
      }
      return { ok: true };
    default:
      return null;
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id) return false;
  (async () => {
    try {
      sendResponse(await handle(message, sender));
    } catch {
      sendResponse({ ok: false, error: "extensionError" });
    }
  })();
  return true;
});
