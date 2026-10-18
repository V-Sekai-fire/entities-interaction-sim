import glob
import json
import os
import sys
import vtracer
from PIL import Image

root = sys.argv[1]
os.makedirs(f"{root}/svg", exist_ok=True)
report = {}
for src in sorted(glob.glob(f"{root}/raster/*.jpg")):
    key = os.path.splitext(os.path.basename(src))[0]
    small = f"{root}/svg/{key}.png"
    Image.open(src).convert("RGB").resize((256, 256), Image.LANCZOS).save(small)
    out = f"{root}/svg/{key}.svg"
    for ld in (32, 16, 8, 4, 2):
        vtracer.convert_image_to_svg_py(small, out, colormode="color", hierarchical="cutout", mode="spline",
                                        filter_speckle=8, color_precision=6, layer_difference=ld,
                                        corner_threshold=60, length_threshold=4.0, splice_threshold=45, path_precision=2)
        paths = open(out).read().count("<path")
        if paths >= 20:
            break
    if paths > 150:
        for fs in (16, 32, 64):
            vtracer.convert_image_to_svg_py(small, out, colormode="color", hierarchical="cutout", mode="spline",
                                            filter_speckle=fs, color_precision=6, layer_difference=ld,
                                            corner_threshold=60, length_threshold=4.0, splice_threshold=45, path_precision=2)
            paths = open(out).read().count("<path")
            if paths <= 150:
                break
    os.remove(small)
    report[key] = {"bytes": os.path.getsize(out), "paths": paths, "layer_difference": ld}
    print(key, report[key])
json.dump(report, open(f"{root}/svg/trace_report.json", "w"), indent=1)
