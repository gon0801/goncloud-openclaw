import glob, json, os, sqlite3, statistics, sys
from collections import defaultdict
from compression import zstd

COPY = os.path.expanduser("~/respaldos/claw-mini-copia-20261009-1255")


def ro(path):
    return sqlite3.connect(f"file:{path}?immutable=1", uri=True)


def pctl(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo))


def summary(xs):
    if not xs:
        return {"n": 0}
    return {"n": len(xs), "median": pctl(xs, 0.5), "p95": pctl(xs, 0.95), "max": max(xs)}


def assistant_calls(lines, session_key, agent, source, session_id):
    for raw in lines:
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if d.get("type") != "message":
            continue
        m = d.get("message") or {}
        if m.get("role") != "assistant" or not isinstance(m.get("usage"), dict):
            continue
        u = m["usage"]
        run_id = (m.get("__openclaw") or {}).get("runId")
        yield {
            "msgId": d.get("id"),
            "agent": agent,
            "sessionKey": session_key,
            "sessionId": session_id,
            "source": source,
            "runId": run_id,
            "ts": d.get("timestamp"),
            "api": m.get("api"),
            "provider": m.get("provider"),
            "model": m.get("model"),
            "stopReason": m.get("stopReason"),
            "input": int(u.get("input") or 0),
            "output": int(u.get("output") or 0),
            "cacheRead": int(u.get("cacheRead") or 0),
            "cacheWrite": int(u.get("cacheWrite") or 0),
        }


calls = {}
for path in sorted(glob.glob(os.path.join(COPY, "agent-*.sqlite"))):
    agent = os.path.basename(path)[len("agent-"):-len(".sqlite")]
    con = ro(path)
    keys = dict(con.execute("select current_session_id, session_key from session_nodes"))
    traj = dict(
        con.execute(
            "select session_id, json_extract(event_json,'$.sessionKey') from trajectory_runtime_events "
            "where json_extract(event_json,'$.sessionKey') is not null group by session_id"
        )
    )
    by_session = defaultdict(list)
    for sid, ej, ez in con.execute(
        "select session_id, event_json, event_zstd from transcript_events order by session_id, seq"
    ):
        by_session[sid].append(ej if ej is not None else zstd.decompress(ez).decode())
    for sid, lines in by_session.items():
        sk = keys.get(sid) or traj.get(sid)
        for c in assistant_calls(lines, sk, agent, "transcript_events", sid):
            calls.setdefault((agent, c["msgId"]), c)
    for sid, sk, blob in con.execute(
        "select session_id, session_key, archive_blob from session_transcript_archives"
    ):
        lines = zstd.decompress(blob).decode().splitlines()
        for c in assistant_calls(lines, sk, agent, "session_transcript_archives", sid):
            calls.setdefault((agent, c["msgId"]), c)

main = ro(os.path.join(COPY, "openclaw.sqlite"))
runs = {}
for run_id, child, requester, controller, created, payload in main.execute(
    "select run_id, child_session_key, requester_session_key, controller_session_key, created_at, payload_json from subagent_runs"
):
    p = json.loads(payload)
    ex = p.get("execution") or {}
    runs[run_id] = {
        "child": child,
        "requester": requester,
        "created": created,
        "start": ex.get("startedAt") or created,
        "end": ex.get("endedAt"),
        "status": (ex.get("outcome") or {}).get("status"),
        "model": p.get("model"),
    }

sub_calls = [c for c in calls.values() if c["sessionKey"] and ":subagent:" in c["sessionKey"]]
per_run = defaultdict(list)
for c in sub_calls:
    per_run[(c["sessionKey"], c["runId"])].append(c)


def run_metrics(cs):
    prompts = [c["input"] + c["cacheRead"] + c["cacheWrite"] for c in cs]
    outs = [c["output"] for c in cs]
    return {
        "calls": len(cs),
        "input": sum(prompts),
        "output": sum(outs),
        "cacheRead": sum(c["cacheRead"] for c in cs),
        "maxContext": max(prompts),
        "maxOutputPerCall": max(outs),
        "tree": sum(prompts) + sum(outs),
    }


metrics = {k: run_metrics(v) for k, v in per_run.items()}
ts = sorted(c["ts"] for c in sub_calls if c["ts"])
fields = ["calls", "input", "output", "cacheRead", "maxContext", "maxOutputPerCall", "tree"]
out = {
    "allAssistantCalls": len(calls),
    "subagentCalls": len(sub_calls),
    "subagentRunsWithUsage": len(metrics),
    "dateRange": [ts[0], ts[-1]] if ts else None,
    "perRun": {f: summary([m[f] for m in metrics.values()]) for f in fields},
    "zeroUsageCalls": sum(1 for c in sub_calls if c["input"] + c["cacheRead"] + c["output"] == 0),
    "apiModel": {},
    "byAgent": {},
}
for c in sub_calls:
    k = f'{c["api"]}|{c["provider"]}/{c["model"]}'
    out["apiModel"][k] = out["apiModel"].get(k, 0) + 1
by_agent = defaultdict(list)
for (sk, rid), m in metrics.items():
    by_agent[sk.split(":")[1]].append(m)
for a, ms in sorted(by_agent.items()):
    out["byAgent"][a] = {f: summary([m[f] for m in ms]) for f in ["calls", "maxContext", "tree"]}

# Trees from the subagent registry: parent run = run whose child session is this run's requester.
child_to_runs = defaultdict(list)
for rid, r in runs.items():
    child_to_runs[r["child"]].append(rid)


def parent_of(rid):
    r = runs[rid]
    if ":subagent:" not in (r["requester"] or ""):
        return None
    cands = child_to_runs.get(r["requester"], [])
    cands = [c for c in cands if runs[c]["start"] <= r["created"]]
    return max(cands, key=lambda c: runs[c]["start"]) if cands else "orphan"


parents = {rid: parent_of(rid) for rid in runs}
roots = [rid for rid, p in parents.items() if p is None]
kids = defaultdict(list)
for rid, p in parents.items():
    if p not in (None, "orphan"):
        kids[p].append(rid)


def descend(rid, depth=0):
    yield rid, depth
    for k in kids[rid]:
        yield from descend(k, depth + 1)


run_usage = {rid: metrics.get((runs[rid]["child"], rid)) for rid in runs}
trees = []
for root in roots:
    members = list(descend(root))
    ids = [m for m, _ in members]
    complete = all(run_usage[i] for i in ids)
    events = []
    for i in ids:
        r = runs[i]
        if r["end"]:
            events += [(r["start"], 1), (r["end"], -1)]
    cur = peak = 0
    for _, delta in sorted(events, key=lambda e: (e[0], e[1])):
        cur += delta
        peak = max(peak, cur)
    t = {
        "root": root,
        "size": len(ids),
        "children": len(ids) - 1,
        "depth": max(d for _, d in members),
        "concurrent": peak,
        "complete": complete,
    }
    if complete:
        us = [run_usage[i] for i in ids]
        t.update(
            calls=sum(u["calls"] for u in us),
            input=sum(u["input"] for u in us),
            output=sum(u["output"] for u in us),
            cacheRead=sum(u["cacheRead"] for u in us),
            maxContext=max(u["maxContext"] for u in us),
            tree=sum(u["tree"] for u in us),
        )
    trees.append(t)

out["registry"] = {
    "runs": len(runs),
    "dateRange": [min(r["created"] for r in runs.values()), max(r["created"] for r in runs.values())],
    "roots": len(roots),
    "orphans": sum(1 for p in parents.values() if p == "orphan"),
    "nested": sum(1 for p in parents.values() if p not in (None, "orphan")),
    "runsWithUsage": sum(1 for v in run_usage.values() if v),
    "treeShape": {f: summary([t[f] for t in trees]) for f in ["children", "depth", "concurrent"]},
    "treesComplete": sum(1 for t in trees if t["complete"]),
    "treeUsage": {
        f: summary([t[f] for t in trees if t["complete"]])
        for f in ["calls", "input", "output", "cacheRead", "maxContext", "tree"]
    },
    "nestedTrees": [
        {k: t.get(k) for k in ["size", "depth", "concurrent", "complete", "calls", "tree"]}
        for t in trees
        if t["size"] > 1
    ],
}

# Native concurrency: overlapping subagent runs under one requester session.
by_req = defaultdict(list)
for r in runs.values():
    if r["end"]:
        by_req[r["requester"]] += [(r["start"], 1), (r["end"], -1)]
peaks = {}
for req, ev in by_req.items():
    cur = peak = 0
    for _, d in sorted(ev):
        cur += d
        peak = max(peak, cur)
    peaks[req] = peak
top = sorted(peaks.items(), key=lambda kv: -kv[1])[:5]
out["concurrencyPerRequester"] = {"max": max(peaks.values()), "top": top}
json.dump(out, sys.stdout, indent=1, default=str)

# --- second pass: anomaly filter, per-call distribution, nested trees by session key
WINDOW = 1048576
anom = [c for c in sub_calls if c["input"] + c["cacheRead"] + c["cacheWrite"] > WINDOW]
anom_keys = {(c["sessionKey"], c["runId"]) for c in anom}
clean = {k: v for k, v in metrics.items() if k not in anom_keys}
extra = {
    "anomalousCalls": [
        {k: c[k] for k in ["agent", "ts", "api", "provider", "model", "input", "cacheRead", "output"]}
        for c in anom
    ],
    "perRunExcludingAnomalousRuns": {f: summary([m[f] for m in clean.values()]) for f in fields},
    "perCall": {
        "prompt": summary([c["input"] + c["cacheRead"] + c["cacheWrite"] for c in sub_calls if c not in anom]),
        "output": summary([c["output"] for c in sub_calls]),
    },
}
session_calls = defaultdict(list)
for c in sub_calls:
    session_calls[c["sessionKey"]].append(c)
nested = defaultdict(list)
for rid, r in runs.items():
    if ":subagent:" in (r["requester"] or ""):
        nested[r["requester"]].append(rid)
tree_rows = []
for parent, kids_ in nested.items():
    ev = []
    for k in kids_:
        r = runs[k]
        ev += [(r["start"], 1), (r["end"], -1)]
    cur = peak = 0
    for _, d in sorted(ev):
        cur += d
        peak = max(peak, cur)
    member_calls = list(session_calls.get(parent, []))
    have = [bool(session_calls.get(parent))] + [bool(metrics.get((runs[k]["child"], k))) for k in kids_]
    for k in kids_:
        member_calls += per_run.get((runs[k]["child"], k), [])
    m = run_metrics(member_calls) if member_calls else None
    tree_rows.append({
        "rootSession": parent, "children": len(kids_), "depth": 1,
        "concurrentChildren": peak, "concurrentWithRoot": peak + 1,
        "usageComplete": all(have), "usage": m,
    })
extra["nestedTreesBySession"] = tree_rows
json.dump(extra, open("medicion-extra.json", "w"), indent=1, default=str)
