# The one place this port makes a godot-sandbox Sandbox, after 1-transport/meshing-pen's
# stages/sandbox_util.gd (Gate 0F): memory_max before program=, references_max before the first
# object-creating vmcall, execution_timeout in 2^20-instruction units, allocations_max 1,000,000.
# Native translation: libriscv binary translation runs a guest as native code from
# res://bintr/bintr-<hash>.so (Linux) or .dll (Windows) built for that program. It is switched on
# per process, never in project.godot, and only when such a library is present: the Windows addon
# build segfaulted with the setting on and no library (2026-09-23), so without a library the
# setting stays off and the guest runs interpreted.
#   var r = SandboxUtil.make_sandbox(null, "res://addons/slug_bridge/slug.elf", 1024, 4096, 1 << 24, {}, ["slug_atlas"])
#   r.sandbox (or null), r.reason, SandboxUtil.translated (whether a library was found)
extends RefCounted

const HEAP_CEILING_MB := 5112

static var translated := false


static func enable_native_translation() -> bool:
	var ext := ".so" if OS.get_name() == "Linux" else (".dll" if OS.get_name() == "Windows" else "")
	if ext == "":
		return false
	var dir := DirAccess.open("res://bintr")
	if dir == null:
		return false
	for f in dir.get_files():
		if f.begins_with("bintr-") and f.ends_with(ext):
			ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
			translated = true
			return true
	return false


## A host refuses a guest built for the other real_t, so a double-precision engine loads <name>.double.elf.
static func for_precision(elf: String, double: bool = OS.has_feature("double")) -> String:
	return elf.get_basename() + ".double.elf" if double else elf


static func make_sandbox(parent: Node, elf: String, mem_mb: int = 0, refs: int = 4096, timeout_units: int = 0,
		extra: Dictionary = {}, required: PackedStringArray = PackedStringArray()) -> Dictionary:
	enable_native_translation()
	if mem_mb > HEAP_CEILING_MB:
		return {"sandbox": null, "reason": "memory_max %d MiB is past the %d MiB ceiling" % [mem_mb, HEAP_CEILING_MB]}
	if not ClassDB.class_exists("Sandbox"):
		return {"sandbox": null, "reason": "no Sandbox class (godot_sandbox addon not loaded)"}
	if not ResourceLoader.exists(elf):
		return {"sandbox": null, "reason": "%s not found (not built or not imported)" % elf.get_file()}
	var sb = ClassDB.instantiate("Sandbox")
	if mem_mb > 0:
		sb.memory_max = mem_mb  # before program=
	if refs > 0:
		sb.references_max = refs
	if timeout_units > 0:
		sb.execution_timeout = timeout_units
	sb.allocations_max = 1000000
	for k in extra:
		sb.set(k, extra[k])
	var prog = load(elf)
	if prog == null:
		sb.free()
		return {"sandbox": null, "reason": "%s did not load" % elf.get_file()}
	sb.program = prog
	if sb.has_method("has_program_loaded") and not sb.has_program_loaded():
		sb.free()
		return {"sandbox": null, "reason": "the Sandbox refused %s (its log line says why)" % elf.get_file()}
	for fn in required:
		if sb.has_method("has_function") and not sb.has_function(fn):
			sb.free()
			return {"sandbox": null, "reason": "%s has no %s()" % [elf.get_file(), fn]}
	if parent != null:
		parent.add_child(sb)
	return {"sandbox": sb, "reason": ""}


## Frees a Sandbox made here (and with it its program, the ELF resource): queue_free inside a tree,
## free outside one. Every owner of a Sandbox calls this on teardown, or the ELF outlives the run
## ("resources still in use at exit").
static func release(sb) -> void:
	if sb == null or not is_instance_valid(sb):
		return
	if sb.is_inside_tree():
		sb.get_parent().remove_child(sb)
	sb.free()
