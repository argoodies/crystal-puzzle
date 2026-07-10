extends Node3D
## 小魔典 — 宝石切割。初始是一整块蓝色宝石方料，按目标轮廓（一枚拼图片的形状）
## 把多余的料一点点磨掉，最终切出拼图片形状的宝石。点击处会磨削材料并发出“嗡嗡”声。
## 宝石用一层体素小方块表示：轮廓内=保留的宝石，轮廓外=可磨掉的多余料。
## 可缩放/旋转视角，保留日/夜灯光切换。iOS 与 Web 同一套代码，场景全部脚本生成。

const SCALE := 0.82                     # 世界缩放
const CELL := 0.042                     # 体素格边长（世界单位）
const THICK := 0.16                     # 宝石厚度
const MARGIN := 0.13                    # 目标轮廓外多余料的宽度
const BRUSH := 0.055                    # 磨削笔刷半径
const ROT_SENS := 0.006
const MIN_ZOOM := 2.2
const MAX_ZOOM := 8.5
const GEM := Color(0.10, 0.42, 0.86)

var _camera: Camera3D
var _world: Node3D
var _touches := {}
var _pinching := false
var _pinch_dist := 0.0

var _manual_rot := Vector3.ZERO
var _rotating := false
var _press_screen := Vector2.ZERO
var _press_moved := false
var _carve_ok := false
var _carve_pos := Vector2.ZERO

# 体素网格
var _mm: MultiMesh
var _nx := 0
var _ny := 0
var _origin := Vector2.ZERO              # 网格左下角（局部 XY）
var _present: PackedByteArray            # 该格是否还有料
var _keep: PackedByteArray               # 该格是否在目标轮廓内（保留，不可磨）

var _sfx_buzz: AudioStreamPlayer
var _dir: DirectionalLight3D
var _spot: SpotLight3D
var _env: Environment
var _night := false
var _toggle_btn: Button

func _ready() -> void:
	randomize()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_world = Node3D.new()
	add_child(_world)
	_build_gem()
	_build_toggle()

# ---------- 基础环境 ----------

func _build_audio() -> void:
	_sfx_buzz = AudioStreamPlayer.new()
	_sfx_buzz.stream = load("res://sounds/buzz.wav")     # 磨削“嗡嗡”声
	_sfx_buzz.volume_db = 0.0
	add_child(_sfx_buzz)

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.05, 0.03, 0.09)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.42, 0.36, 0.52)
	_env.ambient_light_energy = 0.55
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)
	_camera.position = Vector3(0.0, 0.35, 4.0)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true

func _build_lights() -> void:
	_dir = DirectionalLight3D.new()
	_dir.rotation_degrees = Vector3(-34.0, -22.0, 0.0)
	_dir.light_color = Color(1.0, 0.94, 0.85)
	_dir.light_energy = 1.0
	add_child(_dir)
	_spot = SpotLight3D.new()
	add_child(_spot)
	_spot.position = Vector3(0.0, 1.4, 3.6)
	_spot.look_at(Vector3.ZERO, Vector3.UP)
	_spot.light_color = Color(1.0, 0.88, 0.66)
	_spot.light_energy = 5.0
	_spot.spot_range = 12.0
	_spot.spot_angle = 46.0
	_spot.spot_attenuation = 1.1

# ---------- 日/夜切换按钮 ----------

func _build_toggle() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_toggle_btn = Button.new()
	_toggle_btn.flat = true
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	var emoji_font := load("res://fonts/NotoEmoji-toggle.ttf")
	_toggle_btn.add_theme_font_override("font", emoji_font)
	_toggle_btn.add_theme_font_size_override("font_size", 108)
	_toggle_btn.text = "☀️"
	_toggle_btn.pressed.connect(_on_toggle)
	layer.add_child(_toggle_btn)
	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)

func _apply_safe_area() -> void:
	var btn := 144.0
	var m := 40.0
	var vis := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	var top := m
	var left := m
	if win.x > 1.0 and win.y > 1.0:
		var sc := Vector2(vis.x / win.x, vis.y / win.y)
		var safe := DisplayServer.get_display_safe_area()
		top = safe.position.y * sc.y + m
		left = safe.position.x * sc.x + m
	_toggle_btn.offset_left = left
	_toggle_btn.offset_right = left + btn
	_toggle_btn.offset_top = top
	_toggle_btn.offset_bottom = top + btn

func _on_toggle() -> void:
	_night = not _night
	_apply_lighting(true)

func _apply_lighting(animate: bool) -> void:
	var dir_c := Color(0.62, 0.74, 1.0) if _night else Color(1.0, 0.94, 0.85)
	var spot_c := Color(0.5, 0.68, 1.0) if _night else Color(1.0, 0.88, 0.66)
	var bg_c := Color(0.02, 0.03, 0.09) if _night else Color(0.05, 0.03, 0.09)
	var amb_c := Color(0.30, 0.40, 0.60) if _night else Color(0.42, 0.36, 0.52)
	_toggle_btn.text = "🌙" if _night else "☀️"
	if animate:
		var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
		tw.tween_property(_dir, "light_color", dir_c, 0.5)
		tw.tween_property(_spot, "light_color", spot_c, 0.5)
		tw.tween_property(_env, "background_color", bg_c, 0.5)
		tw.tween_property(_env, "ambient_light_color", amb_c, 0.5)
	else:
		_dir.light_color = dir_c
		_spot.light_color = spot_c
		_env.background_color = bg_c
		_env.ambient_light_color = amb_c

# ---------- 宝石体素板 ----------

func _build_gem() -> void:
	# 目标轮廓：复用生成好的中心拼图片（四边都有凹凸，形状完整）。
	var f := FileAccess.open("res://puzzle.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	var raw: Array = data.pieces[4].verts
	var poly := PackedVector2Array()
	for v in raw:
		poly.append(Vector2(float(v[0]) * SCALE, float(v[1]) * SCALE))
	# 目标包围盒 + 四周多余料 = 初始方料范围。
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	mn -= Vector2(MARGIN, MARGIN)
	mx += Vector2(MARGIN, MARGIN)
	var wsz := mx - mn
	_nx = int(ceil(wsz.x / CELL))
	_ny = int(ceil(wsz.y / CELL))
	var center := (mn + mx) * 0.5
	_origin = center - Vector2(_nx, _ny) * CELL * 0.5   # 居中对齐格子

	var total := _nx * _ny
	_present = PackedByteArray()
	_present.resize(total)
	_keep = PackedByteArray()
	_keep.resize(total)

	var box := BoxMesh.new()
	box.size = Vector3(CELL, CELL, THICK)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(GEM.r, GEM.g, GEM.b, 0.5)       # 半透明蓝宝石
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS   # 写深度：上千半透体素不糊成一团
	mat.metallic = 0.25
	mat.roughness = 0.06                                     # 高光亮，宝石光泽
	mat.metallic_specular = 0.9
	mat.rim_enabled = true
	mat.rim = 0.75                                           # 边缘辉光
	mat.rim_tint = 0.3
	mat.refraction_enabled = true                           # 折射（Compatibility 支持时生效，折射背景光）
	mat.refraction_scale = 0.07
	mat.emission_enabled = true                             # 内部微辉，透出“光芒”
	mat.emission = Color(0.06, 0.20, 0.45)
	mat.emission_energy_multiplier = 0.4
	box.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = box
	_mm.instance_count = total

	for iy in _ny:
		for ix in _nx:
			var idx := iy * _nx + ix
			var c := _cell_center(ix, iy)
			var inside := Geometry2D.is_point_in_polygon(c, poly)
			_keep[idx] = 1 if inside else 0
			_present[idx] = 1
			_mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY, Vector3(c.x, c.y, 0.0)))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	_world.add_child(mmi)

	# 整块方料的碰撞盒：用于把点击射线映射到局部 XY（随视角旋转）。
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(_nx * CELL, _ny * CELL, THICK)
	col.shape = shape
	body.add_child(col)
	body.position = Vector3(_origin.x + _nx * CELL * 0.5, _origin.y + _ny * CELL * 0.5, 0.0)
	body.set_meta("gem", true)
	_world.add_child(body)

func _cell_center(ix: int, iy: int) -> Vector2:
	return _origin + Vector2((ix + 0.5) * CELL, (iy + 0.5) * CELL)

# 在局部 XY 处磨削：按笔刷半径去掉圈内的“多余料”格子（保留料不可磨）。
func _carve(local: Vector2) -> void:
	var removed := false
	var rad_cells := int(ceil(BRUSH / CELL)) + 1
	var cix := int((local.x - _origin.x) / CELL)
	var ciy := int((local.y - _origin.y) / CELL)
	for dy in range(-rad_cells, rad_cells + 1):
		for dx in range(-rad_cells, rad_cells + 1):
			var ix := cix + dx
			var iy := ciy + dy
			if ix < 0 or iy < 0 or ix >= _nx or iy >= _ny:
				continue
			var idx := iy * _nx + ix
			if _present[idx] == 0 or _keep[idx] == 1:
				continue                       # 已磨掉 / 是保留的宝石 → 跳过
			if _cell_center(ix, iy).distance_to(local) > BRUSH:
				continue
			_present[idx] = 0
			_mm.set_instance_transform(idx, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(_cell_center(ix, iy).x, _cell_center(ix, iy).y, 0.0)))
			removed = true
	if removed:
		_sfx_buzz.play()
		Input.vibrate_handheld(15)

# ---------- 每帧：视角旋转平滑 ----------

func _process(delta: float) -> void:
	var target := Vector3(_manual_rot.x, _manual_rot.y, 0.0)
	var weight := 1.0 - pow(0.002, delta)
	_world.rotation = _world.rotation.lerp(target, weight)

# ---------- 输入：缩放 / 旋转视角 / 点击磨削 ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() >= 2:
			_pinching = true
			_carve_ok = false
			_rotating = false
			_pinch_dist = _two_touch_dist()
			return
		else:
			_pinching = false
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _pinching and _touches.size() >= 2:
			var d := _two_touch_dist()
			if _pinch_dist > 1.0 and d > 1.0:
				_zoom_by(_pinch_dist / d)
			_pinch_dist = d
			return
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)
		return
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(0.9)
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(1.0 / 0.9)
			return

	if _pinching:
		return

	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			var lp := _pick_local(event.position)
			_carve_ok = lp.z > 0.5           # z 分量作为命中标志
			_carve_pos = Vector2(lp.x, lp.y)
			_press_screen = event.position
			_press_moved = false
			_rotating = true
		else:
			if not _press_moved and _carve_ok:
				_carve(_carve_pos)
			_carve_ok = false
			_rotating = false
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		if _rotating:
			if not _press_moved and event.position.distance_to(_press_screen) > 14.0:
				_press_moved = true
			_rotate_by(event.relative)

# 返回 (localX, localY, hit)：z=1 命中宝石、z=0 未命中。
func _pick_local(screen_pos: Vector2) -> Vector3:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 100.0)
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.collider.has_meta("gem"):
		var lp: Vector3 = _world.to_local(hit.position)
		return Vector3(lp.x, lp.y, 1.0)
	return Vector3(0, 0, 0)

func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

func _two_touch_dist() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _zoom_by(ratio: float) -> void:
	var d := clampf(_camera.position.length() * ratio, MIN_ZOOM, MAX_ZOOM)
	_camera.position = _camera.position.normalized() * d
	_camera.look_at(Vector3.ZERO, Vector3.UP)
