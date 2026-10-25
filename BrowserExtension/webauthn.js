// Мир страницы: navigator.credentials.create/get для passkey идут в Ward. Отказались или Ward недоступен —
// запрос уходит браузеру как обычно (ключ безопасности, «Пароли» macOS). Условный вход (подсказка passkey
// в поле логина, mediation: "conditional") остаётся браузеру.
(() => {
  const credentials = navigator.credentials;
  if (!credentials || !window.PublicKeyCredential || window !== window.top) return;
  const originalCreate = credentials.create.bind(credentials);
  const originalGet = credentials.get.bind(credentials);
  const CHANNEL = "ward-webauthn-v1";
  let sequence = 0;
  const pending = new Map();

  const b64 = (buffer) => {
    const bytes = buffer instanceof ArrayBuffer ? new Uint8Array(buffer) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const unb64 = (text) => {
    const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  };

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.channel !== CHANNEL || data.direction !== "response") return;
    const waiter = pending.get(data.id);
    if (!waiter) return;
    pending.delete(data.id);
    waiter.finish(data.result);
  });

  function askWard(type, payload, options) {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      const signal = options?.signal;
      const timeout = Math.min(Math.max(options?.publicKey?.timeout || 60_000, 1), 60_000);
      const finish = (result, error) => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
        pending.delete(id);
        if (error) reject(error); else resolve(result);
      };
      const cancel = (error) => {
        window.postMessage({ channel: CHANNEL, direction: "request", id, type: "passkey.cancel" }, window.location.origin);
        finish(null, error);
      };
      const abort = () => cancel(new DOMException("Запрос отменён", "AbortError"));
      const timer = setTimeout(() => cancel(new DOMException("Время ожидания истекло", "NotAllowedError")), timeout);
      if (signal?.aborted) return abort();
      signal?.addEventListener("abort", abort, { once: true });
      pending.set(id, { finish });
      window.postMessage({ channel: CHANNEL, direction: "request", id, type, payload }, window.location.origin);
    });
  }

  window.addEventListener("pagehide", () => {
    for (const [id, request] of pending) {
      window.postMessage({ channel: CHANNEL, direction: "request", id, type: "passkey.cancel" }, window.location.origin);
      request.finish(null, new DOMException("Страница закрыта", "AbortError"));
    }
  });

  // Объект, который сайт не отличит от настоящего: прототипы браузерных классов (instanceof проходит),
  // значения — собственными свойствами (они перекрывают браузерные геттеры).
  function define(target, prototype, values) {
    Object.setPrototypeOf(target, prototype);
    for (const [key, value] of Object.entries(values)) {
      Object.defineProperty(target, key, { value, enumerable: true, configurable: true });
    }
    return target;
  }

  function attestationCredential(r) {
    const authenticatorData = unb64(r.authenticatorData);
    const response = define({}, AuthenticatorAttestationResponse.prototype, {
      clientDataJSON: unb64(r.clientDataJSON),
      attestationObject: unb64(r.attestationObject),
      getAuthenticatorData: () => authenticatorData,
      getPublicKey: () => unb64(r.publicKey),
      getPublicKeyAlgorithm: () => r.publicKeyAlgorithm,
      getTransports: () => ["internal", "hybrid"],
    });
    const json = {
      id: r.id, rawId: r.rawId, type: "public-key", authenticatorAttachment: "platform", clientExtensionResults: {},
      response: { clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
                  publicKey: r.publicKey, publicKeyAlgorithm: r.publicKeyAlgorithm, transports: ["internal", "hybrid"] },
    };
    return define({}, PublicKeyCredential.prototype, {
      id: r.id, rawId: unb64(r.rawId), type: "public-key", authenticatorAttachment: "platform", response,
      getClientExtensionResults: () => ({}), toJSON: () => json,
    });
  }

  function assertionCredential(r) {
    const response = define({}, AuthenticatorAssertionResponse.prototype, {
      clientDataJSON: unb64(r.clientDataJSON),
      authenticatorData: unb64(r.authenticatorData),
      signature: unb64(r.signature),
      userHandle: r.userHandle ? unb64(r.userHandle) : null,
    });
    const json = {
      id: r.id, rawId: r.rawId, type: "public-key", authenticatorAttachment: "platform", clientExtensionResults: {},
      response: { clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature,
                  userHandle: r.userHandle },
    };
    return define({}, PublicKeyCredential.prototype, {
      id: r.id, rawId: unb64(r.rawId), type: "public-key", authenticatorAttachment: "platform", response,
      getClientExtensionResults: () => ({}), toJSON: () => json,
    });
  }

  const bytes = (value) => (value instanceof ArrayBuffer || ArrayBuffer.isView(value) ? b64(value) : null);

  credentials.create = async function (options) {
    const pk = options && options.publicKey;
    if (!pk) return originalCreate(options);
    const payload = {
      rpID: (pk.rp && pk.rp.id) || window.location.hostname,
      rpName: (pk.rp && pk.rp.name) || "",
      userHandle: bytes(pk.user && pk.user.id),
      userName: (pk.user && pk.user.name) || "",
      userDisplayName: (pk.user && pk.user.displayName) || "",
      challenge: bytes(pk.challenge),
      algorithms: (pk.pubKeyCredParams || []).map((p) => p.alg),
      excludeCredentials: (pk.excludeCredentials || []).map((c) => bytes(c.id)).filter(Boolean),
    };
    if (!payload.userHandle || !payload.challenge) return originalCreate(options);
    const result = await askWard("passkey.create", payload, options);
    if (result && result.ok) return attestationCredential(result.result);
    if (result && result.error === "alreadyRegistered") {
      throw new DOMException("Этот passkey уже сохранён в Ward", "InvalidStateError");
    }
    return originalCreate(options);
  };

  credentials.get = async function (options) {
    const pk = options && options.publicKey;
    if (!pk || options.mediation === "conditional") return originalGet(options);
    const payload = {
      rpID: pk.rpId || window.location.hostname,
      challenge: bytes(pk.challenge),
      allowCredentials: (pk.allowCredentials || []).map((c) => bytes(c.id)).filter(Boolean),
    };
    if (!payload.challenge) return originalGet(options);
    const result = await askWard("passkey.get", payload, options);
    if (result && result.ok) return assertionCredential(result.result);
    return originalGet(options);
  };
})();
