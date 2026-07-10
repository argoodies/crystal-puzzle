extends Node3D
## 小魔典 — 粉末冲刷。一枚拼图状钻石（GLB 模型）表面覆盖白粉；
## 触击并保持长按 → 向指到的位置持续喷水冲刷，露出下面光滑的蓝钻表面；拖动可移动冲刷点。
## 冲刷用模型局部空间的“冲刷点”做遮罩：冲刷点附近由白粉过渡为钻石。
## 单指=冲刷；双指=缩放+旋转视角。保留日/夜灯光。iOS 与 Web 同一套代码。

const TARGET_W := 1.8                    # 模型最长边世界尺寸
const ROT_SENS := 0.006
const MIN_ZOOM := 2.0
const MAX_ZOOM := 8.0
const MAXW := 80                         # 冲刷点上限（与 shader 数组一致）

var _camera: Camera3D
var _world: Node3D
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _wash: Array[Vector4] = []
var _count := 0
var _wash_r := 0.1                        # 冲刷笔刷半径（模型局部单位）

var _touches := {}
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO
var _manual_rot := Vector3.ZERO
var _rotating := false
var _bg_rotating := false                 # 单指/拖背景旋转画面
var _washing := false
var _wash_screen := Vector2.ZERO

var _sfx_water: AudioStreamPlayer
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
	_build_diamond()
	_build_toggle()

# ---------- 基础环境 ----------

func _build_audio() -> void:
	_sfx_water = AudioStreamPlayer.new()
	_sfx_water.stream = load("res://sounds/water.wav")
	_sfx_water.volume_db = 0.0
	add_child(_sfx_water)

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0, 0, 0)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.42, 0.36, 0.52)
	_env.ambient_light_energy = 0.6
	_env.glow_enabled = true
	_env.glow_intensity = 1.0
	_env.glow_strength = 1.05
	_env.glow_bloom = 0.25
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	_env.glow_hdr_threshold = 0.9
	_env.set_glow_level(4, 1.0)
	_env.set_glow_level(5, 0.6)
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)
	_camera.position = Vector3(0.0, 0.25, 3.6)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true

func _build_lights() -> void:
	_dir = DirectionalLight3D.new()
	_dir.rotation_degrees = Vector3(-34.0, -22.0, 0.0)
	_dir.light_color = Color(1.0, 0.94, 0.85)
	_dir.light_energy = 1.05
	add_child(_dir)
	_spot = SpotLight3D.new()
	add_child(_spot)
	_spot.position = Vector3(0.0, 1.3, 3.2)
	_spot.look_at(Vector3.ZERO, Vector3.UP)
	_spot.light_color = Color(1.0, 0.9, 0.72)
	_spot.light_energy = 6.5
	_spot.spot_range = 12.0
	_spot.spot_angle = 46.0
	_spot.spot_attenuation = 1.1

# ---------- 日/夜切换 ----------

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
	var spot_c := Color(0.5, 0.68, 1.0) if _night else Color(1.0, 0.9, 0.72)
	var bg_c := Color(0, 0, 0)                 # 背景始终纯黑
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

# ---------- 覆粉钻石 ----------

func _build_diamond() -> void:
	var scene := (load("res://models/diamond.glb") as PackedScene).instantiate()
	_world.add_child(scene)
	_mesh = _find_mesh(scene)
	# 归一化：按局部包围盒缩放居中。
	var ab := _mesh.get_aabb()
	var ext: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	var sc := TARGET_W / ext
	_wash_r = ext * 0.09                    # 笔刷半径（局部单位）
	scene.scale = Vector3(sc, sc, sc)
	scene.position = Vector3.ZERO
	scene.position = -(_mesh.global_transform * ab.get_center())

	# 冲刷遮罩 shader：默认白粉，冲刷点附近露出蓝钻。
	_mat = ShaderMaterial.new()
	_mat.shader = _make_shader()
	_wash.resize(MAXW)
	for i in MAXW:
		_wash[i] = Vector4.ZERO
	_mat.set_shader_parameter("wash_points", _wash)
	_mesh.material_override = _mat

	# 三角网碰撞体，供射线拾取冲刷点。
	_mesh.create_trimesh_collision()

	# 直接放在原石模型内部的光源：从内部把钻石点亮，透出内芒。
	var core := OmniLight3D.new()
	core.position = Vector3.ZERO
	core.light_color = Color(0.5, 0.75, 1.0)
	core.light_energy = 3.5
	core.omni_range = TARGET_W * 1.2
	core.omni_attenuation = 1.0
	core.shadow_enabled = false
	_world.add_child(core)

func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null

func _make_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode specular_schlick_ggx;

uniform vec4 wash_points[80];
uniform vec3 powder_color : source_color = vec3(0.95, 0.96, 0.98);
uniform vec3 diamond_color : source_color = vec3(0.12, 0.42, 0.92);

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	float reveal = 0.0;
	for (int i = 0; i < 80; i++) {
		float r = wash_points[i].w;
		if (r > 0.0) {
			float d = distance(v_local, wash_points[i].xyz);
			reveal = max(reveal, 1.0 - smoothstep(r * 0.6, r, d));
		}
	}
	ALBEDO = mix(powder_color, diamond_color, reveal);
	ROUGHNESS = mix(0.92, 0.05, reveal);       // 白粉粗糙 → 钻石光滑
	METALLIC = mix(0.0, 0.3, reveal);
	SPECULAR = mix(0.15, 1.0, reveal);
	EMISSION = diamond_color * (0.35 * reveal); // 露出处微辉，配泛光
}
"""
	return sh

# ---------- 冲刷 ----------

func _hit_model(screen_pos: Vector2) -> bool:
	var wo := _camera.project_ray_origin(screen_pos)
	var wd := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(wo, wo + wd * 100.0)
	return not space.intersect_ray(q).is_empty()

func _spray(screen_pos: Vector2) -> void:
	var wo := _camera.project_ray_origin(screen_pos)
	var wd := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(wo, wo + wd * 100.0)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var local: Vector3 = _mesh.global_transform.affine_inverse() * (hit.position as Vector3)
	# 找最近的已存在冲刷点：够近则扩大，否则新增。
	var best := -1
	var bestd := INF
	for i in _count:
		var d := local.distance_to(Vector3(_wash[i].x, _wash[i].y, _wash[i].z))
		if d < bestd:
			bestd = d
			best = i
	var grow := _wash_r * 0.35
	if best >= 0 and bestd < _wash_r * 0.7 and _wash[best].w < _wash_r * 2.4:
		_wash[best] = Vector4(_wash[best].x, _wash[best].y, _wash[best].z, _wash[best].w + grow)
	elif _count < MAXW:
		_wash[_count] = Vector4(local.x, local.y, local.z, _wash_r)
		_count += 1
	elif best >= 0:
		_wash[best] = Vector4(_wash[best].x, _wash[best].y, _wash[best].z, minf(_wash[best].w + grow, _wash_r * 2.4))
	_mat.set_shader_parameter("wash_points", _wash)

# ---------- 每帧 ----------

func _process(delta: float) -> void:
	if _washing:
		_spray(_wash_screen)
		if not _sfx_water.playing:
			_sfx_water.play()
	var target := Vector3(_manual_rot.x, _manual_rot.y, 0.0)
	var weight := 1.0 - pow(0.002, delta)
	_world.rotation = _world.rotation.lerp(target, weight)

# ---------- 输入 ----------

func _set_washing(on: bool, pos: Vector2) -> void:
	if on and not _washing:
		_washing = true
		_wash_screen = pos
	elif not on and _washing:
		_washing = false
		_sfx_water.stop()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() == 1:
			var pos: Vector2 = _touches.values()[0]
			if _hit_model(pos):
				_set_washing(true, pos)         # 指到模型 → 冲刷
			else:
				_bg_rotating = true             # 指到背景 → 旋转画面
		else:
			_set_washing(false, Vector2.ZERO)
			_bg_rotating = false
			if _touches.size() == 2:
				_pinch_dist = _two_touch_dist()
				_pinch_mid = _two_touch_mid()
		return
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _touches.size() == 1:
			if _washing:
				_wash_screen = event.position
			elif _bg_rotating:
				_rotate_by(event.relative)
		elif _touches.size() == 2:
			var d := _two_touch_dist()
			if _pinch_dist > 1.0 and d > 1.0:
				_zoom_by(_pinch_dist / d)
			_pinch_dist = d
			var mid := _two_touch_mid()
			_rotate_by(mid - _pinch_mid)
			_pinch_mid = mid
		return
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)
		return
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.pressed: _zoom_by(0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed: _zoom_by(1.0 / 0.9)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _hit_model(event.position):
					_set_washing(true, event.position)   # 点到模型 → 冲刷
				else:
					_bg_rotating = true                  # 点到背景 → 旋转画面
			else:
				_set_washing(false, Vector2.ZERO)
				_bg_rotating = false
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = event.pressed
	elif event is InputEventMouseMotion:
		if _washing:
			_wash_screen = event.position
		elif _bg_rotating or _rotating:
			_rotate_by(event.relative)

func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

func _two_touch_dist() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _two_touch_mid() -> Vector2:
	var pts := _touches.values()
	if pts.size() < 2:
		return Vector2.ZERO
	return ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5

func _zoom_by(ratio: float) -> void:
	var d := clampf(_camera.position.length() * ratio, MIN_ZOOM, MAX_ZOOM)
	_camera.position = _camera.position.normalized() * d
	_camera.look_at(Vector3.ZERO, Vector3.UP)
