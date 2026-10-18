# Bonsai 2 plays the interaction sim in decider style (upstream Mapika/decider prompt shape), in real time.
#   python sim_decider.py --port 8791 --seed 7 --seconds 90 [--tick 1.0]
# Every call sends the current screenshot as an image. Context = the image; one-sentence typed questions;
# options shuffled every call; at most 10; one letter at temperature 0. The next image is the only feedback.
import hashlib, json, os, pathlib, random, socket, string, sys, threading, time
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from bonsai import ask

BANNED = ["dies", "reachable", "safe", "dead end", "opens", "unlocks", "leads to", "correct", "wins", " m away", "low ceiling", "steps away"]
MOVES = ["turn left", "turn right", "walk forward", "look down", "look up", "crouch or stand up"]
VERB = {"door handle": "grip the door handle", "drawer pull": "grip the drawer handle", "button": "press the button",
        "item": "take the item", "ladder rung": "grip the ladder"}
GOAL = "get into the lift at the far end of the next room"


class Sim:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=120)
        self.f = self.s.makefile("rw")

    def __call__(self, **req):
        self.f.write(json.dumps(req) + "\n"); self.f.flush()
        return json.loads(self.f.readline())


def where(px):
    return ["on the left", "in the middle", "on the right"][min(2, int(px[0] / (568 / 3)))]


def options(points, rng):
    opts = [(m, ("move", m)) for m in MOVES]
    near = [p for p in points if not p["kind"].startswith("floor")]
    near.sort(key=lambda p: p["dist"])
    for p in near[:10 - len(MOVES)]:
        opts.append((f"{VERB[p['kind']]} {where(p['px'])}", ("act", p["id"])))
    rng.shuffle(opts)
    return {string.ascii_uppercase[i]: o for i, o in enumerate(opts)}


def render(question, opts, context="The image is your view in a VR game."):
    return (f"Context:\n{context}\n\nQuestion: {question}\nOptions:\n" +
            "\n".join(f"({k}) {t}" for k, (t, _) in opts.items()) + "\nAnswer: (")


def pick(reply, opts):
    return next((c for c in reply.strip().upper() if c in opts), None)


def decide(png, points, rng, model):
    """Two typed calls on the same image: a yes/no perception question, then the action."""
    yn = {"A": ("yes", None), "B": ("no", None)}
    if rng.random() < 0.5:
        yn = {"A": ("no", None), "B": ("yes", None)}
    r0, d0 = ask(png, render("Is there open floor straight ahead that you could walk onto?", yn), model=model)
    floor = yn.get(pick(r0, yn), ("unknown", None))[0]
    opts = options(points, rng)
    prompt = render(f"Which action brings you closer to this goal: {GOAL}?", opts,
                    f"The image is your view in a VR game. Open floor straight ahead: {floor}.")
    assert not any(b in prompt.lower() for b in BANNED), "prompt leaks consequences"
    r1, d1 = ask(png, prompt, model=model)
    letter = pick(r1, opts)
    text, op = opts.get(letter, ("no move", None))
    return {"floor": floor, "prompt": prompt, "reply": r1, "letter": letter, "choice": text, "op": op, "reply_s": round(d0 + d1, 2)}


def apply(sim, op):
    kind, v = op
    if kind == "act":
        return sim(cmd="act", id=v).get("result")
    if v == "crouch or stand up":
        st = sim(cmd="state")["progress"]
        return sim(cmd="crouch", on=not st["crouched"]).get("ok")
    return {"turn left": lambda: sim(cmd="turn", deg=45), "turn right": lambda: sim(cmd="turn", deg=-45),
            "walk forward": lambda: sim(cmd="walk", m=0.8), "look down": lambda: sim(cmd="look", deg=-20),
            "look up": lambda: sim(cmd="look", deg=20)}[v]().get("ok")


def frame(png):
    from PIL import Image
    return Image.open(png).convert("L").resize((64, 64))


def changed(a, b):
    from PIL import ImageChops, ImageStat
    return ImageStat.Stat(ImageChops.difference(frame(a), frame(b))).mean[0] > 2.0


def fail_early(hist):
    """hist: (png the decision saw, option text) per applied decision."""
    if len(hist) >= 4 and len({t for _, t in hist[-4:]}) == 1 and not any(changed(hist[i][0], hist[i + 1][0]) for i in range(-4, -1)):
        return f"same choice {hist[-1][1]!r} 4 times and the view stopped changing"
    last6 = [t for _, t in hist[-6:]]
    if len(last6) == 6 and set(last6) <= {"turn left", "turn right"} and all(last6[i] != last6[i + 1] for i in range(5)):
        return "turning left and right back and forth 6 times"
    if len(hist) >= 5 and not any(changed(hist[i][0], hist[i + 1][0]) for i in range(-5, -1)):
        return "view did not change over the last 4 decisions"
    return None


MILESTONES = ["door_open", "in_room_b", "button", "in_lift"]


def main():
    a = sys.argv
    arg = lambda k, d: type(d)(a[a.index(k) + 1]) if k in a else d
    port, seed, seconds, tick = arg("--port", 8791), arg("--seed", 7), arg("--seconds", 90.0), arg("--tick", 1.0)
    log_path = pathlib.Path(arg("--log", str(HERE / "run" / "sim_decider.jsonl")))
    model = os.environ.get("DECIDER_MODEL", "bonsai-desk-3090")
    rng = random.Random(seed)
    sim = Sim(port)
    if "progress" not in sim(cmd="reset", seed=seed):
        sys.exit(f"port {port} is not the interaction sim")
    log = open(log_path, "w")
    pending = {}
    worker = None
    hist, reached, n_tick, idle = [], set(), 0, 0
    end = time.time() + seconds
    zmin = 99.0
    why = None
    while time.time() < end and not why:
        t0 = time.time(); n_tick += 1
        if worker is not None and not worker.is_alive():
            d = pending.pop("d", None); worker = None
            if d and d["op"]:
                d["result"] = apply(sim, d["op"])
                hist.append((d["image"], d["choice"]))
                why = fail_early(hist)
            if d:
                d.pop("op")
                log.write(json.dumps(d) + "\n"); log.flush()
                print(f"t{n_tick:>3} floor ahead: {d['floor']:<7} ({d['letter']}) {d['choice']} [{d['reply_s']}s]", flush=True)
        elif worker is not None:
            idle += 1
        shot = sim(cmd="shot")
        prog = shot["progress"]
        reached |= {m for m in MILESTONES if prog.get(m)}
        zmin = min(zmin, prog["pos"][2])
        if prog.get("in_lift"):
            print("GOAL"); break
        if worker is None:
            png = shot["image"]
            def run(png=png, pts=shot["points"], prog=prog):
                try:
                    d = decide(png, pts, rng, model)
                except Exception as e:
                    d = {"error": str(e), "op": None, "floor": "-", "letter": None, "choice": "endpoint error", "reply_s": 0}
                d.update({"image": png, "sha256": hashlib.sha256(open(png, "rb").read()).hexdigest(), "progress": prog})
                pending["d"] = d
            worker = threading.Thread(target=run); worker.start()
        time.sleep(max(0.0, tick - (time.time() - t0)))
    if why:
        print("FAIL EARLY:", why); log.write(json.dumps({"fail_early": why}) + "\n")
    end_p = sim(cmd="state")["progress"]
    reached |= {m for m in MILESTONES if end_p.get(m)}
    summ = {"seed": seed, "milestones": [m for m in MILESTONES if m in reached], "decisions": len(hist),
            "ticks": n_tick, "ticks_waiting_for_model": idle, "min_z": zmin}
    log.write(json.dumps({"summary": summ}) + "\n")
    print("summary:", summ)


if __name__ == "__main__" and "--self-test" in sys.argv:
    p1, p2 = sys.argv[sys.argv.index("--self-test") + 1:][:2]
    assert fail_early([(p1, "walk forward")] * 3 + [(p2, "walk forward")]) is None
    assert fail_early([(p1, "walk forward")] * 4) is not None, "planted: repeat with frozen view must stop"
    assert fail_early([(p1, t) for t in ["turn left", "turn right"] * 3]) is not None, "planted: flapping must stop"
    pts = [{"id": i, "kind": k, "px": [100 * i, 300], "dist": 1.0 + i} for i, k in enumerate(["door handle", "button", "item", "drawer pull", "ladder rung", "floor spot"])]
    o = options(pts, random.Random(1))
    assert len(o) <= 10 and not any(t.startswith("walk to") for t, _ in o.values()), "no floor-grid options, at most 10"
    p = render("Which action?", o)
    assert not any(b in p.lower() for b in BANNED), "clean prompt must pass"
    assert any(b in "grip the door handle, 1.2 m away" for b in BANNED), "planted: a distance must be caught"
    orders = {tuple(t for t, _ in options(pts, random.Random(s)).values()) for s in range(5)}
    assert len(orders) > 1, "options must be shuffled"
    print("self-test ok"); sys.exit(0)
if __name__ == "__main__":
    main()
