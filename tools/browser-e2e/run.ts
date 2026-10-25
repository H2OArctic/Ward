// Сквозная проверка: настоящий Google Chrome (временный профиль) + расширение Ward + помощник + демо-Ward.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";

const PROFILE = process.env.PROFILE!;
const EXTENSION = process.env.EXTENSION!;
const PYTHON = process.env.PYTHON!;
const PORT = 8765;
mkdirSync(PROFILE, { recursive: true });

const page_html = `<!doctype html><html><body>
<form id="login"><input id="user" name="username" autocomplete="username">
<input id="pass" type="password" name="password"><button>Войти</button></form>
<script>
const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g,"-").replace(/\\//g,"_").replace(/=+$/,"");
window.createPasskey = async (challenge) => {
  const cred = await navigator.credentials.create({ publicKey: {
    rp: { id: "localhost", name: "Тестовый сайт" },
    user: { id: new TextEncoder().encode("user-1"), name: "alice", displayName: "Alice" },
    challenge: Uint8Array.from(atob(challenge), c => c.charCodeAt(0)),
    pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
    authenticatorSelection: { residentKey: "required", userVerification: "required" } } });
  return { isPKC: cred instanceof PublicKeyCredential, json: cred.toJSON(),
           alg: cred.response.getPublicKeyAlgorithm(), pk: b64(cred.response.getPublicKey()) };
};
window.getPasskey = async (challenge) => {
  const cred = await navigator.credentials.get({ publicKey: {
    rpId: "localhost", challenge: Uint8Array.from(atob(challenge), c => c.charCodeAt(0)), userVerification: "required" } });
  return { isPKC: cred instanceof PublicKeyCredential, json: cred.toJSON() };
};
</script></body></html>`;

const change_html = `<!doctype html><html><body>
<form><input id="user" autocomplete="username" value="alice">
<input id="current" type="password" autocomplete="current-password">
<input id="next" type="password" autocomplete="new-password"><button>Сменить</button></form></body></html>`;

const server = Bun.serve({ port: PORT, fetch: (request) => new Response(new URL(request.url).pathname === "/change" ? change_html : page_html,
  { headers: { "content-type": "text/html; charset=utf-8" } }) });

function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "✔" : "✘"} ${name}${detail ? " — " + detail : ""}`);
  if (!ok) process.exitCode = 1;
}

const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  userDataDir: PROFILE,
  headless: true,
  pipe: true,
  enableExtensions: true,
  args: ["--no-first-run", "--no-default-browser-check"],
});
try {
  const id = await browser.installExtension(EXTENSION);
  check("расширение загружено с постоянным идентификатором", id === "fddnjhiefjihmplhkkcemckakfmhplpc", id);

  const page = await browser.newPage();
  await page.goto(`http://localhost:${PORT}/`);

  // Заполнение: настоящий клик (CDP даёт isTrusted) по значку Ward в поле пароля, затем по первой учётке.
  await page.click("#pass");
  const rect = await page.$eval("#pass", (el) => { const r = el.getBoundingClientRect(); return { x: r.right, y: r.top, h: r.height, b: r.bottom, l: r.left }; });
  await page.mouse.click(rect.x - 17, rect.y + rect.h / 2);
  await new Promise((r) => setTimeout(r, 1500));
  await page.mouse.click(rect.l + 40, rect.b + 6 + 6 + 18);
  await new Promise((r) => setTimeout(r, 1500));
  const values = await page.evaluate(() => [document.querySelector<HTMLInputElement>("#user")!.value, document.querySelector<HTMLInputElement>("#pass")!.value]);
  check("форма заполнена из Ward", values[0] === "alice" && values[1] === "demo-password-1", JSON.stringify(values));

  // Смена пароля: значок в поле нового пароля заполняет текущий, а новый остаётся пустым.
  const change = await browser.newPage();
  await change.goto(`http://localhost:${PORT}/change`);
  await change.click("#next");
  const next = await change.$eval("#next", (el) => { const r = el.getBoundingClientRect(); return { x: r.right, y: r.top, h: r.height, b: r.bottom, l: r.left }; });
  await change.mouse.click(next.x - 17, next.y + next.h / 2);
  await new Promise((r) => setTimeout(r, 1500));
  await change.mouse.click(next.l + 40, next.b + 6 + 6 + 18);
  await new Promise((r) => setTimeout(r, 1500));
  const passwords = await change.evaluate(() => [document.querySelector<HTMLInputElement>("#current")!.value, document.querySelector<HTMLInputElement>("#next")!.value]);
  check("смена пароля: заполнен текущий, новый пустой", passwords[0] === "demo-password-1" && passwords[1] === "", JSON.stringify(passwords));

  const popup = await browser.newPage();
  await popup.goto(`chrome-extension://${id}/popup.html`);
  const tabId = await popup.evaluate(async (url) => {
    const tabs = await (globalThis as any).chrome.tabs.query({});
    return tabs.find((tab: any) => tab.url === url).id;
  }, `http://localhost:${PORT}/`);
  const listing: any = await popup.evaluate((tabId) => (globalThis as any).chrome.runtime.sendMessage({ type: "popup.logins", tabId }), tabId);
  check("popup получил идентификатор документа от Chrome", listing?.ok && typeof listing.result?.documentID === "string", JSON.stringify(listing));
  const fillRequest = { type: "popup.fill", tabId, entryID: listing.result?.logins[0]?.entryID, documentID: listing.result?.documentID };
  await page.evaluate(() => { (document.querySelector("#pass") as HTMLInputElement).value = ""; });
  const popupFill: any = await popup.evaluate((message) => (globalThis as any).chrome.runtime.sendMessage(message), fillRequest);
  check("popup заполнил исходный документ без пароля в ответе", popupFill.ok && !popupFill.result && await page.$eval("#pass", (el: any) => el.value) === "demo-password-1");
  await page.goto(`http://localhost:${PORT}/replacement`);
  console.log("→ проверка старого списка после перехода на новый документ");
  const staleFill: any = await popup.evaluate((message) => (globalThis as any).chrome.runtime.sendMessage(message), fillRequest);
  check("popup не заполняет новый документ по старому списку", !staleFill.ok && staleFill.error === "pageUnavailable" && await page.$eval("#pass", (el: any) => el.value) === "");
  const metadataLeak = await page.evaluate(async () => {
    let replied = false;
    const listener = (event: MessageEvent) => { if (event.data?.channel === "ward-webauthn-v1" && event.data.direction === "response" && event.data.id === 424242) replied = true; };
    window.addEventListener("message", listener);
    window.postMessage({ channel: "ward-webauthn-v1", direction: "request", id: 424242, type: "logins" }, location.origin);
    await new Promise((resolve) => setTimeout(resolve, 200));
    window.removeEventListener("message", listener);
    return replied;
  });
  check("страница не получает список учёток через postMessage", !metadataLeak);

  await page.bringToFront();
  // Passkey: создание и вход идут через Ward; результат проверяет py_webauthn как сервер сайта.
  const createChallenge = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
  const created: any = await page.evaluate((c) => (window as any).createPasskey(c), createChallenge);
  check("создан PublicKeyCredential (instanceof)", created.isPKC && created.alg === -7, JSON.stringify(created.json).slice(0, 80));
  const getChallenge = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
  const got: any = await page.evaluate((c) => (window as any).getPasskey(c), getChallenge);
  check("вход passkey вернул PublicKeyCredential", got.isPKC && got.json.id === created.json.id);

  const script = `
import json, sys, base64
from webauthn import verify_registration_response, verify_authentication_response
d = json.loads(sys.stdin.read())
reg = verify_registration_response(credential=d["created"], expected_challenge=base64.b64decode(d["cc"]),
    expected_origin="http://localhost:${PORT}", expected_rp_id="localhost", require_user_verification=True)
auth = verify_authentication_response(credential=d["got"], expected_challenge=base64.b64decode(d["gc"]),
    expected_rp_id="localhost", expected_origin="http://localhost:${PORT}",
    credential_public_key=reg.credential_public_key, credential_current_sign_count=0, require_user_verification=True)
print("ok")`;
  const proc = Bun.spawnSync([PYTHON, "-c", script], {
    stdin: new TextEncoder().encode(JSON.stringify({ created: created.json, got: got.json, cc: createChallenge, gc: getChallenge })),
  });
  const out = proc.stdout.toString() + proc.stderr.toString();
  check("py_webauthn принял регистрацию и вход", proc.exitCode === 0 && out.includes("ok"), out.trim().split("\n").pop());
} finally {
  await browser.close();
  server.stop();
}
