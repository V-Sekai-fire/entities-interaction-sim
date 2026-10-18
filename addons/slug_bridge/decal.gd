# SVG to a flat-colour planar mesh through slug.elf (slughorn), the station's baked-mesh path.
extends RefCounted
const Guest = preload("res://addons/slug_bridge/guest.gd")
const Kernels = preload("res://addons/slug_bridge/kernels.gd")

static var _cache := {}
static var reason := ""


## slug_mesh positions are the unit square. ArrayMesh in the XY plane, size_m wide and high, origin at the centre, +Z facing; null on failure.
static func mesh(key: String, svg: String, size_m: Vector2, tol := 0.5) -> ArrayMesh:
	if _cache.has(key):
		return _cache[key]
	var g = Guest.shared()
	if g == null:
		reason = "no guest: " + Guest.reason
		return null
	var r = g.call_fn("slug_load_svg", [key, svg, tol])
	if not str(r).begins_with("ok"):
		reason = "slug_load_svg: " + str(r)
		return null
	var m = g.call_fn("slug_mesh", [key])
	if not (m is Dictionary) or m.is_empty():
		reason = "slug_mesh empty"
		return null
	var v: PackedFloat32Array = m.get("vertices", PackedFloat32Array())
	var idx: PackedInt32Array = m.get("triangles", PackedInt32Array())
	if v.size() < 9 or idx.size() % 3 != 0:
		reason = "slug_mesh: %d floats, %d indices" % [v.size(), idx.size()]
		return null
	var k := Kernels.parse_mesh(v, m.get("paint", PackedInt32Array()), m.get("param", PackedFloat32Array()), m.get("paints", PackedFloat32Array([0])))
	var pos2: PackedVector2Array = k.positions
	var pos := PackedVector3Array()
	pos.resize(pos2.size())
	var nrm := PackedVector3Array()
	nrm.resize(pos2.size())
	var uv := PackedVector2Array()
	uv.resize(pos2.size())
	for i in pos2.size():
		var t := pos2[i]
		pos[i] = Vector3((t.x - 0.5) * size_m.x, (0.5 - t.y) * size_m.y, 0)
		nrm[i] = Vector3(0, 0, 1)
		uv[i] = t
	var cols: PackedColorArray = k.colours
	var tri := PackedInt32Array()
	tri.resize(idx.size())
	for i in range(0, idx.size(), 3):
		tri[i] = idx[i]; tri[i + 1] = idx[i + 2]; tri[i + 2] = idx[i + 1]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = tri
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	am.surface_set_material(0, mat)
	_cache[key] = am
	return am
