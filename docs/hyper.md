---
summary: "Charm Hyper setup, session/API authentication, and Hypercredit balance."
read_when:
  - Configuring Charm Hyper
---

# Charm Hyper

Charm Hyper is an opt-in bundled TypeScript provider. A browser session reads the signed-in team dashboard with
`GET https://hyper.charm.land/` (same-origin redirects land on `/teams/{team}/dashboard`) and shows the Hypercredit
balance, plan, and refresh note from that page. An API key requests `GET https://hyper.charm.land/v1/credits`,
which accepts bearer keys only — cookie authentication is rejected there, so cookies are never sent to it.

## Authentication

Enable **Settings → Providers → Charm Hyper**. Automatic session access imports Chrome cookies for
`hyper.charm.land`; Manual accepts a Cookie header from that domain, and Off uses only the API key.
Auto prefers the session, falling back to the API key when cookies are missing, the session expires,
or the session request cannot connect. Malformed successful responses fail visibly without fallback.
If Chrome is signed in but cookie access needs permission, use **Refresh** beside **Cookie source**.
A successful browser refresh is reported as `web` and saves the imported session for subsequent refreshes.

Missing guidance names the actual blocker instead of a generic sign-in request: Off says the cookie source is
turned off, Manual asks for a pasted Cookie header, and an Automatic source that finds no cookie says no
signed-in session was found. A session that does not reach the dashboard (HTTP 401/403, a sign-in redirect, or a
marketing page) is rejected before the API-key fallback.

Add an API key in the provider settings or set `HYPER_API_KEY` in the environment that launches CodexBar.
Saved API keys and manual Cookie headers use the CodexBar config file. Multiple API-key token accounts
are supported; in Auto mode, selecting one uses API mode so an unrelated browser session cannot override that account.
Cookies and bearer keys are sent separately, only to the declared `https://hyper.charm.land` origin.

The CLI supports `codexbar usage --provider hyper --source api`. `--source web` requires a usable session
and never falls back to a key; a configured manual Cookie header works without browser import.
Automatic browser import is macOS-only. On Linux, Auto can fall back to the API key.

## Display and limits

The card and CLI show a **Hypercredits → Balance** detail row. The JSON detail row preserves the numeric
balance in `usageValue` alongside the HC display string. A dashboard session also reports **Plan** and **Refresh**
rows when the page shows them; no usage percentage, spend history, limit, or reset countdown is inferred
from this balance-only response. The menu bar shows HC through the Balance or Auto % layout token;
widgets are not supported.
Missing credentials produce setup guidance instead of a fabricated zero balance.

The request and parsing contracts are covered by synthetic fixtures on both plugin engines, including the
dashboard markup shape, redirect/expiry handling, and the API-key response.
