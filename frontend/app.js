// VPN toggle SPA — Cognito Hosted UI (Authorization Code + PKCE) login,
// then calls the JWT-protected API. No shared secret.
(function () {
  const $ = (id) => document.getElementById(id);
  const statusEl = $("status");
  const btnOn = $("btnOn"), btnOff = $("btnOff"), btnStatus = $("btnStatus");
  const btnLogin = $("btnLogin"), btnLogout = $("btnLogout");
  const userEl = $("user");
  const progressWrap = $("progressWrap"), progressBar = $("progressBar"), progressLabel = $("progressLabel");

  const C = window.CONFIG || {};
  const EXPECTED = C.EXPECTED_ASSOC_SEC || 210;
  const TOKENS_KEY = "vpn_tokens";

  // ---- PKCE helpers ----
  function b64url(buf) {
    return btoa(String.fromCharCode.apply(null, new Uint8Array(buf)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  async function sha256(str) {
    return await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
  }
  function randStr(n) {
    const a = new Uint8Array(n); crypto.getRandomValues(a);
    return b64url(a.buffer);
  }

  async function login() {
    const verifier = randStr(48);
    sessionStorage.setItem("pkce_verifier", verifier);
    const challenge = b64url(await sha256(verifier));
    const u = new URL(C.COGNITO_DOMAIN + "/oauth2/authorize");
    u.searchParams.set("response_type", "code");
    u.searchParams.set("client_id", C.COGNITO_CLIENT_ID);
    u.searchParams.set("redirect_uri", C.REDIRECT_URI);
    u.searchParams.set("scope", "openid email profile");
    u.searchParams.set("code_challenge", challenge);
    u.searchParams.set("code_challenge_method", "S256");
    window.location.assign(u.toString());
  }

  function logout() {
    localStorage.removeItem(TOKENS_KEY);
    const u = new URL(C.COGNITO_DOMAIN + "/logout");
    u.searchParams.set("client_id", C.COGNITO_CLIENT_ID);
    u.searchParams.set("logout_uri", C.REDIRECT_URI);
    window.location.assign(u.toString());
  }

  async function exchangeCode(code) {
    const verifier = sessionStorage.getItem("pkce_verifier");
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      client_id: C.COGNITO_CLIENT_ID,
      code: code,
      redirect_uri: C.REDIRECT_URI,
      code_verifier: verifier || "",
    });
    const res = await fetch(C.COGNITO_DOMAIN + "/oauth2/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
    if (!res.ok) throw new Error("token exchange failed");
    const t = await res.json();
    t.obtained_at = Date.now();
    localStorage.setItem(TOKENS_KEY, JSON.stringify(t));
    return t;
  }

  function tokens() {
    try { return JSON.parse(localStorage.getItem(TOKENS_KEY) || "null"); } catch { return null; }
  }
  function idToken() { const t = tokens(); return t && t.id_token; }
  function decodeJwt(jwt) {
    try { return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); }
    catch { return {}; }
  }

  function setStatus(kind, text) {
    statusEl.className = "status " + kind;
    statusEl.innerHTML = '<span class="dot ' + kind + '"></span>' + text;
  }
  function showProgress(on) {
    progressWrap.style.display = on ? "block" : "none";
    if (!on) { progressBar.style.width = "0%"; progressLabel.textContent = ""; }
  }
  let startAt = 0;
  function renderProgress(done) {
    if (done) {
      progressBar.style.background = "#22c55e"; progressBar.style.width = "100%";
      progressLabel.textContent = "Ready."; setTimeout(() => showProgress(false), 1500); return;
    }
    const el = (Date.now() - startAt) / 1000;
    progressBar.style.background = "#eab308";
    progressBar.style.width = Math.min(95, Math.round((el / EXPECTED) * 100)) + "%";
    progressLabel.textContent = "~" + Math.max(0, Math.round(EXPECTED - el)) + "s remaining (estimate)";
  }

  function classify(data) {
    if (!data || typeof data !== "object") return ["off", "Unknown response."];
    const msg = data.message || ""; const state = data.state || "";
    if (data.ready === true || msg === "VPN active" || state === "associated") {
      const portal = data.portal_url
        ? '<br><a href="' + data.portal_url + '" target="_blank" rel="noopener" style="color:#22c55e;">Open self-service portal ↗</a>'
        : "";
      const ip = data.egress_ip ? " — egress IP <code>" + data.egress_ip + "</code>" : "";
      return ["active", "VPN active" + ip + portal];
    }
    if (msg === "VPN starting" || state === "associating") return ["starting", "VPN starting… (~" + EXPECTED + "s)"];
    if (msg === "disassociating" || state === "disassociating") return ["stopping", "VPN stopping…"];
    if (data.associated === false) return ["off", "VPN is off."];
    return ["off", msg || "VPN is off."];
  }

  const TRANSITIONAL = ["starting", "stopping"];
  let pollTimer = null; const POLL_MS = 8000, POLL_MAX = 90; let pollCount = 0;
  function stopPolling() { if (pollTimer) clearTimeout(pollTimer); pollTimer = null; pollCount = 0; }

  async function doCall(action, isPoll) {
    const jwt = idToken();
    if (!jwt) { setStatus("off", "Please sign in."); return; }
    if (!isPoll) { setStatus("starting", "Working…"); [btnOn, btnOff, btnStatus].forEach(b => b.disabled = true); }
    try {
      const u = new URL(C.API_URL);
      u.searchParams.set("action", action);
      const res = await fetch(u.toString(), { headers: { Authorization: "Bearer " + jwt } });
      if (res.status === 401 || res.status === 403) { stopPolling(); setStatus("off", "Session expired — sign in again."); localStorage.removeItem(TOKENS_KEY); updateAuthUI(); return; }
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { stopPolling(); setStatus("error", (data && data.error) || ("HTTP " + res.status)); return; }
      const [kind, text] = classify(data);
      if (TRANSITIONAL.indexOf(kind) >= 0 && pollCount < POLL_MAX) {
        setStatus(kind, text);
        if (kind === "starting") { if (!startAt) startAt = Date.now(); showProgress(true); renderProgress(false); }
        else showProgress(false);
        pollCount++; pollTimer = setTimeout(() => doCall("status", true), POLL_MS); return;
      }
      stopPolling(); setStatus(kind, text);
      if (kind === "active") { renderProgress(true); startAt = 0; } else { showProgress(false); startAt = 0; }
    } catch (e) {
      stopPolling(); setStatus("error", "Request failed: " + e.message);
    } finally {
      if (!isPoll) [btnOn, btnOff, btnStatus].forEach(b => b.disabled = false);
    }
  }
  function call(action) { stopPolling(); pollCount = 0; doCall(action, false); }

  function updateAuthUI() {
    const t = tokens();
    const loggedIn = !!(t && t.id_token);
    btnLogin.style.display = loggedIn ? "none" : "inline-block";
    btnLogout.style.display = loggedIn ? "inline-block" : "none";
    [btnOn, btnOff, btnStatus].forEach(b => b.disabled = !loggedIn);
    if (loggedIn) {
      const claims = decodeJwt(t.id_token);
      userEl.textContent = claims.email || claims["cognito:username"] || "signed in";
      setStatus("off", "Signed in. Press Start.");
    } else {
      userEl.textContent = "";
      setStatus("off", "Please sign in.");
    }
  }

  btnLogin.addEventListener("click", login);
  btnLogout.addEventListener("click", logout);
  btnOn.addEventListener("click", () => call("on"));
  btnOff.addEventListener("click", () => call("off"));
  btnStatus.addEventListener("click", () => call("status"));

  // Handle the OAuth redirect (?code=...)
  (async function init() {
    if (C.APP_TITLE) {
      document.title = C.APP_TITLE;
      const h = document.getElementById("appTitle");
      if (h) h.textContent = C.APP_TITLE;
    }
    const params = new URLSearchParams(window.location.search);
    const code = params.get("code");
    if (code) {
      try { await exchangeCode(code); } catch (e) { /* ignore */ }
      window.history.replaceState({}, document.title, C.REDIRECT_URI);
    }
    updateAuthUI();
    if (idToken()) call("status");
  })();
})();
