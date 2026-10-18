extends Node3D
# VR interaction sim: room-scale mechanics a first-person VR game uses, driven by
# the same action set the pilot sends, plus labelled frames for keypoint training.

const W := 568
const H := 632
const ARM := 0.75
const LEAN := 0.3
const GRAB_R := 0.12
const PRESS_R := 0.10
const GLOVE_RANGE := 6.0
const SPEED := 1.5
const L_WORLD := 1
const L_ITEM := 2
const L_RAIL := 4
const CATS := [
	{"id": 1, "name": "door", "keypoints": ["handle", "hinge_top", "hinge_bottom"]},
	{"id": 2, "name": "drawer", "keypoints": ["pull"]},
	{"id": 3, "name": "button", "keypoints": ["face"]},
	{"id": 4, "name": "item", "keypoints": ["grab"]},
	{"id": 5, "name": "floor", "keypoints": ["stand"]},
	{"id": 6, "name": "ladder", "keypoints": ["rung"]},
]

var rng := RandomNumberGenerator.new()
var world: Node3D
var player: CharacterBody3D
var pshape: CollisionShape3D
var head: Node3D
var cam: Camera3D
var hand := Vector3.ZERO
var aim := {}
var held = null
var glove = null
var doors: Array = []
var drawers: Array = []
var buttons: Array = []
var items: Array = []
var ladders: Array = []
var pocket: Array = []
var cells: Array = []
var crouched := false
var climbing = null
var door_x := 0.0
var lift_x := 0.0
var events: Array = []


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	get_window().size = Vector2i(W, H)
	make_player()
	var code := 0
	match str(args.get("mode", "selftest")):
		"selftest":
			code = await selftest()
		"slugtest":
			code = await slugtest(str(args.get("svg", "")))
		"dataset":
			await dataset(str(args.get("out", "user://out")), int(args.get("worlds", "4")), int(args.get("frames", "8")), int(args.get("seed", "1")))
	get_tree().quit(code)


# ---------------------------------------------------------------- building

func mat(c: Color, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rng.randf_range(0.4, 0.95)
	m.metallic = metal
	return m


func rc() -> Color:
	return Color.from_hsv(rng.randf(), rng.randf_range(0.05, 0.6), rng.randf_range(0.25, 0.85))


func shape_node(body: CollisionObject3D, size: Vector3, c: Color, cyl := false) -> void:
	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	if cyl:
		var s := CylinderShape3D.new()
		s.radius = size.x / 2.0
		s.height = size.y
		cs.shape = s
		var m := CylinderMesh.new()
		m.top_radius = size.x / 2.0
		m.bottom_radius = size.x / 2.0
		m.height = size.y
		mi.mesh = m
	else:
		var s := BoxShape3D.new()
		s.size = size
		cs.shape = s
		var m := BoxMesh.new()
		m.size = size
		mi.mesh = m
	mi.material_override = mat(c)
	body.add_child(cs)
	body.add_child(mi)


func box(size: Vector3, pos: Vector3, c: Color, layer := L_WORLD) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.collision_layer = layer
	shape_node(sb, size, c)
	sb.position = pos
	world.add_child(sb)
	return sb


func light(pos: Vector3) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.omni_range = 7.0
	l.light_energy = rng.randf_range(0.6, 1.8)
	l.light_color = Color.from_hsv(rng.randf_range(0.05, 0.15), rng.randf_range(0.0, 0.4), 1.0)
	l.shadow_enabled = true
	world.add_child(l)


func point(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func build(seed: int) -> void:
	if world:
		remove_child(world)
		world.free()
	doors.clear(); drawers.clear(); buttons.clear(); items.clear(); ladders.clear(); pocket.clear()
	held = null; glove = null; climbing = null; aim = {}
	rng.seed = seed
	world = Node3D.new()
	add_child(world)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.from_hsv(rng.randf_range(0.5, 0.65), 0.3, rng.randf_range(0.5, 0.9))
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = rng.randf_range(0.3, 0.8)
	we.environment = e
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(rng.randf_range(-1.2, -0.4), rng.randf_range(0, TAU), 0)
	sun.light_energy = rng.randf_range(0.5, 1.5)
	sun.shadow_enabled = true
	world.add_child(sun)

	var wc := rc()
	var fc := rc()
	var hh := 2.6
	door_x = rng.randf_range(-1.6, 1.6)
	lift_x = rng.randf_range(-1.0, 1.4)
	# Room A x -3..3 z -3..3, room B z -9..-3, balcony x 3..6 z -1.5..1.5, crawl room C x -5..-3 z -7..-5.
	box(Vector3(6, 0.1, 6), Vector3(0, -0.05, 0), fc)
	box(Vector3(6, 0.1, 6), Vector3(0, -0.05, -6), fc.darkened(0.2))
	box(Vector3(3, 0.1, 3), Vector3(4.5, -0.05, 0), rc())
	box(Vector3(2, 0.1, 2), Vector3(-4, -0.05, -6), fc.darkened(0.4))
	box(Vector3(6, 0.1, 12), Vector3(0, hh + 0.05, -3), wc.darkened(0.3))
	box(Vector3(6, hh, 0.1), Vector3(0, hh / 2, 3), wc)
	box(Vector3(0.1, hh, 6), Vector3(-3, hh / 2, 0), wc)
	box(Vector3(0.1, hh, 1.5), Vector3(3, hh / 2, -2.25), wc)
	box(Vector3(0.1, hh, 1.5), Vector3(3, hh / 2, 2.25), wc)
	box(Vector3(3, 1.0, 0.1), Vector3(4.5, 0.5, -1.5), wc.darkened(0.1))
	box(Vector3(3, 1.0, 0.1), Vector3(4.5, 0.5, 1.5), wc.darkened(0.1))
	# see-through railing: bars the eye looks between and the body cannot pass
	for i in 25:
		box(Vector3(0.03, 1.05, 0.03), Vector3(6.0, 0.525, -1.5 + i * 0.125), Color(0.15, 0.15, 0.15), L_RAIL)
	box(Vector3(0.06, 0.06, 3.0), Vector3(6.0, 1.05, 0), Color(0.15, 0.15, 0.15), L_RAIL)
	for i in 12:
		var t := rng.randf_range(4, 30)
		box(Vector3(rng.randf_range(3, 8), t, rng.randf_range(3, 8)), Vector3(rng.randf_range(15, 60), -20 + t / 2, rng.randf_range(-40, 40)), rc())
	box(Vector3(6, 60, 6), Vector3(90, 10, rng.randf_range(-20, 20)), Color(0.3, 0.33, 0.38))

	# wall A/B with a door opening
	var dl := door_x - 0.45
	var dr := door_x + 0.45
	box(Vector3(dl + 3, hh, 0.1), Vector3((dl - 3) / 2, hh / 2, -3), wc)
	box(Vector3(3 - dr, hh, 0.1), Vector3((dr + 3) / 2, hh / 2, -3), wc)
	box(Vector3(0.9, hh - 2.1, 0.1), Vector3(door_x, 2.1 + (hh - 2.1) / 2, -3), wc)
	var sgn := 1.0 if rng.randf() < 0.5 else -1.0
	make_door(Vector3(door_x - sgn * 0.45, 0, -3), 0.9, 2.1, sgn, rc())

	# room B walls: east full, west with a crawl gap z -6.5..-5.5 below 0.95 m
	box(Vector3(0.1, hh, 6), Vector3(3, hh / 2, -6), wc)
	box(Vector3(0.1, hh, 2.5), Vector3(-3, hh / 2, -7.75), wc)
	box(Vector3(0.1, hh, 2.5), Vector3(-3, hh / 2, -4.25), wc)
	box(Vector3(0.1, hh - 0.95, 1.0), Vector3(-3, 0.95 + (hh - 0.95) / 2, -6), wc)
	box(Vector3(2, 0.1, 2), Vector3(-4, 1.0, -6), wc.darkened(0.3))
	box(Vector3(0.1, 1.0, 2), Vector3(-5, 0.5, -6), wc)
	box(Vector3(2, 1.0, 0.1), Vector3(-4, 0.5, -7), wc)
	box(Vector3(2, 1.0, 0.1), Vector3(-4, 0.5, -5), wc)
	make_item(Vector3(-4.3, 0.15, -6), true)

	# north wall with a lift alcove behind a gate, opened by a button
	var al := lift_x - 0.6
	var ar := lift_x + 0.6
	box(Vector3(al + 3, hh, 0.1), Vector3((al - 3) / 2, hh / 2, -9), wc)
	box(Vector3(3 - ar, hh, 0.1), Vector3((ar + 3) / 2, hh / 2, -9), wc)
	box(Vector3(1.2, 0.1, 1.0), Vector3(lift_x, -0.05, -9.5), Color(0.3, 0.3, 0.3))
	box(Vector3(1.2, hh, 0.1), Vector3(lift_x, hh / 2, -10), wc.darkened(0.2))
	box(Vector3(0.1, hh, 1.0), Vector3(al, hh / 2, -9.5), wc.darkened(0.2))
	box(Vector3(0.1, hh, 1.0), Vector3(ar, hh / 2, -9.5), wc.darkened(0.2))
	var gate := AnimatableBody3D.new()
	gate.sync_to_physics = false
	gate.collision_layer = L_WORLD
	shape_node(gate, Vector3(1.2, 2.2, 0.06), Color(0.5, 0.45, 0.2), false)
	gate.position = Vector3(lift_x, 1.1, -9.0)
	world.add_child(gate)
	make_button(Vector3(ar + 0.35, 1.25, -8.94), Vector3(0, 0, 1), gate)

	# ladder up to a shelf in room B's north-east corner
	make_ladder(Vector3(2.4, 0, -8.9), 2.0)
	box(Vector3(1.0, 0.1, 0.8), Vector3(2.45, 2.0, -8.55), rc())

	# furniture and props
	box(Vector3(0.9, 0.45, 2.0), Vector3(-2.4, 0.225, 1.6), rc())
	var tx := rng.randf_range(-1.5, 1.5)
	box(Vector3(1.2, 0.05, 0.7), Vector3(tx, 0.75, 0.8), rc())
	for lg in [Vector3(-0.55, 0, -0.3), Vector3(0.55, 0, -0.3), Vector3(-0.55, 0, 0.3), Vector3(0.55, 0, 0.3)]:
		box(Vector3(0.05, 0.75, 0.05), Vector3(tx, 0.375, 0.8) + lg, Color(0.2, 0.2, 0.2))
	for i in rng.randi_range(2, 4):
		make_item(Vector3(tx + rng.randf_range(-0.5, 0.5), 0.9, 0.8 + rng.randf_range(-0.25, 0.25)), rng.randf() < 0.5)
	for i in rng.randi_range(2, 4):
		var s := rng.randf_range(0.35, 0.6)
		box(Vector3(s, s, s), Vector3(rng.randf_range(-2.6, -1.0), s / 2, rng.randf_range(-8.6, -7.2)), rc())
	for i in rng.randi_range(1, 3):
		make_item(Vector3(rng.randf_range(-1.5, 1.5), 0.2, rng.randf_range(-7.5, -4.0)), rng.randf() < 0.5)
	# cabinet with two drawers on room B's east wall
	var cz := rng.randf_range(-7.5, -4.5)
	box(Vector3(0.5, 0.9, 0.6), Vector3(2.7, 0.45, cz), rc())
	var dc := rc()
	make_drawer(Vector3(2.44, 0.65, cz), Vector3(-1, 0, 0), dc)
	make_drawer(Vector3(2.44, 0.3, cz), Vector3(-1, 0, 0), dc)
	light(Vector3(0, 2.3, 0))
	light(Vector3(0, 2.3, -6))
	light(Vector3(-4, 0.9, -6))
	skin_world()


var svg_keys: Array = []

func skin_keys() -> Array:
	if svg_keys.is_empty():
		var dir := DirAccess.open("res://textures/svg")
		if dir:
			for f in dir.get_files():
				if f.ends_with(".svg"):
					svg_keys.append(f.get_basename())
		svg_keys.sort()
	return svg_keys


## Lays traced vector surfaces (slug meshes) on both broad faces of every thin slab: walls,
## floors, ceilings, door leaves. Collision is untouched; only looks change.
func skin_world() -> void:
	var keys := skin_keys()
	if keys.is_empty():
		return
	var Decal = load("res://addons/slug_bridge/decal.gd")
	var slabs: Array = []
	for n in world.get_children():
		if n is StaticBody3D and n.collision_layer == L_WORLD:
			slabs.append(n)
	for d in doors:
		slabs.append(d.leaf)
	for b in slabs:
		var cs: CollisionShape3D = b.get_child(0)
		if not (cs.shape is BoxShape3D):
			continue
		var size: Vector3 = cs.shape.size
		var thin := 0 if size.x <= 0.12 else (1 if size.y <= 0.12 else (2 if size.z <= 0.12 else -1))
		if thin < 0:
			continue
		var axes := [0, 1, 2]
		axes.erase(thin)
		var w: float = size[axes[0]]
		var h: float = size[axes[1]]
		if w < 0.5 or h < 0.5:
			continue
		var key: String = keys[rng.randi() % keys.size()]
		var m = Decal.mesh(key, FileAccess.get_file_as_string("res://textures/svg/%s.svg" % key), Vector2(1, 1))
		if m == null:
			continue
		var tile := rng.randf_range(0.8, 1.6)
		var nx := maxi(1, roundi(w / tile))
		var ny := maxi(1, roundi(h / tile))
		var tw := w / nx
		var th := h / ny
		for side in [-1.0, 1.0]:
			var nrm := Vector3.ZERO
			nrm[thin] = side
			var u := Vector3.ZERO
			u[axes[0]] = 1.0
			var v := nrm.cross(u)
			var basis := Basis(u * tw, v * th, nrm)
			for i in nx:
				for j in ny:
					var mi := MeshInstance3D.new()
					mi.mesh = m
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					var off := u * (-w / 2 + tw * (i + 0.5)) + v * (-h / 2 + th * (j + 0.5))
					mi.transform = Transform3D(basis, off + nrm * (size[thin] / 2 + 0.002))
					b.add_child(mi)


func make_door(hinge_pos: Vector3, width: float, height: float, sgn: float, c: Color) -> void:
	var hinge := Node3D.new()
	hinge.position = hinge_pos
	world.add_child(hinge)
	var leaf := AnimatableBody3D.new()
	leaf.sync_to_physics = false
	leaf.collision_layer = L_WORLD
	shape_node(leaf, Vector3(width - 0.02, height - 0.02, 0.05), c)
	leaf.position = Vector3(sgn * width / 2, height / 2, 0)
	hinge.add_child(leaf)
	var handle := point(hinge, Vector3(sgn * (width - 0.1), 1.0, 0.07))
	var knob := MeshInstance3D.new()
	var km := SphereMesh.new()
	km.radius = 0.035
	km.height = 0.07
	knob.mesh = km
	knob.material_override = mat(Color(0.75, 0.7, 0.5), 0.8)
	handle.add_child(knob)
	doors.append({"hinge": hinge, "leaf": leaf, "handle": handle, "hinge_top": point(hinge, Vector3(0, height, 0.03)),
		"hinge_bottom": point(hinge, Vector3(0, 0.02, 0.03)), "sgn": sgn, "width": width, "height": height})


func make_drawer(pos: Vector3, axis: Vector3, c: Color) -> void:
	var body := AnimatableBody3D.new()
	body.sync_to_physics = false
	body.collision_layer = L_WORLD
	shape_node(body, Vector3(0.05, 0.28, 0.5), c)
	body.position = pos
	world.add_child(body)
	var pull := point(body, axis * 0.05)
	var k := MeshInstance3D.new()
	var km := BoxMesh.new()
	km.size = Vector3(0.03, 0.03, 0.14)
	k.mesh = km
	k.material_override = mat(Color(0.7, 0.7, 0.7), 0.9)
	pull.add_child(k)
	drawers.append({"body": body, "pull": pull, "axis": axis, "base": pos, "open": 0.0})


func make_button(pos: Vector3, normal: Vector3, gate: AnimatableBody3D) -> void:
	box(Vector3(0.2, 0.3, 0.04), pos - normal * 0.02, Color(0.2, 0.2, 0.22))
	var b := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.035
	m.bottom_radius = 0.035
	m.height = 0.03
	b.mesh = m
	b.material_override = mat(Color(0.8, 0.1, 0.1))
	b.rotation = Vector3(PI / 2, 0, 0)
	b.position = pos + normal * 0.015
	world.add_child(b)
	buttons.append({"face": point(world, pos + normal * 0.03), "mesh": b, "pressed": false, "gate": gate})


func make_ladder(base: Vector3, height: float) -> void:
	var c := Color(0.35, 0.3, 0.25)
	box(Vector3(0.04, height, 0.04), base + Vector3(-0.22, height / 2, 0), c)
	box(Vector3(0.04, height, 0.04), base + Vector3(0.22, height / 2, 0), c)
	var rungs: Array = []
	var n := int(height / 0.3)
	for i in n:
		var y := 0.3 * (i + 1)
		box(Vector3(0.44, 0.03, 0.03), base + Vector3(0, y, 0), c)
		rungs.append(point(world, base + Vector3(0, y, 0.03)))
	ladders.append({"base": base, "top": height, "rungs": rungs})


func make_item(pos: Vector3, cyl: bool) -> void:
	var rb := RigidBody3D.new()
	rb.collision_layer = L_ITEM
	rb.collision_mask = L_WORLD | L_ITEM
	var s := Vector3(rng.randf_range(0.06, 0.1), rng.randf_range(0.12, 0.25), 0) if cyl else Vector3.ONE * rng.randf_range(0.1, 0.18)
	if cyl:
		s.z = s.x
	shape_node(rb, s, rc(), cyl)
	rb.mass = 0.5
	rb.position = pos
	world.add_child(rb)
	items.append(rb)


func make_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = 0
	player.collision_mask = L_WORLD | L_RAIL
	pshape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.25
	cap.height = 1.75
	pshape.shape = cap
	pshape.position.y = 0.875
	player.add_child(pshape)
	head = Node3D.new()
	head.position.y = 1.6
	player.add_child(head)
	cam = Camera3D.new()
	cam.fov = 100.0
	cam.near = 0.05
	head.add_child(cam)
	add_child(player)


# ---------------------------------------------------------------- actions

func place(pos: Vector3, yaw_deg: float, pitch_deg := 0.0) -> void:
	player.global_position = pos
	player.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
	head.rotation = Vector3(deg_to_rad(pitch_deg), 0, 0)
	player.velocity = Vector3.ZERO
	hand = shoulder() + forward() * 0.3


func forward() -> Vector3:
	return -player.global_transform.basis.z


func shoulder() -> Vector3:
	return head.global_position + head.global_transform.basis * Vector3(0.18, -0.3, 0)


func set_crouch(on: bool) -> bool:
	if not on and crouched:
		var q := PhysicsShapeQueryParameters3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.24
		cap.height = 1.75
		q.shape = cap
		q.collision_mask = L_WORLD
		q.transform = Transform3D(Basis(), player.global_position + Vector3(0, 0.9, 0))
		if not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			return false
	crouched = on
	var c := pshape.shape as CapsuleShape3D
	c.height = 0.9 if on else 1.75
	pshape.position.y = c.height / 2.0
	head.position.y = 0.8 if on else 1.6
	return true


func turn(deg: float) -> void:
	player.rotate_y(deg_to_rad(deg))


func look(pitch_deg: float) -> void:
	head.rotation.x = clamp(head.rotation.x + deg_to_rad(pitch_deg), -1.3, 1.3)


func walk(dir: Vector3, meters: float) -> float:
	var start := player.global_position
	var steps := int(ceil(meters / (SPEED / 60.0)))
	for i in steps:
		var v := player.global_transform.basis * dir.normalized() * SPEED
		player.velocity = Vector3(v.x, player.velocity.y - 9.8 / 60.0, v.z)
		var before := player.global_position
		player.move_and_slide()
		if held != null and held.kind != "item":
			hand += player.global_position - before
			update_held()
		await get_tree().physics_frame
	return start.distance_to(player.global_position)


func ray(o: Vector3, d: Vector3, length := 20.0, mask := L_WORLD | L_ITEM | L_RAIL) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(o, o + d * length, mask)
	return get_world_3d().direct_space_state.intersect_ray(q)


func point_at(px: Vector2) -> Dictionary:
	aim = ray(cam.project_ray_origin(px), cam.project_ray_normal(px))
	return aim


func reach(px: Vector2) -> Vector3:
	var hit := point_at(px)
	var dir := cam.project_ray_normal(px)
	var target: Vector3 = hit.position - dir * 0.05 if hit else cam.project_ray_origin(px) + dir * ARM
	var s := shoulder()
	if s.distance_to(target) > ARM + LEAN:
		target = s + (target - s).normalized() * (ARM + LEAN)
	hand = target
	update_held()
	return hand


func grip() -> String:
	var best = null
	var bd := GRAB_R
	for d in doors:
		var dd: float = d.handle.global_position.distance_to(hand)
		if dd < bd:
			bd = dd; best = {"kind": "door", "ref": d}
	for d in drawers:
		var dd: float = d.pull.global_position.distance_to(hand)
		if dd < bd:
			bd = dd; best = {"kind": "drawer", "ref": d, "grab0": hand - d.pull.global_position}
	for it in items:
		var dd: float = it.global_position.distance_to(hand)
		if dd < bd + 0.05:
			bd = dd; best = {"kind": "item", "ref": it}
	for l in ladders:
		for r in l.rungs:
			var dd: float = r.global_position.distance_to(hand)
			if dd < bd:
				bd = dd; best = {"kind": "ladder", "ref": l}
	if best != null:
		held = best
		if best.kind == "item":
			best.ref.freeze = true
		if best.kind == "ladder":
			climbing = best.ref
		events.append("grab " + best.kind)
		return "held " + best.kind
	if aim and aim.collider in items and aim.position.distance_to(hand) < GLOVE_RANGE:
		glove = aim.collider
		events.append("glove lock")
		return "glove locked"
	return "nothing"


func flick() -> String:
	if glove == null:
		return "nothing locked"
	var it: RigidBody3D = glove
	glove = null
	it.freeze = true
	var tw := create_tween()
	tw.tween_property(it, "global_position", hand, 0.4)
	await tw.finished
	held = {"kind": "item", "ref": it}
	events.append("glove catch")
	return "caught"


func release() -> String:
	if held == null:
		return "empty"
	if held.kind == "item":
		held.ref.freeze = false
	held = null
	climbing = null
	return "released"


func press() -> String:
	for b in buttons:
		if not b.pressed and b.face.global_position.distance_to(hand) < PRESS_R:
			b.pressed = true
			b.mesh.position -= Vector3(0, 0, 0.01)
			var g: AnimatableBody3D = b.gate
			var tw := create_tween()
			tw.tween_property(g, "position", g.position + Vector3(0, 2.3, 0), 1.0)
			events.append("button")
			return "pressed"
	return "nothing to press"


func store() -> String:
	if held == null or held.kind != "item":
		return "nothing held"
	var it: RigidBody3D = held.ref
	pocket.append(it)
	items.erase(it)
	it.visible = false
	it.collision_layer = 0
	held = null
	events.append("store")
	return "stored"


func climb(rungs: int) -> float:
	if climbing == null:
		return 0.0
	var l = climbing
	var y0 := player.global_position.y
	player.global_position.y = clamp(y0 + 0.3 * rungs, 0.0, float(l.top))
	if player.global_position.y >= float(l.top) - 0.01:
		player.global_position += Vector3(0, 0.05, 0) - player.global_transform.basis.z * 0.5
		release()
		events.append("climbed")
	return player.global_position.y - y0


func update_held() -> void:
	if held == null:
		return
	match held.kind:
		"door":
			var d = held.ref
			var v: Vector3 = hand - d.hinge.global_position
			var a := atan2(-v.z, v.x) - (0.0 if d.sgn > 0 else PI)
			d.hinge.rotation.y = clamp(wrapf(a, -PI, PI), -1.6, 1.6)
		"drawer":
			var d = held.ref
			var o: float = clamp((hand - held.grab0 - d.base - d.axis * 0.05).dot(d.axis), 0.0, 0.4)
			d.open = o
			d.body.position = d.base + d.axis * o
		"item":
			held.ref.global_position = hand


func _physics_process(_dt: float) -> void:
	if held != null and held.kind == "item":
		held.ref.global_position = hand


# ---------------------------------------------------------------- floor cells

func free_at(p: Vector3, height: float) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.24
	cap.height = height
	q.shape = cap
	q.collision_mask = L_WORLD | L_RAIL
	q.transform = Transform3D(Basis(), p + Vector3(0, height / 2 + 0.05, 0))
	if not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
		return false
	return not ray(p + Vector3(0, 0.3, 0), Vector3.DOWN, 0.5, L_WORLD).is_empty()


func compute_cells(start: Vector3) -> void:
	cells.clear()
	var step := 0.5
	var origin := Vector3(snappedf(start.x, step), 0, snappedf(start.z, step))
	var seen := {}
	var queue: Array = [Vector2i(0, 0)]
	seen[Vector2i(0, 0)] = true
	while not queue.is_empty() and cells.size() < 800:
		var c: Vector2i = queue.pop_front()
		var p := origin + Vector3(c.x * step, 0, c.y * step)
		var stand := free_at(p, 1.75)
		if not stand and not free_at(p, 0.9):
			continue
		cells.append({"pos": p, "crouch": not stand})
		for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nc: Vector2i = c + n
			if seen.has(nc):
				continue
			var mid := origin + Vector3((c.x + nc.x) * step / 2, 0, (c.y + nc.y) * step / 2)
			if free_at(mid, 0.9):
				seen[nc] = true
				queue.append(nc)


# ---------------------------------------------------------------- self-test

var results: Array = []

func check(name: String, ok: bool, detail := "") -> void:
	results.append(ok)
	print(("PASS " if ok else "FAIL ") + name + ("  " + detail if detail else ""))


func px_of(p: Vector3) -> Vector2:
	return cam.unproject_position(p)


func settle(n := 3) -> void:
	for i in n:
		await get_tree().physics_frame


func selftest() -> int:
	build(7)
	await settle(5)
	var vp := get_viewport().get_visible_rect().size
	check("viewport is the eye size", vp == Vector2(W, H), str(vp))

	# railing: blocks the body, planted control without rail collision passes it
	place(Vector3(4.5, 0, 0), -90)
	await settle()
	await walk(Vector3.FORWARD, 3.0)
	check("railing stops smooth locomotion", player.global_position.x < 5.8, "x=%.2f" % player.global_position.x)
	place(Vector3(4.5, 0, 0), -90)
	player.collision_mask = L_WORLD
	await walk(Vector3.FORWARD, 3.0)
	check("control: without railing collision the body passes", player.global_position.x > 6.2, "x=%.2f" % player.global_position.x)
	player.collision_mask = L_WORLD | L_RAIL

	# door: grip the handle seen at its pixel, back away, the door swings
	var d = doors[0]
	place(Vector3(d.handle.global_position.x, 0, -2.45), 0, -20)
	await settle()
	reach(px_of(d.handle.global_position) + Vector2(0, 0))
	hand.x += 0.0
	var off := hand + Vector3(0.4, 0, 0)
	var keep := hand
	hand = off
	check("control: grip 0.4 m from the handle holds nothing", grip() != "held door")
	release()
	hand = keep
	var g := grip()
	check("grip at the handle pixel holds the door", g == "held door", g + " hand-handle=%.3f" % hand.distance_to(d.handle.global_position))
	await walk(Vector3.BACK, 0.7)
	check("backing away swings the door open", abs(d.hinge.rotation.y) > 0.5, "angle=%.2f rad" % d.hinge.rotation.y)
	release()

	# glove: lock an item through its pixel, flick, catch; blocked line of sight does not lock
	var target: RigidBody3D = items[1]
	place(Vector3(target.global_position.x, 0, target.global_position.z - 2.0), 180, -15)
	await settle()
	point_at(px_of(target.global_position))
	var gg := grip()
	check("glove locks the item at its pixel", gg == "glove locked", gg + " aim=" + (str(aim.collider) + " d=%.2f" % aim.position.distance_to(hand) if aim else "none") + " target=" + str(target) + " held=" + str(held))
	check("flick pulls it into the hand", await flick() == "caught" and held != null and held.ref == target)
	check("store puts it away", store() == "stored" and pocket.size() == 1 and held == null)
	var hidden: RigidBody3D = items[items.size() - 1]
	place(Vector3(hidden.global_position.x, 0, -1.0), 0, -10)
	await settle()
	point_at(px_of(hidden.global_position))
	check("control: an item with a door or wall in the way does not lock", grip() != "glove locked", "aim hit=" + (str(aim.collider) if aim else "none"))
	release()

	# drawer: pull open by its handle pixel
	var dr = drawers[0]
	place(Vector3(2.0, 0, dr.base.z), -90, -40)
	await settle()
	reach(px_of(dr.pull.global_position))
	var gd := grip()
	check("grip at the drawer pull pixel holds it", gd == "held drawer", gd + " hand-pull=%.3f hand=%s pull=%s" % [hand.distance_to(dr.pull.global_position), str(hand), str(dr.pull.global_position)])
	await walk(Vector3.BACK, 0.35)
	check("backing away opens the drawer", dr.open > 0.2, "open=%.2f m" % dr.open)
	release()

	# button: a press away from it does nothing, at its pixel it opens the lift gate
	var b = buttons[0]
	place(Vector3(b.face.global_position.x - 0.2, 0, -8.3), 0, -20)
	await settle()
	reach(px_of(b.face.global_position + Vector3(-0.45, 0, 0)))
	check("control: a press 0.45 m left of the button does nothing", press() == "nothing to press")
	reach(px_of(b.face.global_position))
	check("press at the button pixel registers", press() == "pressed")
	var gate: AnimatableBody3D = b.gate
	var gy := gate.position.y
	await get_tree().create_timer(1.2).timeout
	check("the lift gate opens", gate.position.y > gy + 2.0, "gate y %.2f -> %.2f" % [gy, gate.position.y])

	# crouch: standing is blocked by the crawl gap, crouched passes
	place(Vector3(-2.4, 0, -6), 90)
	await settle()
	await walk(Vector3.FORWARD, 1.5)
	check("standing cannot enter the crawl gap", player.global_position.x > -2.8, "x=%.2f" % player.global_position.x)
	set_crouch(true)
	await walk(Vector3.FORWARD, 1.5)
	check("crouched walks through it", player.global_position.x < -3.3, "x=%.2f" % player.global_position.x)
	check("cannot stand up under the low ceiling", not set_crouch(false))
	await walk(Vector3.BACK, 1.6)
	check("can stand up back in the room", set_crouch(false))

	# ladder: grip a rung, climb to the shelf
	var l = ladders[0]
	place(Vector3(2.4, 0, -8.3), 0, -10)
	await settle()
	reach(px_of(l.rungs[2].global_position))
	var gl := grip()
	check("grip a rung at its pixel", gl == "held ladder", gl + " hand-rung=%.3f hit=%s" % [hand.distance_to(l.rungs[2].global_position), str(aim.collider) if aim else "none"])
	climb(10)
	await settle()
	check("climbing reaches the shelf", player.global_position.y > 1.9, "y=%.2f" % player.global_position.y)

	# floor cells: reachable set excludes the far side of the railing, includes the crawl room
	build(7)
	await settle(5)
	doors[0].hinge.rotation.y = 1.4
	await settle(2)
	compute_cells(Vector3(0, 0, 1.5))
	var beyond := cells.filter(func(c): return c.pos.x > 6.0)
	var crawl := cells.filter(func(c): return c.crouch and c.pos.x < -3.2)
	var alcove := func(): return cells.filter(func(c): return c.pos.z < -9.2).size()
	check("floor cells found", cells.size() > 100, str(cells.size()))
	check("no floor cell beyond the railing", beyond.is_empty(), str(beyond.size()))
	check("crawl-room cells are reachable crouched", not crawl.is_empty(), str(crawl.size()))
	check("no cells behind the closed lift gate", alcove.call() == 0, str(alcove.call()))
	buttons[0].gate.position.y += 2.3
	await settle(2)
	compute_cells(Vector3(0, 0, 1.5))
	check("control: opening the gate makes the lift reachable", alcove.call() > 0, str(alcove.call()))

	var fails := results.count(false)
	print("selftest: %d pass, %d fail" % [results.size() - fails, fails])
	return 1 if fails else 0


func slugtest(svg_path: String) -> int:
	var Decal = load("res://addons/slug_bridge/decal.gd")
	build(7)
	var good = Decal.mesh("t_good", FileAccess.get_file_as_string(svg_path), Vector2(1.2, 1.2))
	check("svg traced from a raster becomes a slug mesh", good != null, Decal.reason if good == null else "%d verts" % good.surface_get_array_len(0))
	var bad = Decal.mesh("t_bad", "<svg><path d='M 0 0 Q'/></svg>", Vector2(1, 1))
	if good != null:
		var sz: Vector3 = good.get_aabb().size
		check("the panel spans the size asked for", abs(sz.x - 1.2) < 0.05 and abs(sz.y - 1.2) < 0.05, str(sz))
	check("control: a broken svg gives no mesh", bad == null or bad.surface_get_array_len(0) == 0, Decal.reason)
	if good != null:
		var mi := MeshInstance3D.new()
		mi.mesh = good
		mi.position = Vector3(0, 1.4, 1.0)
		world.add_child(mi)
		place(Vector3(0, 0, 2.2), 0, -8)
		await settle(3)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_user_data_dir().path_join("slugtest.png"))
	var fails := results.count(false)
	print("slugtest: %d pass, %d fail" % [results.size() - fails, fails])
	return 1 if fails else 0


# ---------------------------------------------------------------- dataset

func visible_kp(p: Vector3, owner: Node) -> Array:
	if not cam.is_position_in_frustum(p):
		return [0.0, 0.0, 0]
	var s := cam.unproject_position(p)
	if s.x < 0 or s.y < 0 or s.x >= W or s.y >= H:
		return [0.0, 0.0, 0]
	var o := cam.global_position
	var hit := ray(o, (p - o).normalized(), o.distance_to(p) + 0.1)
	var v := 2
	if hit and hit.position.distance_to(p) > 0.08 and not (owner != null and (hit.collider == owner or owner.is_ancestor_of(hit.collider))):
		v = 1
	return [s.x, s.y, v]


func bbox_of(pts: Array) -> Array:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	var any := false
	for p in pts:
		if not cam.is_position_in_frustum(p):
			continue
		var s := cam.unproject_position(p)
		mn = mn.min(s); mx = mx.max(s); any = true
	if not any:
		return []
	mn = mn.clamp(Vector2.ZERO, Vector2(W, H)); mx = mx.clamp(Vector2.ZERO, Vector2(W, H))
	if mx.x - mn.x < 2 or mx.y - mn.y < 2:
		return []
	return [mn.x, mn.y, mx.x - mn.x, mx.y - mn.y]


func corners(n: Node3D, size: Vector3) -> Array:
	var out: Array = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				out.append(n.global_transform * (size * Vector3(x, y, z)))
	return out


func annotate() -> Array:
	var anns: Array = []
	var add := func(cat: int, kps: Array, box_pts: Array):
		var flat: Array = []
		var nvis := 0
		var nseen := 0
		for k in kps:
			flat.append_array(k)
			if k[2] > 0:
				nvis += 1
			if k[2] == 2:
				nseen += 1
		var bb := bbox_of(box_pts)
		if nseen > 0 and not bb.is_empty():
			anns.append({"category_id": cat, "bbox": bb, "keypoints": flat, "num_keypoints": nvis})
	for d in doors:
		add.call(1, [visible_kp(d.handle.global_position, d.leaf), visible_kp(d.hinge_top.global_position, d.leaf), visible_kp(d.hinge_bottom.global_position, d.leaf)],
			corners(d.leaf, Vector3(d.width, d.height, 0.05)))
	for d in drawers:
		add.call(2, [visible_kp(d.pull.global_position, d.body)], corners(d.body, Vector3(0.05, 0.28, 0.5)))
	for b in buttons:
		add.call(3, [visible_kp(b.face.global_position, null)], corners(b.face, Vector3(0.08, 0.08, 0.02)))
	for it in items:
		add.call(4, [visible_kp(it.global_position, it)], corners(it, Vector3.ONE * 0.18))
	for l in ladders:
		for r in l.rungs:
			add.call(6, [visible_kp(r.global_position, null)], corners(r, Vector3(0.44, 0.05, 0.05)))
	var here := player.global_position
	for c in cells:
		if c.pos.distance_to(here) < 5.0:
			add.call(5, [visible_kp(c.pos + Vector3(0, 0.02, 0), null)], corners(point(world, c.pos), Vector3(0.4, 0.02, 0.4)))
	return anns


func dataset(out: String, nworlds: int, frames: int, seed: int) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var coco := {"images": [], "annotations": [], "categories": CATS}
	var img_id := 0
	var ann_id := 0
	for w in nworlds:
		build(seed * 1000 + w)
		await settle(10)
		doors[0].hinge.rotation.y = 1.5
		buttons[0].gate.position.y += 2.3
		await settle(2)
		compute_cells(Vector3(0, 0, 1.5))
		var standing := cells.filter(func(c): return not c.crouch)
		for f in frames:
			for d in doors:
				d.hinge.rotation.y = rng.randf_range(-1.4, 1.4) if rng.randf() < 0.5 else 0.0
			for d in drawers:
				d.open = rng.randf_range(0, 0.4) if rng.randf() < 0.4 else 0.0
				d.body.position = d.base + d.axis * d.open
			var c: Dictionary = standing[rng.randi() % standing.size()]
			place(c.pos + Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2)), rng.randf_range(0, 360), rng.randf_range(-45, 10))
			set_crouch(rng.randf() < 0.15)
			await settle(3)
			await RenderingServer.frame_post_draw
			var name := "w%02d_f%03d.png" % [w, f]
			get_viewport().get_texture().get_image().save_png(out.path_join(name))
			coco.images.append({"id": img_id, "file_name": name, "width": W, "height": H, "world_seed": seed * 1000 + w})
			for a in annotate():
				a["id"] = ann_id
				a["image_id"] = img_id
				a["area"] = a.bbox[2] * a.bbox[3]
				a["iscrowd"] = 0
				coco.annotations.append(a)
				ann_id += 1
			img_id += 1
			set_crouch(false)
	var fa := FileAccess.open(out.path_join("annotations.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(coco))
	fa.close()
	print("dataset: %d images, %d annotations -> %s" % [img_id, ann_id, out])
