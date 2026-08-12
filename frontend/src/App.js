import React, { useEffect, useState } from "react";
import { signIn, completeNewPassword, currentToken, signOut, decodeIdentity } from "./auth";
import { ensureSocket, setAuthToken } from "./socket";
import Overview from "./components/Overview";
import Dashboard from "./components/Dashboard";
import ControlTower from "./components/ControlTower";
import PolicyLibrary from "./components/PolicyLibrary";
import AssistantDock from "./components/AssistantDock";
import SystemBanner from "./components/SystemBanner";

export default function App() {
  const [token, setToken] = useState(null);
  const [identity, setIdentity] = useState(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [tab, setTab] = useState("overview");
  const [dockOpen, setDockOpen] = useState(true);
  const [pendingPrompt, setPendingPrompt] = useState(null);
  // First-login password change (Cognito FORCE_CHANGE_PASSWORD challenge).
  const [newPwMode, setNewPwMode] = useState(false);
  const [newPassword, setNewPassword] = useState("");
  const [newPassword2, setNewPassword2] = useState("");

  useEffect(() => {
    currentToken().then((t) => t && setToken(t));
  }, []);

  useEffect(() => {
    if (token) {
      setIdentity(decodeIdentity(token));
      setAuthToken(token);   // so $connect can verify the JWT and derive groups
      ensureSocket();
    }
  }, [token]);

  async function handleLogin(e) {
    e.preventDefault();
    setError("");
    try {
      const res = await signIn(email, password);
      if (res.status === "NEW_PASSWORD_REQUIRED") {
        // First login on an admin-created account — prompt for a permanent password.
        setNewPwMode(true);
      } else {
        setToken(res.token);
      }
    } catch (err) {
      setError(err.message || "Login failed");
    }
  }

  async function handleSetNewPassword(e) {
    e.preventDefault();
    setError("");
    if (newPassword.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    if (newPassword !== newPassword2) {
      setError("Passwords do not match.");
      return;
    }
    try {
      const res = await completeNewPassword(newPassword);
      setNewPwMode(false);
      setToken(res.token);
    } catch (err) {
      // Surfaces Cognito password-policy errors (uppercase/number/symbol, etc.).
      setError(err.message || "Could not set the new password.");
    }
  }

  function handleLogout() {
    signOut();
    setToken(null);
  }

  // Overview rows call this to hand a question to the docked assistant.
  function ask(prompt) {
    setDockOpen(true);
    setPendingPrompt(prompt);
  }

  if (!token) {
    if (newPwMode) {
      return (
        <div className="login-wrap">
          <form className="login-card" onSubmit={handleSetNewPassword}>
            <h1>Set a new password</h1>
            <p className="sub">First sign-in for {email} — choose a permanent password.</p>
            <input type="password" placeholder="New password" value={newPassword}
                   onChange={(e) => setNewPassword(e.target.value)} required autoFocus />
            <input type="password" placeholder="Confirm new password" value={newPassword2}
                   onChange={(e) => setNewPassword2(e.target.value)} required />
            <button type="submit">Set password &amp; sign in</button>
            {error && <div className="err">{error}</div>}
          </form>
        </div>
      );
    }
    return (
      <div className="login-wrap">
        <form className="login-card" onSubmit={handleLogin}>
          <h1>EBS Finance Assistant</h1>
          <p className="sub">Oracle 26ai · Receivables &amp; Payables · one pane, live</p>
          <input type="email" placeholder="Email" value={email}
                 onChange={(e) => setEmail(e.target.value)} required />
          <input type="password" placeholder="Password" value={password}
                 onChange={(e) => setPassword(e.target.value)} required />
          <button type="submit">Sign in</button>
          {error && <div className="err">{error}</div>}
        </form>
      </div>
    );
  }

  return (
    <div className={"app " + (dockOpen ? "dock-is-open" : "")}>
      <header className="topbar">
        <div className="brand">EBS Finance Assistant <span>26ai</span></div>
        <nav>
          <button className={tab === "overview" ? "active" : ""} onClick={() => setTab("overview")}>Overview</button>
          <button className={tab === "dashboard" ? "active" : ""} onClick={() => setTab("dashboard")}>Collections</button>
          <button className={tab === "payables" ? "active" : ""} onClick={() => setTab("payables")}>AP Control Tower</button>
          <button className={tab === "policy" ? "active" : ""} onClick={() => setTab("policy")}>Policy</button>
        </nav>
        <div className="user-box">
          {identity && (
            <span className="who" title={identity.email}>
              <span className="who-name">{identity.name || identity.email}</span>
              {identity.role && <span className="who-role">{identity.role}</span>}
            </span>
          )}
          <button className="logout" onClick={handleLogout}>Sign out</button>
        </div>
      </header>

      <SystemBanner />

      <div className="shell">
        <main className={(tab === "overview" || tab === "payables" || tab === "policy") ? "wide" : ""}>
          {tab === "overview" && <Overview onDrill={setTab} onAsk={ask} />}
          {tab === "dashboard" && <Dashboard onAsk={ask} />}
          {tab === "payables" && <ControlTower onAsk={ask} />}
          {tab === "policy" && <PolicyLibrary />}
        </main>

        <AssistantDock
          open={dockOpen}
          onToggle={() => setDockOpen((v) => !v)}
          pendingPrompt={pendingPrompt}
          onConsumed={() => setPendingPrompt(null)}
          identity={identity}
        />
      </div>
    </div>
  );
}
