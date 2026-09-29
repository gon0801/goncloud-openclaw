"""Observaciones del director para `corrida.sh reconciliar --observations`.
Lo mismo que reconciliar_observar (tmux, HEAD, sucio, commits por delante),
mas lo que solo el director ve: el inspect real del adaptador sobre la sesion
vigente del carril, el predecesor y sus hijos, y el candidato del selector.
Uso: observar.py <select.json> <sesion-sucesor> <exhausted,csv>"""
import json, os, subprocess, sys

ID = os.environ["ID"]
reg = json.load(open(os.path.expanduser(f"~/.local/state/corridas/{ID}/registro.json")))
wreg = json.load(open(os.environ["CORRIDA_WORKERS_REGISTRY"]))
sel_file, next_session, exhausted = sys.argv[1], sys.argv[2], sys.argv[3]

def git(wt, *a):
    p = subprocess.run(["git", "-C", wt, *a], capture_output=True, text=True, timeout=20)
    return p.stdout.strip() if p.returncode == 0 else None

tm = subprocess.run(["tmux", "ls", "-F", "#{session_name}"], capture_output=True, text=True)
sessions = [l for l in tm.stdout.splitlines() if l]
lane = reg["lanes"][0]
wt = lane["worktree"]
sel = json.load(open(sel_file))
ses = lane.get("session") or ""
o = {
    "worktree_exists": os.path.isdir(wt),
    "head": git(wt, "rev-parse", "HEAD"),
    "dirty": bool(git(wt, "status", "--porcelain")),
    "commits_ahead": int(git(wt, "rev-list", "--count", lane["base_remote_sha"] + "..HEAD")),
    "remote_branch": False,
    "session_alive": ses in sessions,
    "predecessor_alive": False,
    "children_writing": False,
    "pr": None, "merge": None, "deployed": None, "canary": None,
}
if ses in sessions:
    p = subprocess.run(["bash", os.path.expanduser("~/bin/corrida.sh"), "adaptador", "inspect",
                        ID, lane["id"], lane["worker"], ses], capture_output=True, text=True)
    o["inspect"] = p.stdout.strip()
obs = {
    "registry": {"workers": [w["id"] for w in wreg["workers"]]},
    "tmux": {"sessions": sessions},
    "lanes": {lane["id"]: o},
    "candidates": {
        "exhausted": [x for x in exhausted.split(",") if x],
        "next": {"worker": sel["winner"], "session": next_session} if sel.get("winner") else None,
    },
}
if next_session in sessions:
    o["successor_session"] = next_session
    o["successor"] = {"worker": sel["winner"], "session": next_session}
print(json.dumps(obs, sort_keys=True))
