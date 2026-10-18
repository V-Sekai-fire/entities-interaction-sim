# entities-interaction-sim

A small Godot world that simulates room-scale VR interaction, driven by the actions a remote pilot sends, that writes frames with keypoint labels.

## What it is for

A planner that plays a VR game through a pilot needs places to put the controller: a handle to grab, a button face to press, floor it can walk to. This world has those mechanics behind the pilot's own action set (look, aim at a pixel, reach, grip, trigger, stick), and it writes each frame with the exact pixel of every such place. The labels come from the scene, so they are true by construction.

Mechanics: smooth locomotion with collision, a see-through railing the body cannot pass, hinged doors pulled by the handle, drawers, a button that opens a lift gate, pulling an item at a distance and catching it, storing an item, crouching through a low gap, and climbing a ladder.

Label categories (COCO keypoints): door (handle, hinge top, hinge bottom), drawer (pull), button (face), item (grab), floor (stand), ladder (rung). Floor points are the cells reachable from the start by flood fill, so a cell behind a railing or a closed gate is not one.

Surfaces carry vector art traced from CC0 photographs: `pixi run trace` turns each raster into SVG with VTracer, and the `slug.elf` guest from `entities-sakuragaoka-station` turns each SVG into a flat-colour mesh (`addons/slug_bridge/decal.gd`).

## Build and run

Use the double-precision editor at engine ref `97dab7a6` with a real renderer. Copy `addons/godot_sandbox` from `transport-meshing-pen`; without it the surfaces keep flat colours and the mechanics still run.

    godot --path . -- --mode=selftest
    godot --path . -- --mode=dataset --out=<dir> --worlds=4 --frames=8 --seed=1
    godot --path . -- --mode=slugtest --svg=<file.svg>
    pixi run fetch && pixi run trace
    pixi run sheet

`selftest` checks each mechanic, and each check has a control that must fail: the railing without collision lets the body through, a grip 0.4 m from a handle holds nothing, an item behind a wall does not lock, opening the gate makes the lift reachable. `sheet` draws the labels over the frames as a contact sheet.

## Licence

MIT; see `LICENSE`. `addons/slug_bridge` is copied from `entities-sakuragaoka-station` (MIT). Texture sources are CC0, listed with their hashes in `textures/sources.json`. `CITATION.cff` names each.
