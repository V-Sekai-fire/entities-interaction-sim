# Frontier learning (RFD 2309) for the decider-style sim player. Bonsai weights stay frozen; only the domain changes.
# Level = task template + attributes (world seed, start distance, start yaw offset). Problem = one level played n times
# (each try reshuffles the options). Regret 1[s>=1] - s/n picks what to replay; a domain revision is kept only when it
# raises success on the problem it was tried on.
#   python sim_frontier.py --port 8792 --minutes 40 [--n 3]
import json, os, pathlib, random, sys, threading, time
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from bonsai import ask
from sim_decider import BANNED, VERB, Sim, changed, fail_early, pick, render, where

BASE = {"name": "base", "walk_m": 0.8, "turn_deg": 45, "look_deg": 20, "perceive": "floor", "turn_around": False,
        "goal_in_context": False, "tick": 1.0}
REVISIONS = [
    {"name": "short steps", "walk_m": 0.4},
    {"name": "small turns", "turn_deg": 30},
    {"name": "turn around option", "turn_around": True},
    {"name": "no perception question", "perceive": None},
    {"name": "wall question", "perceive": "wall"},
    {"name": "goal in context", "goal_in_context": True},
    {"name": "fast tick", "tick": 0.5},
]
PERCEIVE = {"floor": ("Is there open floor straight ahead that you could walk onto?", "Open floor straight ahead"),
            "wall": ("Is there a wall or a closed door right in front of you?", "Wall or closed door right in front")}
LEVELS = {  # name: (goal, success key, reset flags, start(layout, d) -> (x, z), distances near/far, seconds)
    "door":   ("open the door", "door_open", {}, lambda L, d: (L["door_x"], -3.0 + d), (1.0, 2.2), 30),
    "room_b": ("walk through the doorway into the next room", "in_room_b", {"door_open": True},
               lambda L, d: (L["door_x"], -3.0 + d), (1.2, 2.6), 30),
    "button": ("press the button", "button", {"door_open": True}, lambda L, d: (L["button"][0], L["button"][1] + d), (0.9, 2.0), 30),
    "lift":   ("walk into the lift", "in_lift", {"door_open": True, "gate_open": True}, lambda L, d: (L["lift_x"], -9.0 + d), (1.3, 2.6), 30),
    "full":   ("get into the lift at the far end of the next room", "in_lift", {}, lambda L, d: (0.0, 1.8), (0.0, 0.0), 90),
}
SEEDS = [7, 11, 23, 42, 5, 13]
YAWS = [0, 45, -45, 90]


def moves(dom):
    m = ["turn left", "turn right", "walk forward", "look down", "look up", "crouch or stand up"]
    return m + (["turn around"] if dom["turn_around"] else [])


def options(dom, points, rng):
    opts = [(m, ("move", m)) for m in moves(dom)]
    near = sorted((p for p in points if not p["kind"].startswith("floor")), key=lambda p: p["dist"])
    for p in near[:10 - len(opts)]:
        opts.append((f"{VERB[p['kind']]} {where(p['px'])}", ("act", p["id"])))
    rng.shuffle(opts)
    return {chr(65 + i): o for i, o in enumerate(opts)}


def decide(dom, goal, png, points, rng, model):
    ctx, dt = "The image is your view in a VR game.", 0.0
    if dom["perceive"]:
        q, label = PERCEIVE[dom["perceive"]]
        yn = dict(zip("AB", rng.sample([("yes", None), ("no", None)], 2)))
        r0, d0 = ask(png, render(q, yn), model=model); dt += d0
        ctx += f" {label}: {yn.get(pick(r0, yn), ('unknown',))[0]}."
    opts = options(dom, points, rng)
    if dom["goal_in_context"]:
        prompt = render("Which action do you take next?", opts, ctx + f" Your goal: {goal}.")
    else:
        prompt = render(f"Which action brings you closer to this goal: {goal}?", opts, ctx)
    assert not any(b in prompt.lower() for b in BANNED), "prompt leaks consequences"
    r1, d1 = ask(png, prompt, model=model)
    text, op = opts.get(pick(r1, opts), ("no move", None))
    return {"choice": text, "op": op, "reply_s": round(dt + d1, 2), "prompt": prompt}


def apply(sim, dom, op):
    kind, v = op
    if kind == "act":
        return sim(cmd="act", id=v).get("result")
    if v == "crouch or stand up":
        return sim(cmd="crouch", on=not sim(cmd="state")["progress"]["crouched"]).get("ok")
    return {"turn left": lambda: sim(cmd="turn", deg=dom["turn_deg"]), "turn right": lambda: sim(cmd="turn", deg=-dom["turn_deg"]),
            "turn around": lambda: sim(cmd="turn", deg=180), "walk forward": lambda: sim(cmd="walk", m=dom["walk_m"]),
            "look down": lambda: sim(cmd="look", deg=-dom["look_deg"]), "look up": lambda: sim(cmd="look", deg=dom["look_deg"])}[v]().get("ok")


def play(sim, dom, level, try_i, model, log):
    """One real-time try. Returns 1 on success, 0 otherwise."""
    name, seed, dist_i, yaw = level
    goal, key, flags, start, dists, seconds = LEVELS[name]
    probe = sim(cmd="reset", seed=seed)
    x, z = start(probe["layout"], dists[dist_i])
    sim(cmd="reset", seed=seed, start=[x, z, yaw, -10.0], **flags)
    rng = random.Random(hash((name, seed, dist_i, yaw, try_i)) & 0xffffffff)
    pending, worker, hist, why, ok = {}, None, [], None, 0
    end = time.time() + seconds
    while time.time() < end and not why:
        t0 = time.time()
        if worker is not None and not worker.is_alive():
            d = pending.pop("d"); worker = None
            if d.get("op"):
                apply(sim, dom, d["op"]); hist.append((d["image"], d["choice"])); why = fail_early(hist)
            log.write(json.dumps({"level": level, "try": try_i, "dom": dom["name"], "image": d["image"], "choice": d["choice"],
                                  "reply_s": d.get("reply_s"), "error": d.get("error")}) + "\n")
        shot = sim(cmd="shot")
        if shot["progress"].get(key):
            ok = 1; break
        if worker is None:
            def run(png=shot["image"], pts=shot["points"]):
                try:
                    d = decide(dom, goal, png, pts, rng, model)
                except Exception as e:
                    d = {"error": str(e), "choice": "endpoint error"}
                d["image"] = png; pending["d"] = d
            worker = threading.Thread(target=run); worker.start()
        time.sleep(max(0.0, dom["tick"] - (time.time() - t0)))
    if worker is not None:
        worker.join()
    log.write(json.dumps({"level": level, "try": try_i, "dom": dom["name"], "success": ok, "decisions": len(hist), "stop": why}) + "\n")
    log.flush()
    return ok


def rate(sim, dom, level, n, model, log):
    return sum(play(sim, dom, level, i, model, log) for i in range(n)) / n


def main():
    a = sys.argv
    arg = lambda k, d: type(d)(a[a.index(k) + 1]) if k in a else d
    port, minutes, n = arg("--port", 8792), arg("--minutes", 40.0), arg("--n", 3)
    model = os.environ.get("DECIDER_MODEL", "bonsai-desk-4090")
    run = HERE / "run" / "frontier_sim"; run.mkdir(parents=True, exist_ok=True)
    log = open(run / "tries.jsonl", "a")
    sim = Sim(port)
    rng = random.Random(20261017)
    dom = dict(BASE); kept, buffer, tried, steps = [], {}, {}, []
    end = time.time() + minutes * 60
    t = 0
    while time.time() < end:
        t += 1
        if not buffer or rng.random() < 0.5:
            name = rng.choice(list(LEVELS))
            level = (name, rng.choice(SEEDS), rng.randrange(2) if name != "full" else 0, rng.choice(YAWS) if name != "full" else 0)
            how = "explore"
        else:
            level = max(buffer, key=lambda k: (buffer[k], rng.random())); how = "replay"
        r = rate(sim, dom, level, n, model, log)
        buffer[level] = (1.0 if r > 0 else 0.0) - r
        row = {"step": t, "how": how, "level": level, "dom": dom["name"], "rate": r, "regret": buffer[level]}
        if r < 1.0:
            left = [v for v in REVISIONS if v["name"] not in tried.setdefault(level, []) and v["name"] not in dom["name"]]
            if left:
                cand_rev = left[0]; tried[level].append(cand_rev["name"])
                cand = dict(dom, **cand_rev); cand["name"] = dom["name"] + " + " + cand_rev["name"] if dom["name"] != "base" else cand_rev["name"]
                cr = rate(sim, cand, level, n, model, log)
                row.update({"trial": cand_rev["name"], "trial_rate": cr, "kept": cr > r})
                if cr > r:
                    dom = cand; kept.append({"step": t, "revision": cand_rev["name"], "level": level, "from": r, "to": cr})
                    buffer[level] = (1.0 if cr > 0 else 0.0) - cr
        steps.append(row)
        print(json.dumps(row), flush=True)
        json.dump({"domain": dom, "kept": kept, "steps": steps}, open(run / "state.json", "w"), indent=1)
    print("FINAL domain:", dom["name"], "kept:", kept)


if __name__ == "__main__":
    main()
