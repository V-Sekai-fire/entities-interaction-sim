# Earcut (mapbox v2.2.4) as three.js r170 ships it, with the linked-list nodes held as indices into
# parallel arrays (no reference cycles). Coordinates are float64, as in JavaScript.
extends RefCounted

var _i := PackedInt32Array()
var _x := PackedFloat64Array()
var _y := PackedFloat64Array()
var _prev := PackedInt32Array()
var _next := PackedInt32Array()
var _z := PackedInt32Array()
var _pz := PackedInt32Array()
var _nz := PackedInt32Array()
var _steiner := PackedByteArray()


static func triangulate(data: PackedFloat64Array, hole_indices: Array, dim: int = 2) -> PackedInt32Array:
	return load("res://addons/sakuragaoka_station/core/earcut.gd").new()._run(data, hole_indices, dim)


func _run(data: PackedFloat64Array, hole_indices: Array, dim: int) -> PackedInt32Array:
	var has_holes := hole_indices.size() > 0
	var outer_len: int = hole_indices[0] * dim if has_holes else data.size()
	var outer := _linked_list(data, 0, outer_len, dim, true)
	var tris := PackedInt32Array()
	if outer < 0 or _next[outer] == _prev[outer]:
		return tris
	var min_x := 0.0
	var min_y := 0.0
	var inv_size := 0.0
	if has_holes:
		outer = _eliminate_holes(data, hole_indices, outer, dim)
	if data.size() > 80 * dim:
		min_x = data[0]
		var max_x := data[0]
		min_y = data[1]
		var max_y := data[1]
		var i := dim
		while i < outer_len:
			var x := data[i]
			var y := data[i + 1]
			if x < min_x: min_x = x
			if y < min_y: min_y = y
			if x > max_x: max_x = x
			if y > max_y: max_y = y
			i += dim
		inv_size = maxf(max_x - min_x, max_y - min_y)
		inv_size = 32767.0 / inv_size if inv_size != 0.0 else 0.0
	_earcut_linked(outer, tris, dim, min_x, min_y, inv_size, 0)
	return tris


func _node(i: int, x: float, y: float) -> int:
	var n := _i.size()
	_i.append(i)
	_x.append(x)
	_y.append(y)
	_prev.append(-1)
	_next.append(-1)
	_z.append(0)
	_pz.append(-1)
	_nz.append(-1)
	_steiner.append(0)
	return n


func _insert_node(i: int, x: float, y: float, last: int) -> int:
	var p := _node(i, x, y)
	if last < 0:
		_prev[p] = p
		_next[p] = p
	else:
		_next[p] = _next[last]
		_prev[p] = last
		_prev[_next[last]] = p
		_next[last] = p
	return p


func _remove_node(p: int) -> void:
	_prev[_next[p]] = _prev[p]
	_next[_prev[p]] = _next[p]
	if _pz[p] >= 0: _nz[_pz[p]] = _nz[p]
	if _nz[p] >= 0: _pz[_nz[p]] = _pz[p]


func _signed_area(data: PackedFloat64Array, start: int, end: int, dim: int) -> float:
	var s := 0.0
	var i := start
	var j := end - dim
	while i < end:
		s += (data[j] - data[i]) * (data[i + 1] + data[j + 1])
		j = i
		i += dim
	return s


func _linked_list(data: PackedFloat64Array, start: int, end: int, dim: int, clockwise: bool) -> int:
	var last := -1
	if clockwise == (_signed_area(data, start, end, dim) > 0.0):
		var i := start
		while i < end:
			last = _insert_node(i, data[i], data[i + 1], last)
			i += dim
	else:
		var i := end - dim
		while i >= start:
			last = _insert_node(i, data[i], data[i + 1], last)
			i -= dim
	if last >= 0 and _equals(last, _next[last]):
		_remove_node(last)
		last = _next[last]
	return last


func _filter_points(start: int, end: int = -1) -> int:
	if start < 0:
		return start
	if end < 0:
		end = start
	var p := start
	var again := false
	while true:
		again = false
		if not _steiner[p] and (_equals(p, _next[p]) or _area(_prev[p], p, _next[p]) == 0.0):
			_remove_node(p)
			p = _prev[p]
			end = p
			if p == _next[p]:
				break
			again = true
		else:
			p = _next[p]
		if not (again or p != end):
			break
	return end


func _earcut_linked(ear: int, tris: PackedInt32Array, dim: int, min_x: float, min_y: float, inv_size: float, pass_n: int) -> void:
	if ear < 0:
		return
	if pass_n == 0 and inv_size != 0.0:
		_index_curve(ear, min_x, min_y, inv_size)
	var stop := ear
	while _prev[ear] != _next[ear]:
		var prev := _prev[ear]
		var next := _next[ear]
		var is_ear := _is_ear_hashed(ear, min_x, min_y, inv_size) if inv_size != 0.0 else _is_ear(ear)
		if is_ear:
			tris.append(_i[prev] / dim)
			tris.append(_i[ear] / dim)
			tris.append(_i[next] / dim)
			_remove_node(ear)
			ear = _next[next]
			stop = _next[next]
			continue
		ear = next
		if ear == stop:
			if pass_n == 0:
				_earcut_linked(_filter_points(ear), tris, dim, min_x, min_y, inv_size, 1)
			elif pass_n == 1:
				ear = _cure_local_intersections(_filter_points(ear), tris, dim)
				_earcut_linked(ear, tris, dim, min_x, min_y, inv_size, 2)
			elif pass_n == 2:
				_split_earcut(ear, tris, dim, min_x, min_y, inv_size)
			break


func _is_ear(ear: int) -> bool:
	var a := _prev[ear]
	var b := ear
	var c := _next[ear]
	if _area(a, b, c) >= 0.0:
		return false
	var ax := _x[a]; var bx := _x[b]; var cx := _x[c]
	var ay := _y[a]; var by := _y[b]; var cy := _y[c]
	var x0 := minf(ax, minf(bx, cx))
	var y0 := minf(ay, minf(by, cy))
	var x1 := maxf(ax, maxf(bx, cx))
	var y1 := maxf(ay, maxf(by, cy))
	var p := _next[c]
	while p != a:
		if _x[p] >= x0 and _x[p] <= x1 and _y[p] >= y0 and _y[p] <= y1 and \
				_point_in_triangle(ax, ay, bx, by, cx, cy, _x[p], _y[p]) and _area(_prev[p], p, _next[p]) >= 0.0:
			return false
		p = _next[p]
	return true


func _is_ear_hashed(ear: int, min_x: float, min_y: float, inv_size: float) -> bool:
	var a := _prev[ear]
	var b := ear
	var c := _next[ear]
	if _area(a, b, c) >= 0.0:
		return false
	var ax := _x[a]; var bx := _x[b]; var cx := _x[c]
	var ay := _y[a]; var by := _y[b]; var cy := _y[c]
	var x0 := minf(ax, minf(bx, cx))
	var y0 := minf(ay, minf(by, cy))
	var x1 := maxf(ax, maxf(bx, cx))
	var y1 := maxf(ay, maxf(by, cy))
	var min_z := _z_order(x0, y0, min_x, min_y, inv_size)
	var max_z := _z_order(x1, y1, min_x, min_y, inv_size)
	var p := _pz[ear]
	var n := _nz[ear]
	while p >= 0 and _z[p] >= min_z and n >= 0 and _z[n] <= max_z:
		if _x[p] >= x0 and _x[p] <= x1 and _y[p] >= y0 and _y[p] <= y1 and p != a and p != c and \
				_point_in_triangle(ax, ay, bx, by, cx, cy, _x[p], _y[p]) and _area(_prev[p], p, _next[p]) >= 0.0:
			return false
		p = _pz[p]
		if _x[n] >= x0 and _x[n] <= x1 and _y[n] >= y0 and _y[n] <= y1 and n != a and n != c and \
				_point_in_triangle(ax, ay, bx, by, cx, cy, _x[n], _y[n]) and _area(_prev[n], n, _next[n]) >= 0.0:
			return false
		n = _nz[n]
	while p >= 0 and _z[p] >= min_z:
		if _x[p] >= x0 and _x[p] <= x1 and _y[p] >= y0 and _y[p] <= y1 and p != a and p != c and \
				_point_in_triangle(ax, ay, bx, by, cx, cy, _x[p], _y[p]) and _area(_prev[p], p, _next[p]) >= 0.0:
			return false
		p = _pz[p]
	while n >= 0 and _z[n] <= max_z:
		if _x[n] >= x0 and _x[n] <= x1 and _y[n] >= y0 and _y[n] <= y1 and n != a and n != c and \
				_point_in_triangle(ax, ay, bx, by, cx, cy, _x[n], _y[n]) and _area(_prev[n], n, _next[n]) >= 0.0:
			return false
		n = _nz[n]
	return true


func _cure_local_intersections(start: int, tris: PackedInt32Array, dim: int) -> int:
	var p := start
	while true:
		var a := _prev[p]
		var b := _next[_next[p]]
		if not _equals(a, b) and _intersects(a, p, _next[p], b) and _locally_inside(a, b) and _locally_inside(b, a):
			tris.append(_i[a] / dim)
			tris.append(_i[p] / dim)
			tris.append(_i[b] / dim)
			_remove_node(p)
			_remove_node(_next[p])
			p = b
			start = b
		p = _next[p]
		if p == start:
			break
	return _filter_points(p)


func _split_earcut(start: int, tris: PackedInt32Array, dim: int, min_x: float, min_y: float, inv_size: float) -> void:
	var a := start
	while true:
		var b := _next[_next[a]]
		while b != _prev[a]:
			if _i[a] != _i[b] and _is_valid_diagonal(a, b):
				var c := _split_polygon(a, b)
				a = _filter_points(a, _next[a])
				c = _filter_points(c, _next[c])
				_earcut_linked(a, tris, dim, min_x, min_y, inv_size, 0)
				_earcut_linked(c, tris, dim, min_x, min_y, inv_size, 0)
				return
			b = _next[b]
		a = _next[a]
		if a == start:
			break


func _eliminate_holes(data: PackedFloat64Array, hole_indices: Array, outer: int, dim: int) -> int:
	var queue := []
	var n := hole_indices.size()
	for i in n:
		var start: int = hole_indices[i] * dim
		var end: int = hole_indices[i + 1] * dim if i < n - 1 else data.size()
		var list := _linked_list(data, start, end, dim, false)
		if list == _next[list]:
			_steiner[list] = 1
		queue.append(_get_leftmost(list))
	# Array.prototype.sort by x (stable)
	var xs := _x
	queue = _stable_by_x(queue, xs)
	for h in queue:
		outer = _eliminate_hole(h, outer)
	return outer


static func _stable_by_x(q: Array, xs: PackedFloat64Array) -> Array:
	var idx := range(q.size())
	idx.sort_custom(func(a, b): return xs[q[a]] < xs[q[b]] or (xs[q[a]] == xs[q[b]] and a < b))
	var out := []
	for k in idx:
		out.append(q[k])
	return out


func _eliminate_hole(hole: int, outer: int) -> int:
	var bridge := _find_hole_bridge(hole, outer)
	if bridge < 0:
		return outer
	var bridge_reverse := _split_polygon(bridge, hole)
	_filter_points(bridge_reverse, _next[bridge_reverse])
	return _filter_points(bridge, _next[bridge])


func _find_hole_bridge(hole: int, outer: int) -> int:
	var p := outer
	var qx := -INF
	var m := -1
	var hx := _x[hole]
	var hy := _y[hole]
	while true:
		var pn := _next[p]
		if hy <= _y[p] and hy >= _y[pn] and _y[pn] != _y[p]:
			var x := _x[p] + (hy - _y[p]) * (_x[pn] - _x[p]) / (_y[pn] - _y[p])
			if x <= hx and x > qx:
				qx = x
				m = p if _x[p] < _x[pn] else pn
				if x == hx:
					return m
		p = pn
		if p == outer:
			break
	if m < 0:
		return -1
	var stop := m
	var mx := _x[m]
	var my := _y[m]
	var tan_min := INF
	p = m
	while true:
		if hx >= _x[p] and _x[p] >= mx and hx != _x[p] and \
				_point_in_triangle(hx if hy < my else qx, hy, mx, my, qx if hy < my else hx, hy, _x[p], _y[p]):
			var tan := absf(hy - _y[p]) / (hx - _x[p])
			if _locally_inside(p, hole) and (tan < tan_min or (tan == tan_min and (_x[p] > _x[m] or (_x[p] == _x[m] and _sector_contains_sector(m, p))))):
				m = p
				tan_min = tan
		p = _next[p]
		if p == stop:
			break
	return m


func _sector_contains_sector(m: int, p: int) -> bool:
	return _area(_prev[m], m, _prev[p]) < 0.0 and _area(_next[p], m, _next[m]) < 0.0


func _index_curve(start: int, min_x: float, min_y: float, inv_size: float) -> void:
	var p := start
	while true:
		if _z[p] == 0:
			_z[p] = _z_order(_x[p], _y[p], min_x, min_y, inv_size)
		_pz[p] = _prev[p]
		_nz[p] = _next[p]
		p = _next[p]
		if p == start:
			break
	_nz[_pz[p]] = -1
	_pz[p] = -1
	_sort_linked(p)


func _sort_linked(list: int) -> int:
	var in_size := 1
	while true:
		var p := list
		list = -1
		var tail := -1
		var num_merges := 0
		while p >= 0:
			num_merges += 1
			var q := p
			var p_size := 0
			for i in in_size:
				p_size += 1
				q = _nz[q]
				if q < 0:
					break
			var q_size := in_size
			while p_size > 0 or (q_size > 0 and q >= 0):
				var e: int
				if p_size != 0 and (q_size == 0 or q < 0 or _z[p] <= _z[q]):
					e = p
					p = _nz[p]
					p_size -= 1
				else:
					e = q
					q = _nz[q]
					q_size -= 1
				if tail >= 0:
					_nz[tail] = e
				else:
					list = e
				_pz[e] = tail
				tail = e
			p = q
		_nz[tail] = -1
		in_size *= 2
		if num_merges <= 1:
			break
	return list


static func _z_order(x: float, y: float, min_x: float, min_y: float, inv_size: float) -> int:
	var xi := int((x - min_x) * inv_size)
	var yi := int((y - min_y) * inv_size)
	xi = (xi | (xi << 8)) & 0x00FF00FF
	xi = (xi | (xi << 4)) & 0x0F0F0F0F
	xi = (xi | (xi << 2)) & 0x33333333
	xi = (xi | (xi << 1)) & 0x55555555
	yi = (yi | (yi << 8)) & 0x00FF00FF
	yi = (yi | (yi << 4)) & 0x0F0F0F0F
	yi = (yi | (yi << 2)) & 0x33333333
	yi = (yi | (yi << 1)) & 0x55555555
	return xi | (yi << 1)


func _get_leftmost(start: int) -> int:
	var p := start
	var leftmost := start
	while true:
		if _x[p] < _x[leftmost] or (_x[p] == _x[leftmost] and _y[p] < _y[leftmost]):
			leftmost = p
		p = _next[p]
		if p == start:
			break
	return leftmost


static func _point_in_triangle(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, px: float, py: float) -> bool:
	return (cx - px) * (ay - py) >= (ax - px) * (cy - py) and \
		(ax - px) * (by - py) >= (bx - px) * (ay - py) and \
		(bx - px) * (cy - py) >= (cx - px) * (by - py)


func _is_valid_diagonal(a: int, b: int) -> bool:
	return _i[_next[a]] != _i[b] and _i[_prev[a]] != _i[b] and not _intersects_polygon(a, b) and \
		((_locally_inside(a, b) and _locally_inside(b, a) and _middle_inside(a, b) and \
		(_area(_prev[a], a, _prev[b]) != 0.0 or _area(a, _prev[b], b) != 0.0)) or \
		(_equals(a, b) and _area(_prev[a], a, _next[a]) > 0.0 and _area(_prev[b], b, _next[b]) > 0.0))


func _area(p: int, q: int, r: int) -> float:
	return (_y[q] - _y[p]) * (_x[r] - _x[q]) - (_x[q] - _x[p]) * (_y[r] - _y[q])


func _equals(p1: int, p2: int) -> bool:
	return _x[p1] == _x[p2] and _y[p1] == _y[p2]


func _intersects(p1: int, q1: int, p2: int, q2: int) -> bool:
	var o1 := _sgn(_area(p1, q1, p2))
	var o2 := _sgn(_area(p1, q1, q2))
	var o3 := _sgn(_area(p2, q2, p1))
	var o4 := _sgn(_area(p2, q2, q1))
	if o1 != o2 and o3 != o4: return true
	if o1 == 0 and _on_segment(p1, p2, q1): return true
	if o2 == 0 and _on_segment(p1, q2, q1): return true
	if o3 == 0 and _on_segment(p2, p1, q2): return true
	if o4 == 0 and _on_segment(p2, q1, q2): return true
	return false


func _on_segment(p: int, q: int, r: int) -> bool:
	return _x[q] <= maxf(_x[p], _x[r]) and _x[q] >= minf(_x[p], _x[r]) and _y[q] <= maxf(_y[p], _y[r]) and _y[q] >= minf(_y[p], _y[r])


static func _sgn(n: float) -> int:
	return 1 if n > 0.0 else (-1 if n < 0.0 else 0)


func _intersects_polygon(a: int, b: int) -> bool:
	var p := a
	while true:
		if _i[p] != _i[a] and _i[_next[p]] != _i[a] and _i[p] != _i[b] and _i[_next[p]] != _i[b] and _intersects(p, _next[p], a, b):
			return true
		p = _next[p]
		if p == a:
			break
	return false


func _locally_inside(a: int, b: int) -> bool:
	if _area(_prev[a], a, _next[a]) < 0.0:
		return _area(a, b, _next[a]) >= 0.0 and _area(a, _prev[a], b) >= 0.0
	return _area(a, b, _prev[a]) < 0.0 or _area(a, _next[a], b) < 0.0


func _middle_inside(a: int, b: int) -> bool:
	var p := a
	var inside := false
	var px := (_x[a] + _x[b]) / 2.0
	var py := (_y[a] + _y[b]) / 2.0
	while true:
		var pn := _next[p]
		if ((_y[p] > py) != (_y[pn] > py)) and _y[pn] != _y[p] and (px < (_x[pn] - _x[p]) * (py - _y[p]) / (_y[pn] - _y[p]) + _x[p]):
			inside = not inside
		p = pn
		if p == a:
			break
	return inside


func _split_polygon(a: int, b: int) -> int:
	var a2 := _node(_i[a], _x[a], _y[a])
	var b2 := _node(_i[b], _x[b], _y[b])
	var an := _next[a]
	var bp := _prev[b]
	_next[a] = b
	_prev[b] = a
	_next[a2] = an
	_prev[an] = a2
	_next[b2] = a2
	_prev[a2] = b2
	_next[bp] = b2
	_prev[b2] = bp
	return b2
