# Autofill playground

Local static pages + a tiny stdlib Python server for testing Wowser's autofill by hand
(passwords, emails, names, phones, addresses, `<select>` menus) against well-behaved,
ambiguous, and framework-y markup.

## Run

```sh
python3 scripts/autofill_test/server.py            # http://localhost:8765/
python3 scripts/autofill_test/server.py --port 8799
```

Binds `127.0.0.1` only. No dependencies. The React and Vue pages load their libraries from
cdn.jsdelivr.net (network required for those two pages only).

- `GET` any file → served with `Cache-Control: no-store`.
- `POST` any non-`/api/` path → "Submitted" page echoing the decoded fields. Fields whose name
  contains `pass` or `pw` are masked (length shown) with a reveal toggle, plus a link back.
- `POST /api/login` (JSON or form-encoded) → `{"ok": true, "user": ...}` after ~300 ms.
  Password `wrong` → HTTP 401 `{"ok": false}` (for "don't offer to save a failed login").
- `POST /api/<other>` → `{"ok": true}` after ~300 ms.

**Two hosts:** `http://localhost:8765` and `http://127.0.0.1:8765` are the same server but
different hosts/origins to the browser. Use them to test credential matching across hosts
(`cross-host.html`) and cross-origin iframes (`login-iframe.html`).

## The event panel

Every page includes `playground.js` / `playground.css`, which add a fixed panel on the right:

- **Event log** — `focusin`/`focusout`, `keydown`, `beforeinput` (with `inputType` and `data`),
  `input`, `change`, `submit`, for every field including open shadow roots. Untrusted
  (script-dispatched) events are marked `(untrusted)`.
- **Values** — every field's current value, polled every 500 ms. A row turns red and a
  `SILENT CHANGE` line is logged when a value changed **without** an `input`/`change` event —
  that is exactly the kind of fill React/Vue miss.
- **Clear log**, **Reset page** (reloads without query/hash), **Hide**.
- Pages add their own notes with `PG.log(...)` (fetch results, route changes, rebuilds).

## Scenarios

| Group | Page | What it tests |
|---|---|---|
| Logins | `login-classic.html` | POST form with autocomplete attrs; menu, fill both, save on submit |
| | `login-ambiguous.html` | No autocomplete attrs; `name="login"` / `name="pwd"`, decoy company field |
| | `login-two-step.html` | Username-first, password revealed on the same page |
| | `login-two-step-1.html` → `-2.html` | Username-first across two pages (hidden username on page 2) |
| | `login-remember.html` | Remember-me checkbox, hidden inputs, honeypots must stay untouched |
| | `login-iframe.html` | Same-origin and cross-origin iframe logins |
| | `login-modal.html` | Native `<dialog>` and div modal (fetch, then removed) |
| | `multi-form.html` | Search + login + newsletter on one page |
| | `login-password-toggle.html` | type=text until focus; show/hide toggle |
| | `login-otp.html` | Password step → OTP step (one-time-code + 6 digit boxes) |
| | `cross-host.html` | Same pages on localhost vs 127.0.0.1 |
| Sign-up | `signup.html` | new-password + confirm, generated password fills both |
| | `change-password.html` | current / new / confirm; update instead of duplicate |
| Identity & address | `contact.html` | first / last / email / phone, plus a no-attrs copy |
| | `shipping.html` | Full address with Country (~230) and State selects |
| | `billing-shipping.html` | Two address sections on one form must stay separate |
| | `address-de.html` | German labels: Vorname / Nachname / Straße / Hausnummer / PLZ / Ort / Land |
| | `checkout-card.html` | Card fields never get identity data; password-typed CVC isn't a login |
| Selects | `select-countries.html` | Long list, searchable menu, diacritics |
| | `select-optgroups.html` | Group headings, disabled optgroup, initial selection |
| | `select-disabled.html` | Disabled / hidden options, disabled select |
| | `select-custom.html` | Transparent select over a styled div; hidden select + div listbox |
| | `select-async.html` | Options arrive after 1 s; dependent Country → City |
| Unorthodox | `no-form.html` | No `<form>`: div button, fetch, DOM swap |
| | `react-login.html` | React 18 controlled inputs, "React state" readouts, pushState, unmount |
| | `vue-login.html` | Vue 3 `v-model` / `v-model.lazy`, v-if swap |
| | `shadow-dom.html` | Open + closed shadow roots, form-associated custom elements |
| | `contenteditable.html` | `contenteditable` role=textbox "inputs" |
| | `placeholder-only.html` | No name/id/label, placeholder only |
| | `aria-labels.html` | Sibling `<span>`, `aria-labelledby`, `aria-label`, wrapping label |
| | `enter-keydown.html` | Enter handled in keydown with preventDefault, no form |
| | `rerender.html` | Inputs replaced per keystroke; form rebuilt on a timer |
| | `lazy-form.html` | Form inserted after 2 s; infinite scroll appends another form |

Each page states its **Expected** behaviour and the test credentials to use.

## Manual test checklist

Start with no saved data for `localhost`, then work down the list.

**Saving**
- [ ] `login-classic`: submit → save prompt for `alice@example.com`; Submitted page shows the password masked.
- [ ] `login-ambiguous`: save prompt for `alice` even though there are no autocomplete attrs.
- [ ] `login-two-step` and `login-two-step-1/2`: saved username is the step-1 email, not empty.
- [ ] `no-form`, `react-login`, `vue-login`, `login-modal` (div), `shadow-dom`, `enter-keydown`, `login-otp`:
      save prompt appears after the fetch + DOM swap (SPA detection, within ~3.5 s).
- [ ] React page with password `wrong`: 401, form stays, **no** save prompt.
- [ ] `multi-form` newsletter, `lazy-form` newsletter, `checkout-card`: **no** save-password prompt.
- [ ] `change-password`: offers to **update** the existing entry, not add a second one.
- [ ] `signup`: saves the new password once (the confirm field isn't a separate login).

**Suggestion menu**
- [ ] Appears under the focused field on focus/click; correct position inside iframes, `<dialog>`, and modals.
- [ ] Doesn't appear on search boxes, OTP boxes, card fields, promo/gift/referral codes, honeypots.
- [ ] Up/Down moves the highlight; **Return fills** username + password and the page does not see that Return
      (`enter-keydown`: attempt counter doesn't go up with an empty password).
- [ ] Escape closes the menu without filling.
- [ ] After filling the username, focus moves to the password (or the password is filled too).
- [ ] Menu survives or closes cleanly when the field is replaced under it (`rerender`).
- [ ] Fields inserted late are picked up (`lazy-form`, `login-modal`, `login-two-step`, `select-async`).
- [ ] `cross-host`: logins saved on `localhost` are never auto-filled on `127.0.0.1` (and vice versa).

**Fill quality (watch the event panel)**
- [ ] Each filled field logs `beforeinput` + `input` (and `change` on blur or immediately); no red `SILENT CHANGE`.
- [ ] `react-login`: every "React state" readout matches the DOM after fill; Sign in button enables.
- [ ] `vue-login`: "Vue state" matches for `v-model`; `v-model.lazy` syncs at the latest on blur.
- [ ] `contact`, `shipping`, `address-de`: one choice fills the whole group; unrelated fields untouched.
- [ ] `billing-shipping`: filling shipping leaves billing empty and vice versa.
- [ ] `checkout-card`: no identity data in any card field.
- [ ] `login-remember`: checkbox, hidden inputs and honeypots unchanged (check the Submitted page).
- [ ] `shadow-dom`: open root fills; record behaviour for the closed root and form-associated elements.

**Selects**
- [ ] Clicking a select opens the searchable menu; typing filters ("ger", "cote" finds Côte d’Ivoire).
- [ ] Return picks the highlight, Escape cancels, the page gets `input` + `change`.
- [ ] Optgroup labels shown as headings; disabled options and the disabled optgroup can't be picked.
- [ ] Hidden placeholder option not listed; fully disabled select doesn't open.
- [ ] Transparent select over a div (`select-custom` 1) opens the menu in the right place; the div face updates.
- [ ] Async options (`select-async`) are all visible once loaded; Country → City repopulation handled.
- [ ] Address fill sets Country and State selects by value or by text (`shipping`).
