# Chrome extension permissions

The extension is an interface to Ward on the same Mac. It stores no vault data and makes no network requests of its own. Passwords and passkeys remain in Ward's encrypted vault; the extension receives only the data Ward releases for the current tab's site.

| Permission | Purpose |
|---|---|
| `nativeMessaging` | Communicates with Ward through its helper (`local.ward`). The helper accepts only this extension through `allowed_origins`; Ward verifies signatures and accepts only its helper launched by Chrome. |
| `activeTab` | Lets the extension popup list credentials for the active tab and fill its form. |
| `host_permissions: <all_urls>` | Allows page scripts to show the Ward icon in login fields and intercept `navigator.credentials` for passkeys across sites. Chrome's `sender` supplies the page address for requests to Ward; the page does not supply it. |

## Page scripts

- `webauthn.js` runs in the page world. It routes `navigator.credentials.create/get` calls with `publicKey` to Ward. If Ward declines or is unavailable, the request falls back to the browser. Conditional mediation (`mediation: "conditional"`) and passkeys inside iframes stay with the browser. An `AbortSignal`, navigation, or timeout cancels the request to Ward.
- `content.js` runs in the isolated world. Its UI uses a closed Shadow DOM and reacts only to trusted clicks (`isTrusted`). It accepts page messages only for passkeys; a page cannot obtain credential lists or passwords through `postMessage`.

## Request boundaries

Popup autofill is bound to the original Chrome document's `documentId` and address. If the tab navigates, Ward's response is not delivered to the replacement page. HTTPS credentials are not released to HTTP pages.

At most 32 extension requests may be pending at once. After 65 seconds, a pending request times out and sends a cancellation.

The extension does not use `chrome.storage`. Its ID is stable through the public `key` in the manifest; the helper's allowed origin depends on that ID.
