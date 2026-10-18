import base64, json, os, sys, time, urllib.request
env = dict(l.split("=", 1) for l in open(os.path.expanduser("~/.hermes/.env")).read().splitlines() if "=" in l and not l.startswith("#"))
KEY = env.get("MODEL_ROUTER_API_KEY", "").strip().strip('"')


def ask(png, prompt, model="bonsai", max_tokens=2):
    img = base64.b64encode(open(png, "rb").read()).decode()
    body = {"model": model, "max_tokens": max_tokens, "temperature": 0, "reasoning_effort": "none",
            "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}},
                                                       {"type": "text", "text": prompt}]}]}
    t = time.time()
    r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18000/v1/chat/completions", json.dumps(body).encode(),
        {"Content-Type": "application/json", "Authorization": "Bearer " + KEY}), timeout=30)
    j = json.loads(r.read())
    return j["choices"][0]["message"].get("content") or "", time.time() - t


if __name__ == "__main__":
    print(ask(sys.argv[1], sys.argv[2], max_tokens=int(sys.argv[3]) if len(sys.argv) > 3 else 40))
