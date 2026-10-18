import hashlib
import json
import os
import sys
import urllib.request

root = sys.argv[1]
os.makedirs(f"{root}/raster", exist_ok=True)
bad = 0
for row in json.load(open(f"{root}/sources.json")):
    path = f"{root}/raster/{row['key']}.jpg"
    if not os.path.exists(path):
        req = urllib.request.Request(row["url"], headers={"User-Agent": "entities-interaction-sim"})
        open(path, "wb").write(urllib.request.urlopen(req, timeout=60).read())
    ok = hashlib.sha256(open(path, "rb").read()).hexdigest() == row["sha256"]
    bad += not ok
    print(("ok  " if ok else "BAD ") + row["key"])
sys.exit(1 if bad else 0)
