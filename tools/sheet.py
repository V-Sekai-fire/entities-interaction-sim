import json
import sys
from collections import Counter
from PIL import Image, ImageDraw

out = sys.argv[1] if len(sys.argv) > 1 else "out"
c = json.load(open(f"{out}/annotations.json"))
names = {x["id"]: x["name"] for x in c["categories"]}
print(Counter(names[a["category_id"]] for a in c["annotations"]))
col = {1: (255, 60, 60), 2: (60, 200, 255), 3: (255, 220, 0), 4: (80, 255, 80), 5: (255, 255, 255), 6: (255, 120, 255)}
by = {}
for a in c["annotations"]:
    by.setdefault(a["image_id"], []).append(a)
tiles = []
for im in c["images"]:
    img = Image.open(f"{out}/{im['file_name']}").convert("RGB")
    d = ImageDraw.Draw(img)
    for a in by.get(im["id"], []):
        k = a["keypoints"]
        cl = col[a["category_id"]]
        if a["category_id"] != 5:
            x, y, w, h = a["bbox"]
            d.rectangle((x, y, x + w, y + h), outline=cl)
        for i in range(0, len(k), 3):
            if k[i + 2] == 0:
                continue
            r = 3 if a["category_id"] == 5 else 5
            d.ellipse((k[i] - r, k[i + 1] - r, k[i] + r, k[i + 1] + r), outline=cl, fill=cl if k[i + 2] == 2 else None)
    tiles.append(img.resize((284, 316)))
cols = 6
sheet = Image.new("RGB", (284 * cols, 316 * ((len(tiles) + cols - 1) // cols)))
for i, t in enumerate(tiles):
    sheet.paste(t, ((i % cols) * 284, (i // cols) * 316))
sheet.save(sys.argv[2] if len(sys.argv) > 2 else "labels_sheet.png")
