# The port's canvas-texture compute, run either as GDScript (here, the original code) or as the
# compiled SafeGDScript port core/slug/slug_kernels.sgd -> slug_kernels.elf in a Sandbox (made by
# sandbox_util.gd, so it runs natively once a res://bintr/ translation for it exists). Both take and
# return the same values; tools/sgd_check.gd checks them bit for bit and times each stage.
#   Kernels.pack_layers(layers, gradients) -> PackedFloat32Array
# The compiled port runs whenever its Sandbox can be made (the operator's rule: ship compiled
# GDScript); the GDScript bodies here are the reference tools/sgd_check.gd compares it with, and
# the fallback where there is no godot_sandbox addon (then there is no slug.elf either, so only
# realize.gd's palette helpers ever run here). SLUG_KERNELS=gd forces them, for the comparison.
extends RefCounted

const SandboxUtil = preload("res://addons/slug_bridge/sandbox_util.gd")
const SINGLE_ELF := "res://addons/slug_bridge/slug_kernels.elf"
static var ELF := SandboxUtil.for_precision(SINGLE_ELF)
const DATA_WIDTH := 1024
const LAYER_STRIDE := 24
const LAYER_TEXELS := 8
const STAMP_BLEND := 100
const MAX_PER_CELL := 32
const STAMP_WIDTH := 1024
const KIND_CURVE := 0
const KIND_ELLIPSE := 1
const KIND_RECT := 2

static var mode := "gd" if OS.get_environment("SLUG_KERNELS") == "gd" else "sgd"
static var reason := ""
static var _sb = null
static var _tried := false


## The kernels' Sandbox, or null (then everything runs as GDScript).
static func sandbox():
	if not _tried:
		_tried = true
		var r := SandboxUtil.make_sandbox(null, ELF, 1024, 4096, 1 << 24)
		_sb = r.sandbox
		reason = r.reason
	return _sb


## Frees the kernels' Sandbox (and slug_kernels.elf); the next call makes it again.
static func shutdown() -> void:
	SandboxUtil.release(_sb)
	_sb = null
	_tried = false


static func _sgd() -> bool:
	return mode == "sgd" and sandbox() != null


# ----------------------------------------------------------------------------- pack.gd stages

## slug_load_svg for each key (the guest reads the SVG files); returns each call's answer.
static func load_svgs(slug_sandbox: Object, svg_dir: String, keys: PackedStringArray, tolerance_px: float) -> PackedStringArray:
	if _sgd():
		return _sb.vmcall("load_svgs", slug_sandbox, svg_dir, keys, tolerance_px)
	var out := PackedStringArray()
	for key in keys:
		var text := FileAccess.get_file_as_string(svg_dir.path_join(key + ".svg"))
		out.append(str(slug_sandbox.call("vmcall", "slug_load_svg", key, text, tolerance_px)))
	return out


static func read_cache(path: String):
	if _sgd():
		return _sb.vmcall("read_cache", path)
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var d = f.get_var()
	f.close()
	return d


static func write_cache(path: String, data: Dictionary) -> bool:
	if _sgd():
		return bool(_sb.vmcall("write_cache", path, data))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_var(data)
	f.close()
	return true


# ----------------------------------------------------------------------------- atlas.gd stage

## The data texture's floats (atlas.gd documents the layout).
static func pack_layers(layers: PackedFloat32Array, grads: PackedFloat32Array) -> PackedFloat32Array:
	if _sgd():
		return _sb.vmcall("pack_layers", layers, grads)
	var layer_count := layers.size() / LAYER_STRIDE
	var gs := []
	var at := 1
	var ng := int(grads[0]) if grads.size() > 0 else 0
	for g in ng:
		var k := int(grads[at + 10])
		gs.append({"type": grads[at], "m": grads.slice(at + 1, at + 7), "inner": grads[at + 7], "k": k, "stops": grads.slice(at + 11, at + 11 + k * 5)})
		at += 11 + k * 5
	var stop_at := []
	var n := layer_count * LAYER_TEXELS
	for g in gs:
		stop_at.append(n)
		n += 2 * g.k
	var rows := maxi(1, ceili(float(maxi(n, 1)) / DATA_WIDTH))
	var px := PackedFloat32Array()
	px.resize(DATA_WIDTH * rows * 4)
	for li in layer_count:
		var s := li * LAYER_STRIDE
		var d := li * LAYER_TEXELS * 4
		for c in 8:
			px[d + c] = layers[s + c]  # band location, limits, transform
		for c in 4:
			px[d + 8 + c] = layers[s + 16 + c]  # colour
		var gid := int(layers[s + 14])
		var stamp := int(layers[s + 15]) == STAMP_BLEND
		px[d + 12] = layers[s + 12]
		px[d + 13] = layers[s + 13]
		px[d + 14] = -1.0
		px[d + 16] = 1.0
		px[d + 19] = 1.0
		if stamp:
			# a stamp layer: texel 3.zw = (-2, stamp layer index); slot 14 is that index, not a gradient
			px[d + 14] = -2.0
			px[d + 15] = layers[s + 14]
		elif gid > 0 and gid <= gs.size():
			var g: Dictionary = gs[gid - 1]
			px[d + 14] = g.type
			px[d + 15] = stop_at[gid - 1]
			for c in 4:
				px[d + 16 + c] = g.m[c]
			px[d + 20] = g.m[4]
			px[d + 21] = g.m[5]
			px[d + 22] = g.inner
			px[d + 23] = g.k
		px[d + 24] = layers[s + 15]
		var bx := layers[s + 8]
		var by := layers[s + 9]
		px[d + 28] = bx
		px[d + 29] = by - layers[s + 11]
		px[d + 30] = bx + layers[s + 10]
		px[d + 31] = by
	for gi in gs.size():
		var g: Dictionary = gs[gi]
		for si in g.k:
			var o: int = (stop_at[gi] + si * 2) * 4
			px[o] = g.stops[si * 5]
			for c in 4:
				px[o + 4 + c] = g.stops[si * 5 + 1 + c]
	return px


# ----------------------------------------------------------------------------- baked.gd stages

## slug_mesh's arrays as baked.gd keeps them: {positions, paint, param, colours, radial}.
static func parse_mesh(v: PackedFloat32Array, paint: PackedInt32Array, pr: PackedFloat32Array, paints_flat: PackedFloat32Array) -> Dictionary:
	if _sgd():
		return _sb.vmcall("parse_mesh", v, paint, pr, paints_flat)
	var n := v.size() / 3
	var pos := PackedVector2Array()
	pos.resize(n)
	for i in n:
		pos[i] = Vector2(v[i * 3], v[i * 3 + 1])
	var pid := paint.duplicate()
	pid.resize(n)
	var prm := PackedVector2Array()
	prm.resize(n)
	for i in mini(n, pr.size() / 2):
		prm[i] = Vector2(pr[i * 2], pr[i * 2 + 1])
	var paints := decode_paints(paints_flat)
	var radial := false
	var cols := PackedColorArray()
	cols.resize(n)
	for i in n:
		if paints.is_empty():
			cols[i] = Color(1, 1, 1)
			continue
		var p: Dictionary = paints[clampi(pid[i], 0, paints.size() - 1)]
		radial = radial or p.type == "radial"
		cols[i] = paint_colour(p, prm[i].x)
	return {"positions": pos, "paint": pid, "param": prm, "colours": cols, "radial": radial}


static func decode_paints(f: PackedFloat32Array) -> Array:
	var out := []
	var at := 1
	for p in (int(f[0]) if f.size() > 0 else 0):
		var type: String = ["solid", "linear", "radial"][clampi(int(f[at]), 0, 2)]
		var k := int(f[at + 1])
		var stops := []
		for s in k:
			var o := at + 2 + s * 5
			stops.append({"t": f[o], "color": Color(f[o + 1], f[o + 2], f[o + 3], f[o + 4])})
		out.append({"type": type, "stops": stops})
		at += 2 + k * 5
	return out


## A paint's linear colour; t is the linear gradient parameter.
static func paint_colour(p: Dictionary, t: float) -> Color:
	if p.stops.is_empty():
		return Color(1, 1, 1)
	if p.type == "solid":
		return p.stops[0].color
	return ramp(p.stops, t)


static func ramp(stops: Array, t: float) -> Color:
	if stops.is_empty():
		return Color(1, 1, 1)
	t = clampf(t, 0.0, 1.0)
	if t <= float(stops[0].t):
		return stops[0].color
	for i in range(1, stops.size()):
		var a: float = stops[i - 1].t
		var b: float = stops[i].t
		if t <= b:
			return (stops[i - 1].color as Color).lerp(stops[i].color, (t - a) / (b - a) if b - a > 1e-9 else 0.0)
	return stops[stops.size() - 1].color


## slug_decal's flat answer as Godot-wound triangles: [positions, normals, params].
static func unpack_tris(ov: PackedFloat32Array, on: PackedFloat32Array, op: PackedFloat32Array) -> Array:
	if _sgd():
		return _sb.vmcall("unpack_tris", ov, on, op)
	var m := ov.size() / 3
	var out_pos := PackedVector3Array()
	var out_nor := PackedVector3Array()
	var out_prm := PackedVector2Array()
	out_pos.resize(m)
	out_nor.resize(m)
	out_prm.resize(m)
	for t in range(0, m - m % 3, 3):
		for k in 3:
			var s: int = t + [0, 2, 1][k]  # mesh_wire counter-clockwise -> Godot clockwise
			out_pos[t + k] = Vector3(ov[s * 3], ov[s * 3 + 1], ov[s * 3 + 2])
			out_nor[t + k] = Vector3(on[s * 3], on[s * 3 + 1], on[s * 3 + 2]) if on.size() >= m * 3 else Vector3.UP
			out_prm[t + k] = Vector2(op[s * 2], op[s * 2 + 1]) if op.size() >= m * 2 else Vector2.ZERO
	return [out_pos, out_nor, out_prm]


# ----------------------------------------------------------------------------- realize.gd stages

## A palette row's colours: the linear gradient (stops as paint stops {t, color}) at t = x / (width - 1),
## times tint, sRGB; alpha the gradient's for an overlay, else 1.
static func ramp_row(stops: Array, tint: Color, overlay: bool, width: int) -> PackedColorArray:
	if _sgd():
		var st := PackedFloat64Array()
		var sc := PackedColorArray()
		for s in stops:
			st.append(s.t)
			sc.append(s.color)
		return _sb.vmcall("ramp_row", st, sc, tint, overlay, width)
	var out := PackedColorArray()
	out.resize(width)
	for x in width:
		var c := ramp(stops, float(x) / (width - 1))
		var s := Color(c.r * tint.r, c.g * tint.g, c.b * tint.b).linear_to_srgb()
		out[x] = Color(s.r, s.g, s.b, c.a if overlay else 1.0)
	return out


## A blossom mass's band colours from its colour attribute (realize.gd's band rule).
static func blob_cols(attr: PackedFloat32Array, item_size: int, bn: PackedColorArray, bw: PackedColorArray, pe: Color) -> PackedColorArray:
	if _sgd():
		return _sb.vmcall("blob_cols", attr, item_size, bn, bw, pe)
	var out := PackedColorArray()
	out.resize(attr.size() / item_size)
	for i in out.size():
		var tn: float = attr[i * item_size]
		var gc: float = attr[i * item_size + 1]
		var pal := 1 if gc >= 1.5 else 0
		var band: PackedColorArray = bw if pal == 1 else bn
		var b: Color = band[3 if tn >= 0.75 else (2 if tn >= 0.5 else (1 if tn >= 0.25 else 0))]
		out[i] = b.lerp(pe, clampf(gc - 2.0 * pal, 0.0, 1.0))
	return out


## Faces split from idx, with each face's colour (the mean of its vertex colours, times colour):
## [positions, normals (empty without normals), face colours].
static func split_coloured(pos: PackedVector3Array, nor, idx: PackedInt32Array, cols: PackedColorArray, colour: Color) -> Array:
	var nv: PackedVector3Array = nor if nor != null else PackedVector3Array()
	if _sgd():
		return _sb.vmcall("split_coloured", pos, nv, idx, cols, colour)
	var n := idx.size() - idx.size() % 3
	var has_n := nv.size() == pos.size() and nv.size() > 0
	var p2 := PackedVector3Array()
	p2.resize(n)
	var n2 := PackedVector3Array()
	n2.resize(n if has_n else 0)
	var fc := PackedColorArray()
	fc.resize(n / 3)
	for t in range(0, n, 3):
		var ia := idx[t]
		var ib := idx[t + 1]
		var ic := idx[t + 2]
		fc[t / 3] = (cols[ia] + cols[ib] + cols[ic]) / 3.0 * colour
		p2[t] = pos[ia]
		p2[t + 1] = pos[ib]
		p2[t + 2] = pos[ic]
		if has_n:
			n2[t] = nv[ia]
			n2[t + 1] = nv[ib]
			n2[t + 2] = nv[ic]
	return [p2, n2, fc]


## Where each gradient's stops start in the data texture (texel index), as pack_layers lays them out.
static func gradient_stops(layer_count: int, grads: PackedFloat32Array) -> PackedInt32Array:
	if _sgd():
		return _sb.vmcall("gradient_stops", layer_count, grads)
	var out := PackedInt32Array()
	var at := 1
	var n := layer_count * LAYER_TEXELS
	for g in (int(grads[0]) if grads.size() > 0 else 0):
		var k := int(grads[at + 10])
		out.append(n)
		n += 2 * k
		at += 11 + k * 5
	return out


# ----------------------------------------------------------------------------- stamps.gd stage

## stamps.gd's arrays from slug_atlas()'s stamp fields and the atlas's gradient stop texels
## (gradient_stops; the stamps' gradient records share the atlas's stops): {"error": "", "px" (the stamps texture's
## floats, STAMP_WIDTH x rows RGBA), "rows", "cells" (the cells texture's bytes, STAMP_WIDTH x
## cell_rows RGBA8), "cell_rows", "stamp_of_layer" (pairs: layer, stamp layer), "stamp_layer_count",
## "instance_count"}, or {"error": why} when the arrays are inconsistent.
static func pack_stamps(r: Dictionary, stops: PackedInt32Array) -> Dictionary:
	if _sgd():
		return _sb.vmcall("pack_stamps", r, stops)
	var layers: PackedFloat32Array = r.get("layers", PackedFloat32Array())
	var sl: PackedInt32Array = r.get("stamp_layers", PackedInt32Array())
	var protos: PackedFloat32Array = r.get("stamp_protos", PackedFloat32Array())
	var inst: PackedFloat32Array = r.get("stamp_instances", PackedFloat32Array())
	var cb: PackedByteArray = r.get("stamp_cells", PackedByteArray())
	var means: PackedByteArray = r.get("stamp_means", PackedByteArray())
	var grads: PackedFloat32Array = r.get("gradients", PackedFloat32Array([0]))
	var stamp_layer_count := sl.size() / 5
	var instance_count := inst.size() / 12
	var nproto := protos.size() / 2
	var ncell_tex := cb.size() / 4
	var mean_at := ncell_tex
	var hdr := PackedFloat32Array()
	hdr.resize(stamp_layer_count * 8)
	for si in stamp_layer_count:
		var g := sl[si * 5]
		var cbase := sl[si * 5 + 1]
		var first := sl[si * 5 + 2]
		var count := sl[si * 5 + 3]
		var maxc := sl[si * 5 + 4]
		if g <= 0 or cbase < 0 or cbase + g * g > ncell_tex or first < 0 or count < 0 or first + count > instance_count \
				or maxc > MAX_PER_CELL or means.size() < (mean_at - ncell_tex + g * g) * 4:
			return {"error": "stamp layer %d: grid %d, cells at %d (+%d of %d), instances %d+%d of %d, max %d, means %d bytes" % [
					si, g, cbase, g * g, ncell_tex, first, count, instance_count, maxc, means.size()]}
		for c in g * g:
			var fx := cb.decode_u16((cbase + c) * 4)
			var fy := cb.decode_u16((cbase + c) * 4 + 2)
			var last := 2 * cbase + fx + fy
			if fy > MAX_PER_CELL or (fy > 0 and (last + 1) / 2 > ncell_tex):
				return {"error": "stamp layer %d cell %d: %d instances at element %d" % [si, c, fy, fx]}
		hdr[si * 8] = g
		hdr[si * 8 + 1] = cbase
		hdr[si * 8 + 2] = stamp_layer_count * 2 + first * 3
		hdr[si * 8 + 3] = count
		hdr[si * 8 + 4] = maxc
		hdr[si * 8 + 5] = mean_at
		mean_at += g * g
	var layer_count := layers.size() / LAYER_STRIDE
	var grec := PackedFloat32Array()
	var at := 1
	for gi in (int(grads[0]) if grads.size() > 0 else 0):
		var k := int(grads[at + 10])
		grec.append_array(PackedFloat32Array([grads[at + 1], grads[at + 2], grads[at + 3], grads[at + 4],
				grads[at + 5], grads[at + 6], grads[at + 7], k, grads[at], stops[gi], 0, 0]))
		at += 11 + k * 5
	var ngrad := grec.size() / 12
	var grad_base := stamp_layer_count * 2 + instance_count * 3
	var n := grad_base + ngrad * 3
	var rows := maxi(1, ceili(float(maxi(n, 1)) / STAMP_WIDTH))
	var px := PackedFloat32Array()
	px.resize(STAMP_WIDTH * rows * 4)
	for i in hdr.size():
		px[i] = hdr[i]
	for i in grec.size():
		px[grad_base * 4 + i] = grec[i]
	for i in instance_count:
		var s := i * 12
		var d := (stamp_layer_count * 2 + i * 3) * 4
		var pid := int(inst[s + 6])
		if pid < 0 or pid >= nproto:
			return {"error": "instance %d: prototype %d of %d" % [i, pid, nproto]}
		var kind := int(protos[pid * 2])
		var lref := int(protos[pid * 2 + 1])
		var paint := int(inst[s + 7])
		if (kind == KIND_CURVE and (lref < 0 or lref >= layer_count)) or kind < 0 or kind > KIND_RECT or paint < 0 or paint > ngrad:
			return {"error": "instance %d: prototype %d (kind %d, layer %d of %d), paint %d of %d" % [
					i, pid, kind, lref, layer_count, paint, ngrad]}
		for c in 6:
			px[d + c] = inst[s + c]
		px[d + 6] = lref if kind == KIND_CURVE else (-1 if kind == KIND_ELLIPSE else -2)
		px[d + 7] = grad_base + (paint - 1) * 3 if paint > 0 else -1
		for c in 4:
			px[d + 8 + c] = inst[s + 8 + c]
	var cells := cb.duplicate()
	cells.append_array(means.slice(0, (mean_at - ncell_tex) * 4))
	var cell_rows := maxi(1, ceili(float(maxi(cells.size() / 4, 1)) / STAMP_WIDTH))
	cells.resize(STAMP_WIDTH * cell_rows * 4)
	var sol := PackedInt32Array()
	for li in layer_count:
		if int(layers[li * LAYER_STRIDE + 15]) != STAMP_BLEND:
			continue
		var si := int(layers[li * LAYER_STRIDE + 14])
		if si < 0 or si >= stamp_layer_count:
			return {"error": "layer %d: stamp layer %d of %d" % [li, si, stamp_layer_count]}
		sol.append(li)
		sol.append(si)
	return {"error": "", "px": px, "rows": rows, "cells": cells, "cell_rows": cell_rows, "stamp_of_layer": sol,
			"stamp_layer_count": stamp_layer_count, "instance_count": instance_count}


## Two RGB8 frames: [sum |a - b| over the pixels where m equals key (all when m is empty), their channel
## count, the same over the rest, pixels that differ, largest channel difference, pixels that differ inside, outside].
static func frame_diff(a: PackedByteArray, b: PackedByteArray, m: PackedByteArray, key: int) -> PackedInt64Array:
	if _sgd():
		return _sb.vmcall("frame_diff", a, b, m, key)
	var out := PackedInt64Array()
	out.resize(8)
	var count := mini(a.size(), b.size())
	var masked := m.size() >= count
	var i := 0
	while i < count:
		var d0 := absi(a[i] - b[i])
		var d1 := absi(a[i + 1] - b[i + 1])
		var d2 := absi(a[i + 2] - b[i + 2])
		var dd := maxi(d0, maxi(d1, d2))
		var o := 0
		if masked and ((m[i] << 16) | (m[i + 1] << 8) | m[i + 2]) != key:
			o = 2
		if dd > 0:
			out[4] += 1
			out[5] = maxi(out[5], dd)
			out[6 + o / 2] += 1
		out[o] += d0 + d1 + d2
		out[o + 1] += 3
		i += 3
	return out


## An RGB8 frame w x h read inside screen quad q, inset px in from its edges: [pixels, pixels not probe-coloured
## (green under 250 or blue over 5), lowest red, highest red] (chart_in_view.gd's shadow probes).
static func probe_scan(d: PackedByteArray, w: int, h: int, q: PackedVector2Array, inset: float) -> PackedInt32Array:
	if _sgd():
		return _sb.vmcall("probe_scan", d, w, h, q, inset)
	var centre := (q[0] + q[1] + q[2] + q[3]) / 4.0
	var ea := PackedVector2Array()
	var en := PackedVector2Array()
	for k in 4:
		var a := q[k]
		var e := (q[(k + 1) % 4] - a).normalized()
		var n := Vector2(-e.y, e.x)
		if (centre - a).dot(n) < 0.0:
			n = -n
		ea.append(a)
		en.append(n)
	var lo_v := q[0]
	var hi_v := q[0]
	for p in q:
		lo_v = lo_v.min(p)
		hi_v = hi_v.max(p)
	var box := Rect2(lo_v, hi_v - lo_v)
	var out := PackedInt32Array()
	out.resize(4)
	out[2] = 255
	for y in range(maxi(int(box.position.y), 0), mini(int(box.end.y) + 1, h)):
		var yc := y + 0.5
		var x0 := -INF
		var x1 := INF
		var row_ok := true
		for k in 4:
			var a := ea[k]
			var n := en[k]
			var rhs := inset + a.dot(n) - n.y * yc
			if absf(n.x) < 1e-6:
				if rhs > 0.0:
					row_ok = false
			elif n.x > 0.0:
				x0 = maxf(x0, rhs / n.x)
			else:
				x1 = minf(x1, rhs / n.x)
		if not row_ok:
			continue
		for x in range(maxi(ceili(x0 - 0.5), 0), mini(floori(x1 - 0.5), w - 1) + 1):
			var i := (y * w + x) * 3
			out[0] += 1
			if d[i + 1] < 250 or d[i + 2] > 5:
				out[1] += 1
				continue
			out[2] = mini(out[2], d[i])
			out[3] = maxi(out[3], d[i])
	return out


static func score_rgba(a: PackedByteArray, b: PackedByteArray, w: int, h: int) -> PackedFloat64Array:
	if sandbox() == null:
		return PackedFloat64Array()
	return _sb.vmcall("score_rgba", a, b, w, h)


static func diff_rgba(a: PackedByteArray, b: PackedByteArray) -> PackedByteArray:
	if sandbox() == null:
		return PackedByteArray()
	return _sb.vmcall("diff_rgba", a, b)
