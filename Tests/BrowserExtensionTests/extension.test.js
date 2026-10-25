import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const source = (name) => readFileSync(new URL(`../../BrowserExtension/${name}.js`, import.meta.url), "utf8");
const sender = { id: "ward", tab: { id: 1 }, frameId: 0, documentId: "original", url: "https://example.com/login", origin: "https://example.com" };
const tick = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

function background() {
  let listener, nativeListener, disconnected;
  const sent = [], deliveries = [], contexts = [], timers = new Map();
  let timerID = 0, currentDocument = "original";
  const chrome = {
    runtime: {
      id: "ward", onMessage: { addListener: (callback) => { listener = callback; } },
      connectNative: () => ({
        postMessage: (message) => sent.push(message),
        onMessage: { addListener: (callback) => { nativeListener = callback; } },
        onDisconnect: { addListener: (callback) => { disconnected = callback; } },
      }),
    },
    tabs: { sendMessage: async (id, message, options) => {
      if (message.type === "documentContext") {
        contexts.push(options);
        if (options.documentId && options.documentId !== currentDocument) return new Promise(() => {});
        return { url: sender.url, documentID: currentDocument };
      }
      if (options.documentId && options.documentId !== currentDocument) throw new Error("document gone");
      deliveries.push({ id, message, options });
      return { ok: true };
    } },
  };
  runInNewContext(source("background"), { chrome, setTimeout: (callback) => { timers.set(++timerID, callback); return timerID; }, clearTimeout: (id) => timers.delete(id) });
  return {
    sent, deliveries, contexts, timers,
    message: (message, from = sender) => new Promise((resolve) => { if (!listener(message, from, resolve)) resolve(null); }),
    reply: (message) => nativeListener(message), disconnect: () => disconnected(),
    navigate: () => { currentDocument = "replacement"; },
  };
}

describe("background document and request lifecycle", () => {
  test("navigation while fill waits never sends secrets to replacement document", async () => {
    const bg = background();
    const task = bg.message({ type: "popup.fill", tabId: 1, entryID: "entry", documentID: "original" }, { id: "ward" });
    await tick();
    expect(bg.sent[0].url).toBe(sender.url);
    bg.navigate();
    bg.reply({ id: bg.sent[0].id, ok: true, result: { password: "secret" } });
    expect((await task).ok).toBe(false);
    expect(bg.deliveries).toHaveLength(0);
  });

  test("successful popup fill targets document ID and keeps secrets out of popup response", async () => {
    const bg = background();
    const task = bg.message({ type: "popup.fill", tabId: 1, entryID: "entry", documentID: "original" }, { id: "ward" });
    await tick();
    bg.reply({ id: bg.sent[0].id, ok: true, result: { password: "secret" } });
    const reply = await task;
    expect(reply.ok).toBe(true);
    expect(reply.result).toBeUndefined();
    expect(bg.deliveries[0].options.documentId).toBe("original");
    expect(bg.deliveries[0].message.url).toBe(sender.url);
  });

  test("popup page opened in a tab still uses the trusted document handshake", async () => {
    const bg = background();
    const task = bg.message({ type: "popup.logins", tabId: 1 }, { ...sender, url: "chrome-extension://ward/popup.html" });
    await tick();
    bg.reply({ id: bg.sent[0].id, ok: true, result: { logins: [] } });
    expect((await task).result.documentID).toBe("original");
  });

  test("listing from old document cannot be used after navigation", async () => {
    const bg = background();
    bg.navigate();
    expect((await bg.message({ type: "popup.fill", tabId: 1, documentID: "original" }, { id: "ward" })).error).toBe("pageUnavailable");
    expect(bg.sent).toHaveLength(0);
    expect(bg.contexts).toEqual([{ frameId: 0 }]);
  });

  test("passkey origin is supplied by Chrome and iframe requests are rejected", async () => {
    const bg = background();
    expect((await bg.message({ type: "passkey.get" }, { ...sender, frameId: 1 })).error).toBe("unsupportedFrame");
    expect(bg.sent).toHaveLength(0);
    const task = bg.message({ type: "passkey.get", requestID: 1, payload: { origin: "https://evil.example" } });
    expect(bg.sent[0].origin).toBe(sender.origin);
    bg.reply({ id: bg.sent[0].id, ok: false });
    await task;
  });

  test("cancellation belongs to originating document and request", async () => {
    const bg = background();
    const task = bg.message({ type: "passkey.get", requestID: 2, payload: {} });
    await bg.message({ type: "passkey.cancel", requestID: 2 }, { ...sender, documentId: "other" });
    expect(bg.sent).toHaveLength(1);
    await bg.message({ type: "passkey.cancel", requestID: 2 });
    expect((await task).error).toBe("cancelled");
    expect(bg.sent[1].type).toBe("cancel");
    expect(bg.sent[1].requestID).toBe(bg.sent[0].id);
    expect(bg.timers.size).toBe(0);
  });

  test("timeout cancels native operation and capacity is bounded", async () => {
    const bg = background();
    const tasks = Array.from({ length: 32 }, () => bg.message({ type: "logins" }));
    expect((await bg.message({ type: "logins" })).error).toBe("busy");
    for (const timer of [...bg.timers.values()]) timer();
    expect((await Promise.all(tasks)).every((reply) => reply.error === "timeout")).toBe(true);
    expect(bg.sent.filter((request) => request.type === "cancel")).toHaveLength(32);
    expect(bg.timers.size).toBe(0);
  });

  test("disconnect drains waiting requests", async () => {
    const bg = background();
    const task = bg.message({ type: "logins" });
    bg.disconnect();
    expect((await task).error).toBe("disconnected");
    expect(bg.timers.size).toBe(0);
  });
});

function pageScript(name, iframe = false) {
  const listeners = {}, sent = [], runtimeRequests = [], timers = new Map();
  let runtimeListener, timerID = 0, nativeCalls = 0;
  const window = {
    location: { href: sender.url, hostname: "example.com", origin: sender.origin },
    PublicKeyCredential: class {},
    addEventListener: (type, callback) => { (listeners[type] ??= []).push(callback); },
    postMessage: (message) => sent.push(message),
  };
  window.top = iframe ? {} : window;
  const navigator = { credentials: { create: async () => { nativeCalls++; return "native"; }, get: async () => { nativeCalls++; return "native"; } } };
  const chrome = { runtime: { id: "ward", onMessage: { addListener: (callback) => { runtimeListener = callback; } }, sendMessage: (message, callback) => { runtimeRequests.push(message); callback?.({ ok: false }); } } };
  const document = { createElement: () => ({}), addEventListener: () => {}, querySelectorAll: () => [], activeElement: null };
  runInNewContext(source(name), { window, navigator, chrome, document, HTMLInputElement: class {},
    ArrayBuffer, Uint8Array, DOMException, btoa, atob,
    setTimeout: (callback) => { timers.set(++timerID, callback); return timerID; }, clearTimeout: (id) => timers.delete(id) });
  return { window, navigator, sent, runtimeRequests, timers, nativeCalls: () => nativeCalls,
    emit: (type, event) => listeners[type]?.forEach((callback) => callback(event)),
    runtime: (message, from = { id: "ward" }) => new Promise((resolve) => runtimeListener(message, from, resolve)),
  };
}

describe("isolated content boundary", () => {
  test("page messages cannot request account lists or passwords", () => {
    const page = pageScript("content");
    for (const type of ["logins", "fill", "hello", "popup.fill"]) {
      page.emit("message", { source: page.window, origin: sender.origin, data: { channel: "ward-webauthn-v1", direction: "request", id: 1, type } });
    }
    expect(page.runtimeRequests).toHaveLength(0);
    page.emit("message", { source: page.window, origin: sender.origin, data: { channel: "ward-webauthn-v1", direction: "request", id: 1, type: "passkey.get" } });
    expect(page.runtimeRequests[0].requestID).toBe(1);
  });

  test("applyFill rejects URL changes within same document", async () => {
    const page = pageScript("content");
    page.window.location.href = "https://evil.example";
    expect((await page.runtime({ type: "applyFill", url: sender.url, data: { password: "secret" } })).ok).toBe(false);
  });
});

describe("WebAuthn lifecycle", () => {
  const options = () => ({ publicKey: { challenge: new Uint8Array([1]), timeout: 30 } });

  test("AbortSignal cancels Ward request and rejects without native fallback", async () => {
    const page = pageScript("webauthn");
    const controller = new AbortController();
    const task = page.navigator.credentials.get({ ...options(), signal: controller.signal });
    controller.abort();
    await expect(task).rejects.toMatchObject({ name: "AbortError" });
    expect(page.sent.map((message) => message.type)).toEqual(["passkey.get", "passkey.cancel"]);
    expect(page.nativeCalls()).toBe(0);
    expect(page.timers.size).toBe(0);
  });

  test("timeout cleans pending request and rejects", async () => {
    const page = pageScript("webauthn");
    const task = page.navigator.credentials.get(options());
    [...page.timers.values()][0]();
    await expect(task).rejects.toMatchObject({ name: "NotAllowedError" });
    expect(page.sent.at(-1).type).toBe("passkey.cancel");
    expect(page.timers.size).toBe(0);
  });

  test("pagehide cancels request", async () => {
    const page = pageScript("webauthn");
    const task = page.navigator.credentials.get(options());
    page.emit("pagehide", {});
    await expect(task).rejects.toMatchObject({ name: "AbortError" });
    expect(page.sent.at(-1).type).toBe("passkey.cancel");
  });

  test("iframe uses native WebAuthn", async () => {
    const page = pageScript("webauthn", true);
    expect(await page.navigator.credentials.get(options())).toBe("native");
    expect(page.sent).toHaveLength(0);
  });

  test("unavailable Ward falls back to native WebAuthn and clears timer", async () => {
    const page = pageScript("webauthn");
    const task = page.navigator.credentials.get(options());
    page.emit("message", { source: page.window, data: { channel: "ward-webauthn-v1", direction: "response", id: 1, result: { ok: false, error: "hostMissing" } } });
    expect(await task).toBe("native");
    expect(page.timers.size).toBe(0);
  });
});
