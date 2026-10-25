// Изолированный мир расширения на странице: пересылает запросы passkey из webauthn.js в фон и показывает
// значок Ward в полях входа со списком подходящих учёток. Интерфейс — в Shadow DOM: стили сайта его не ломают.
(() => {
  const CHANNEL = "ward-webauthn-v1";

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (event.source !== window || event.origin !== window.location.origin || !data || data.channel !== CHANNEL || data.direction !== "request" ||
      !["passkey.create", "passkey.get", "passkey.cancel"].includes(data.type) || !Number.isSafeInteger(data.id)) return;
    chrome.runtime.sendMessage({ type: data.type, payload: data.payload, requestID: data.id }, (result) => {
      const reply = result || { ok: false, error: chrome.runtime.lastError ? "extensionError" : "noAnswer" };
      window.postMessage({ channel: CHANNEL, direction: "response", id: data.id, result: reply }, window.location.origin);
    });
  });

  // Роль поля — прежде всего по стандартному autocomplete (username, current-password, one-time-code),
  // и только без него — по имени и подписи.
  const tokens = (el) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
  const isPassword = (el) => el instanceof HTMLInputElement && el.type === "password";
  /// Поле нового пароля (регистрация, смена пароля): сюда сохранённый пароль не подставляем, если есть текущий.
  const isNewPassword = (el) => isPassword(el) && tokens(el).includes("new-password");
  const isUsername = (el) =>
    el instanceof HTMLInputElement &&
    ["text", "email", "tel", ""].includes(el.type) &&
    (tokens(el).includes("username") || tokens(el).includes("email") || el.type === "email" ||
      /user|login|email|mail|phone|логин|почт/i.test([el.name, el.id, el.placeholder, el.getAttribute("aria-label")].join(" ")));
  const isOneTimeCode = (el) =>
    el instanceof HTMLInputElement &&
    (el.autocomplete === "one-time-code" || /otp|totp|2fa|one.?time|code|код/i.test([el.name, el.id, el.placeholder].join(" "))) &&
    !isPassword(el);

  /// Поле логина рядом с полем пароля: ближайшее видимое текстовое поле перед ним в той же форме.
  function usernameFor(password) {
    const scope = password.form || document;
    const inputs = [...scope.querySelectorAll("input")].filter((el) => el.offsetParent !== null);
    const index = inputs.indexOf(password);
    for (let i = index - 1; i >= 0; i--) {
      const el = inputs[i];
      if (["text", "email", "tel"].includes(el.type)) return el;
    }
    return null;
  }

  /// Поле пароля формы: текущий пароль важнее нового, чтобы на странице смены пароля не заполнить поле нового.
  function passwordIn(scope) {
    const visible = [...scope.querySelectorAll('input[type="password"]')].filter((el) => el.offsetParent !== null);
    return visible.find((el) => tokens(el).includes("current-password")) || visible.find((el) => !isNewPassword(el)) || visible[0] || null;
  }

  function passwordFor(username) {
    return passwordIn(username.form || document);
  }

  /// Значение, которое заметят и React, и обычные формы: через нативный сеттер и события input/change.
  function setValue(el, value) {
    if (!el || value == null) return;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const host = document.createElement("ward-autofill");
  let shadow = null;
  let menu = null;
  let badge = null;
  let target = null;

  function ensureUI() {
    if (shadow) return;
    shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `
      <style>
        :host { all: initial; }
        .badge { position: fixed; width: 22px; height: 22px; border-radius: 6px; background: #2A2D33; cursor: pointer;
                 display: flex; align-items: center; justify-content: center; z-index: 2147483647;
                 box-shadow: 0 1px 3px rgba(0,0,0,.35); transition: background .12s; }
        .badge:hover { background: #3A3D45; }
        .badge svg { width: 13px; height: 13px; }
        .menu { position: fixed; min-width: 260px; max-width: 360px; background: #202227; color: #ECEDEF; border-radius: 10px;
                border: 1px solid rgba(255,255,255,.1); box-shadow: 0 8px 28px rgba(0,0,0,.45); padding: 6px;
                font: 13px -apple-system, BlinkMacSystemFont, sans-serif; z-index: 2147483647; }
        .row { display: flex; flex-direction: column; gap: 2px; padding: 8px 10px; border-radius: 7px; cursor: pointer; }
        .row:hover, .row:focus { background: #2E3139; outline: none; }
        .title { font-weight: 600; }
        .sub { color: #9A9EA8; font-size: 12px; }
        .note { padding: 8px 10px; color: #9A9EA8; }
      </style>`;
    (document.body || document.documentElement).appendChild(host);
  }

  const KEY_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="#F2B155" stroke-width="2.6" stroke-linecap="round">
    <circle cx="8" cy="15" r="4.5"/><path d="M11.3 11.7 20 3m-3.5 3.5 2.5 2.5M14 9l2 2"/></svg>`;

  function showBadge(field) {
    ensureUI();
    target = field;
    if (!badge) {
      badge = document.createElement("div");
      badge.className = "badge";
      badge.title = "Ward — выбрать учётку";
      badge.innerHTML = KEY_ICON;
      badge.addEventListener("mousedown", (event) => {
        // Только настоящий клик: скрипт страницы не должен уметь «нажать» за человека.
        if (!event.isTrusted) return;
        event.preventDefault();
        event.stopPropagation();
        toggleMenu();
      });
      shadow.appendChild(badge);
    }
    const rect = field.getBoundingClientRect();
    badge.style.top = `${rect.top + (rect.height - 22) / 2}px`;
    badge.style.left = `${rect.right - 28}px`;
    badge.style.display = "flex";
  }

  function hideAll() {
    if (badge) badge.style.display = "none";
    closeMenu();
  }

  function closeMenu() {
    if (menu) menu.remove();
    menu = null;
  }

  function note(text) {
    const div = document.createElement("div");
    div.className = "note";
    div.textContent = text;
    return div;
  }

  const MESSAGES = {
    locked: "Ward заблокирован — откройте его и повторите",
    wardNotRunning: "Ward не запущен",
    hostMissing: "Помощник Ward не установлен: Ward → Настройки → Браузер",
    notPaired: "Разрешите расширение в окне Ward",
  };

  function toggleMenu() {
    if (menu) return closeMenu();
    menu = document.createElement("div");
    menu.className = "menu";
    const rect = target.getBoundingClientRect();
    menu.style.top = `${rect.bottom + 6}px`;
    menu.style.left = `${Math.max(8, rect.left)}px`;
    menu.appendChild(note("Ищу в Ward…"));
    shadow.appendChild(menu);
    chrome.runtime.sendMessage({ type: "logins" }, (reply) => {
      if (!menu) return;
      menu.textContent = "";
      if (!reply || !reply.ok) {
        menu.appendChild(note(MESSAGES[reply && reply.error] || "Ward недоступен"));
        return;
      }
      const logins = reply.result.logins;
      if (!logins.length) {
        menu.appendChild(note("Для этого сайта в Ward учёток нет"));
        return;
      }
      for (const login of logins) {
        const row = document.createElement("div");
        row.className = "row";
        row.tabIndex = 0;
        const title = document.createElement("div");
        title.className = "title";
        title.textContent = login.title;
        const sub = document.createElement("div");
        sub.className = "sub";
        sub.textContent = login.login || (login.hasPassword ? "пароль" : "");
        row.append(title, sub);
        row.addEventListener("mousedown", (event) => {
          if (!event.isTrusted) return;
          event.preventDefault();
          fill(login.entryID);
        });
        menu.appendChild(row);
      }
    });
  }

  function fill(entryID) {
    const field = target;
    const url = window.location.href;
    closeMenu();
    chrome.runtime.sendMessage({ type: "fill", entryID }, (reply) => {
      if (reply && reply.ok && window.location.href === url && field?.isConnected) apply(reply.result, field);
    });
  }

  /// Заполнить форму: от поля под фокусом, а без него (кнопка расширения) — первую видимую форму входа.
  function apply(data, field) {
    const start = field || document.activeElement;
    if (start && isOneTimeCode(start)) return setValue(start, data.code);
    const password = start && isPassword(start) && !isNewPassword(start) ? start
      : start && isPassword(start) ? passwordIn(start.form || document)
      : start && isUsername(start) ? passwordFor(start)
      : passwordIn(document);
    const username = start && isUsername(start) ? start : password ? usernameFor(password) : null;
    if (username && data.login) setValue(username, data.login);
    if (password && data.password) setValue(password, data.password);
    if (password) password.focus();
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== chrome.runtime.id || window !== window.top) return;
    if (message.type === "documentContext") {
      chrome.runtime.sendMessage({ type: "documentContext" }, (context) => sendResponse(context));
      return true;
    }
    if (message.type !== "applyFill") return;
    if (message.url !== window.location.href) return sendResponse({ ok: false });
    apply(message.data, null);
    sendResponse({ ok: true });
  });

  document.addEventListener(
    "focusin",
    (event) => {
      const el = event.target;
      if (isPassword(el) || isUsername(el) || isOneTimeCode(el)) showBadge(el);
    },
    true
  );
  document.addEventListener(
    "mousedown",
    (event) => {
      if (event.composedPath().includes(host)) return;
      if (target && event.target !== target) hideAll();
    },
    true
  );
  window.addEventListener("scroll", () => target && badge && badge.style.display !== "none" && showBadge(target), true);
  window.addEventListener("resize", () => hideAll());
})();
