# slug.elf, the godot-sandbox guest that does the canvas textures' compute (slughorn: SVG to curve
# and band textures, the per-key layer table, baked planar meshes, decal clipping). The port only
# calls it; see atlas.gd and baked.gd for what each call returns. Made by core/slug/sandbox_util.gd
# (meshing-pen's stages/sandbox_util.gd: Gate 0F settings, native translation when a res://bintr/
# library exists). No Sandbox class (the godot_sandbox addon is not in this project) or no ELF:
# shared() is null and every canvas texture falls back to its mean colour.
#   var g = Guest.shared()
#   if g: var r = g.call_fn("slug_atlas")
# Tests set Guest.override to an object with call_fn(name, args) and has_fn(name) (see
# tools/slug_fixture/fixture_guest.gd) before the first shared().
extends RefCounted

const SandboxUtil = preload("res://addons/slug_bridge/sandbox_util.gd")

const SINGLE_ELF := "res://addons/slug_bridge/slug.elf"
static var ELF := SandboxUtil.for_precision(SINGLE_ELF)
const MEM_MB := 1024
const REFS := 4096
## execution_timeout in 2^20-instruction units; a whole station's decals run long.
const TIMEOUT_UNITS := 1 << 24
const REQUIRED := ["slug_load_svg", "slug_atlas", "slug_mesh", "slug_cost", "slug_decal"]

static var override = null
static var _shared = null
static var _tried := false
static var reason := ""

var sandbox = null


static func shared():
	if override != null:
		return override
	if not _tried:
		_tried = true
		_shared = _open()
	return _shared


static func reset() -> void:
	_tried = false
	_shared = null


## Frees slug.elf's Sandbox (and the ELF); the next shared() makes it again.
static func shutdown() -> void:
	if _shared != null:
		SandboxUtil.release(_shared.sandbox)
		_shared.sandbox = null
	reset()


static func _open():
	var r := SandboxUtil.make_sandbox(null, ELF, MEM_MB, REFS, TIMEOUT_UNITS, {}, PackedStringArray(REQUIRED))
	if r.sandbox == null:
		reason = r.reason
		return null
	var g = new()
	g.sandbox = r.sandbox
	return g


func has_fn(fn: String) -> bool:
	return sandbox != null and (not sandbox.has_method("has_function") or sandbox.has_function(fn))


func call_fn(fn: String, args: Array = []):
	return sandbox.callv("vmcall", [fn] + args)
