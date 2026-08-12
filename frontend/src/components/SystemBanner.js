import React, { useEffect, useState } from "react";
import { onHealth, onState, checkHealth } from "../socket";

// Global availability banner. Distinguishes three states the old UI conflated with "$0":
//   - socket closed        → we can't reach the service at all (reconnecting)
//   - backend unavailable  → socket is up but the DB / app tier is down (e.g. a backup)
//   - healthy              → no banner
// This stops a dead database from silently looking like "zero overdue / pipeline clear".
export default function SystemBanner() {
  const [health, setHealth] = useState("unknown");
  const [reason, setReason] = useState("");
  const [sockState, setSockState] = useState("connecting");

  useEffect(() => {
    const offH = onHealth(({ health: nextHealth, reason: nextReason }) => {
      setHealth(nextHealth); setReason(nextReason);
    });
    const offS = onState(setSockState);
    return () => { offH(); offS(); };
  }, []);

  // Socket down takes precedence — nothing is reachable.
  if (sockState === "closed") {
    return (
      <div className="sysbanner sysbanner-warn" role="status">
        <span className="sysbanner-dot" />
        Reconnecting to the service… live data is paused.
      </div>
    );
  }

  if (health === "unavailable") {
    return (
      <div className="sysbanner sysbanner-down" role="alert">
        <span className="sysbanner-dot" />
        <span>
          <b>Live data is temporarily unavailable.</b> The system may be under maintenance
          (for example a database backup). Figures are hidden until the connection is restored.
        </span>
        <button className="sysbanner-retry" onClick={() => checkHealth()}>Retry</button>
      </div>
    );
  }

  return null;
}
