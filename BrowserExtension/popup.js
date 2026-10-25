// Учётки Ward для активной вкладки; выбор — заполнение формы на странице.
const MESSAGES = {
  pageUnavailable: "Страница изменилась — откройте список учёток заново",
  busy: "Ward занят — повторите через несколько секунд",
  timeout: "Время ожидания истекло — повторите запрос",
  cancelled: "Запрос отменён",
  locked: "Ward заблокирован — откройте его и повторите",
  wardNotRunning: "Ward не запущен",
  hostMissing: "Помощник Ward не установлен: Ward → Настройки → Браузер",
  notPaired: "Разрешите расширение в окне Ward",
};

function note(text) {
  const div = document.createElement("div");
  div.className = "note";
  div.textContent = text;
  return div;
}

chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
  const list = document.getElementById("list");
  if (!tab) return;
  chrome.runtime.sendMessage({ type: "popup.logins", tabId: tab.id }, (reply) => {
    list.textContent = "";
    if (!reply || !reply.ok) return list.appendChild(note(MESSAGES[reply && reply.error] || "Ward недоступен"));
    if (!reply.result.logins.length) return list.appendChild(note("Для этого сайта в Ward учёток нет"));
    let filling = false;
    for (const login of reply.result.logins) {
      const row = document.createElement("div");
      row.className = "row";
      const title = document.createElement("div");
      title.className = "title";
      title.textContent = login.title;
      const sub = document.createElement("div");
      sub.className = "sub";
      sub.textContent = login.login || "пароль";
      row.append(title, sub);
      row.addEventListener("click", () => {
        if (filling) return;
        filling = true;
        chrome.runtime.sendMessage({ type: "popup.fill", tabId: tab.id, documentID: reply.result.documentID, entryID: login.entryID }, (result) => {
          if (result?.ok) return window.close();
          filling = false;
          list.replaceChildren(note(MESSAGES[result?.error] || "Не удалось заполнить — повторите запрос"));
        });
      });
      list.appendChild(row);
    }
  });
});
