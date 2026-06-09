#!/usr/bin/env python3
"""Reference probe: compute the SAME numbers the Swift menu-bar app should show.
Use this as ground truth to validate AICreditsBar.app output. Read-only."""
import json, glob, os, time, sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
now = time.time()

def fmt_reset(ts):
    if not ts: return "?"
    d = ts - now
    if d <= 0: return "RESET (window already refilled)"
    if d < 3600: return f"in {d/60:.0f}m"
    if d < 86400: return f"in {d/3600:.1f}h"
    return f"in {d/86400:.1f}d"

# ---------- CODEX (official) ----------
def codex():
    base = os.path.join(HOME, ".codex", "sessions")
    files = glob.glob(os.path.join(base, "*", "*", "*", "rollout-*.jsonl"))
    files.sort(key=os.path.getmtime, reverse=True)
    best_ts, best = None, None
    for f in files[:12]:
        try:
            for line in open(f, encoding="utf-8", errors="ignore"):
                if '"rate_limits"' not in line:
                    continue
                o = json.loads(line)
                rl = (o.get("payload", {}) or {}).get("rate_limits") or o.get("rate_limits")
                if not rl:
                    # dig
                    def dig(d):
                        if isinstance(d, dict):
                            if "primary" in d and isinstance(d["primary"], dict) and "used_percent" in d["primary"]:
                                return d
                            for v in d.values():
                                r = dig(v)
                                if r: return r
                        if isinstance(d, list):
                            for v in d:
                                r = dig(v)
                                if r: return r
                        return None
                    rl = dig(o)
                if rl and "primary" in rl:
                    ts = o.get("timestamp", "")
                    if best_ts is None or ts > best_ts:
                        best_ts, best = ts, rl
        except Exception:
            continue
    if not best:
        return {"ok": False, "msg": "no rate_limits found (run codex once)"}
    p = best.get("primary") or {}
    s = best.get("secondary") or {}
    return {
        "ok": True, "as_of": best_ts, "plan": best.get("plan_type"),
        "p_remaining": round(100 - p.get("used_percent", 0)), "p_reset": fmt_reset(p.get("resets_at")),
        "p_stale": (p.get("resets_at", 0) or 0) < now,
        "w_remaining": round(100 - s.get("used_percent", 0)) if s else None,
        "w_reset": fmt_reset(s.get("resets_at")) if s else None,
    }

# ---------- CLAUDE (5h block token estimate, ccusage-style) ----------
def claude(budget=None):
    files = glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl"))
    files = [f for f in files if "/subagents/" not in f]
    events = []  # (epoch, total_tokens, dedup_key)
    seen = set()
    for f in files:
        try:
            mt = os.path.getmtime(f)
            if now - mt > 5*3600 + 600:  # only files possibly in the active block window
                pass  # still scan; cheap enough but we could skip. keep for accuracy of block start
        except Exception:
            pass
        try:
            for line in open(f, encoding="utf-8", errors="ignore"):
                if '"usage"' not in line or '"assistant"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                msg = o.get("message", {})
                u = msg.get("usage") if isinstance(msg, dict) else None
                if not u:
                    continue
                ts = o.get("timestamp")
                if not ts:
                    continue
                try:
                    ep = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception:
                    continue
                key = (msg.get("id"), o.get("requestId"))
                if key in seen:
                    continue
                seen.add(key)
                tot = (u.get("input_tokens", 0) + u.get("output_tokens", 0)
                       + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0))
                events.append((ep, tot))
        except Exception:
            continue
    if not events:
        return {"ok": False, "msg": "no claude usage found"}
    events.sort()
    # build 5h blocks: new block if gap>5h or exceeds 5h from block start (floored to hour)
    FIVE = 5*3600
    blocks = []
    cur_start = None; cur_tokens = 0; last = None
    for ep, tot in events:
        start_floor = ep - (ep % 3600)
        if cur_start is None:
            cur_start = start_floor; cur_tokens = 0; last = ep
        elif ep - last > FIVE or ep - cur_start >= FIVE:
            blocks.append((cur_start, cur_tokens, last))
            cur_start = start_floor; cur_tokens = 0
        cur_tokens += tot; last = ep
    if cur_start is not None:
        blocks.append((cur_start, cur_tokens, last))
    start, tokens, last = blocks[-1]
    reset = start + FIVE
    active = now < reset
    res = {"ok": True, "tokens": tokens, "reset": fmt_reset(reset), "active": active,
           "block_start": datetime.fromtimestamp(start).strftime("%H:%M")}
    if budget:
        res["remaining"] = max(0, round(100 * (1 - tokens / budget)))
        res["budget"] = budget
    return res

# ---------- GEMINI ----------
def gemini():
    gdir = os.path.join(HOME, ".gemini")
    if not os.path.isdir(gdir):
        return {"ok": False, "installed": False, "msg": "not installed (~/.gemini absent)"}
    files = os.listdir(gdir)
    return {"ok": True, "installed": True, "files": files}

if __name__ == "__main__":
    out = {"codex": codex(), "claude": claude(budget=220_000_000), "gemini": gemini()}
    print(json.dumps(out, indent=2, ensure_ascii=False))
