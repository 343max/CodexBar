function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "hyper",
  name: "Charm Hyper",
  endpoints: ["https://hyper.charm.land"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["hyper.charm.land"],
  settings: [
    { key: "HYPER_API_KEY", title: "API key", type: "secure" },
    { key: "SOURCE_MODE", title: "Source", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const domain = "hyper.charm.land";
    const key = ctx.settings.getSecret("HYPER_API_KEY");
    const webOnly = ctx.settings.get("SOURCE_MODE") === "web";
    const cookiePolicy = ctx.browser.availability(domain);
    const canUseKey = Boolean(key) && !webOnly;
    const missing = () => {
      if (cookiePolicy === "off") {
        throw ctx.fail.missingCredential(
          "Sign in to hyper.charm.land and turn on Charm Hyper browser cookies in Settings, or configure a Charm Hyper API key.",
        );
      }
      if (cookiePolicy === "manual") {
        throw ctx.fail.missingCredential(
          "Paste a Cookie header from a signed-in hyper.charm.land request in Settings, or configure a Charm Hyper API key.",
        );
      }
      throw ctx.fail.missingCredential(
        "No signed-in Hyper session was found. Sign in to hyper.charm.land, or configure a Charm Hyper API key.",
      );
    };
    const amount = (raw, field) => {
      const value = Number(_nullishCoalesce(raw, () => "").replace(/,/g, ""));
      if (!raw || !Number.isFinite(value) || value < 0) {
        throw ctx.fail.parseFailure(`Charm Hyper dashboard ${field} is not a non-negative number.`);
      }
      return value;
    };
    const request = (headers, timeoutSeconds = 10) =>
      ctx.http.get(`https://${domain}/v1/credits`, {
        headers,
        timeoutSeconds,
      });

    // The dashboard renders the Hypercredit balance; /v1/credits accepts bearer keys only, never cookies.
    if (cookiePolicy !== "off") {
      let cookie = null;
      try {
        cookie = await ctx.browser.cookieHeader(domain);
      } catch (error) {
        if (error.transportClass === "cancelled") throw error;
        if (!canUseKey) missing();
      }
      if (cookie !== null) {
        let home = null;
        try {
          home = await ctx.http.get(`https://${domain}/`, {
            headers: { Cookie: cookie, Accept: "text/html" },
            timeoutSeconds: 8,
          });
        } catch (error) {
          if (error.transportClass === "cancelled") throw error;
          if (!canUseKey) throw ctx.fail.networkFailure("Charm Hyper session request failed.");
        }
        if (home) {
          const status = home.status;
          if (status === 429) throw ctx.fail.rateLimited("Charm Hyper dashboard requests are rate limited.");
          if (status >= 500) throw ctx.fail.providerUnavailable(`Charm Hyper dashboard error: HTTP ${status}`);
          const team = /\/teams\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
          // The session request follows same-origin redirects, so a signed-in session lands on the team dashboard.
          if (status === 200 && (team.test(home.url) || team.test(home.bodyText))) {
            const balance = amount(
              _nullishCoalesce(
                _optionalChain([
                  /Hypercredits Available[\s\S]{0,400}?text-5xl font-bold">\s*([0-9][0-9,]*(?:\.[0-9]+)?)/,
                  "access",
                  (_) => _.exec,
                  "call",
                  (_2) => _2(home.bodyText),
                  "optionalAccess",
                  (_3) => _3[1],
                ]),
                () => null,
              ),
              "balance",
            );
            const rows = [
              {
                label: "Balance",
                value: `${ctx.format.number(balance, { maximumFractionDigits: 2 })} HC`,
                usageValue: balance,
              },
            ];
            const plan = _optionalChain([
              /Plan[\s\S]{0,200}?text-3xl font-bold">([^<]+)/,
              "access",
              (_4) => _4.exec,
              "call",
              (_5) => _5(home.bodyText),
              "optionalAccess",
              (_6) => _6[1],
              "optionalAccess",
              (_7) => _7.trim,
              "call",
              (_8) => _8(),
            ]);
            if (plan) rows.push({ label: "Plan", value: plan });
            const refresh = _optionalChain([
              /Next Hypercredit refresh in ([^<]+)/,
              "access",
              (_9) => _9.exec,
              "call",
              (_10) => _10(home.bodyText),
              "optionalAccess",
              (_11) => _11[1],
              "optionalAccess",
              (_12) => _12.trim,
              "call",
              (_13) => _13(),
            ]);
            if (refresh) rows.push({ label: "Refresh", value: refresh });
            return {
              usage: {
                details: [{ title: "Hypercredits", rows }],
                identity: { loginMethod: "Browser session" },
                dataConfidence: "exact",
              },
              sourceLabel: "web",
            };
          }
          if (status !== 200 && status !== 401 && status !== 403 && (status < 300 || status >= 400)) {
            throw ctx.fail.apiFailure(`Charm Hyper dashboard returned HTTP ${status}`);
          }
          ctx.browser.rejectCookie(domain);
          if (!canUseKey) {
            if (cookiePolicy === "manual") {
              throw ctx.fail.authenticationExpired(
                "Charm Hyper session expired. Paste a fresh Cookie header in Settings.",
              );
            }
            throw ctx.fail.authenticationExpired("Charm Hyper session expired. Sign in again at hyper.charm.land.");
          }
        }
      }
    }

    if (!key || webOnly) missing();
    const response = await request({ Authorization: `Bearer ${key}` });
    if (response.status === 401) throw ctx.fail.authenticationExpired("Charm Hyper API key rejected (HTTP 401).");
    if (response.status === 403)
      throw ctx.fail.permissionDenied("Charm Hyper API key cannot access credits (HTTP 403).");
    if (response.status === 429) throw ctx.fail.rateLimited("Charm Hyper credits requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Charm Hyper API error: HTTP ${response.status}`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Charm Hyper API error: HTTP ${response.status}`);

    let payload;
    try {
      payload = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      throw ctx.fail.parseFailure("Charm Hyper credits response is not valid JSON.");
    }
    const balance = _optionalChain([payload, "optionalAccess", (_14) => _14.balance]);
    if (typeof balance !== "number" || !Number.isFinite(balance) || balance < 0) {
      throw ctx.fail.parseFailure("Charm Hyper balance must be a non-negative number.");
    }
    return {
      usage: {
        details: [
          {
            title: "Hypercredits",
            rows: [
              {
                label: "Balance",
                value: `${ctx.format.number(balance, { maximumFractionDigits: 2 })} HC`,
                usageValue: balance,
              },
            ],
          },
        ],
        identity: { loginMethod: "API key" },
        dataConfidence: "exact",
      },
      sourceLabel: "api",
    };
  },
});
