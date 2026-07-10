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
var _wash: Array[Vector4] = []            # 冲刷点：xyz=局部位置, w=半径
var _washn: Array[Vector4] = []           # 冲刷点命中面的局部法线（只冲这一面）
var _count := 0
var _wash_r := 0.1                        # 冲刷笔刷半径（模型局部单位）
var _verts: PackedVector3Array            # 模型顶点（局部空间），用于随机撒“无尘点”
var _norms: PackedVector3Array            # 对应顶点法线
var _refresh_btn: Button
var _spinning := false                     # 旋转4周动画中，暂停常规旋转/冲刷

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
	_spin4()                                  # 初始也旋转 4 周

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

	# 右上角：刷新按钮（重置覆尘 + 旋转 4 周）。
	_refresh_btn = Button.new()
	_refresh_btn.flat = true
	_refresh_btn.focus_mode = Control.FOCUS_NONE
	_refresh_btn.anchor_left = 1.0
	_refresh_btn.anchor_right = 1.0
	_refresh_btn.pivot_offset = Vector2(72.0, 72.0)   # 绕中心旋转（144x144）
	_refresh_btn.icon = load("res://textures/icon_refresh.png")
	_refresh_btn.expand_icon = true
	_refresh_btn.pressed.connect(_restart)
	layer.add_child(_refresh_btn)

	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)

func _apply_safe_area() -> void:
	var btn := 144.0
	var m := 40.0
	var vis := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	var top := m
	var left := m
	var right := m
	if win.x > 1.0 and win.y > 1.0:
		var sc := Vector2(vis.x / win.x, vis.y / win.y)
		var safe := DisplayServer.get_display_safe_area()
		top = safe.position.y * sc.y + m
		left = safe.position.x * sc.x + m
		right = (win.x - (safe.position.x + safe.size.x)) * sc.x + m
	_toggle_btn.offset_left = left
	_toggle_btn.offset_right = left + btn
	_toggle_btn.offset_top = top
	_toggle_btn.offset_bottom = top + btn
	if _refresh_btn != null:
		_refresh_btn.offset_right = -right
		_refresh_btn.offset_left = -right - btn
		_refresh_btn.offset_top = top
		_refresh_btn.offset_bottom = top + btn

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
	_washn.resize(MAXW)
	for i in MAXW:
		_wash[i] = Vector4.ZERO
		_washn[i] = Vector4.ZERO
	var arrays := _mesh.mesh.surface_get_arrays(0)
	_verts = arrays[Mesh.ARRAY_VERTEX]
	_norms = arrays[Mesh.ARRAY_NORMAL]
	_mesh.material_override = _mat
	_seed_dust()                            # 初始：95% 有尘，随机 5% 已无尘

	# 三角网碰撞体，供射线拾取冲刷点。
	_mesh.create_trimesh_collision()

# 重置为初始覆尘态：清空冲刷，随机撒若干“无尘”小点（约 5% 面积无尘）。
func _seed_dust() -> void:
	for i in MAXW:
		_wash[i] = Vector4.ZERO
		_washn[i] = Vector4.ZERO
	_count = 0
	if not _verts.is_empty():
		var n := 12
		for i in n:
			var k := randi() % _verts.size()
			var v: Vector3 = _verts[k]
			var nn: Vector3 = _norms[k] if k < _norms.size() else Vector3.UP
			_wash[_count] = Vector4(v.x, v.y, v.z, _wash_r * 0.7)
			_washn[_count] = Vector4(nn.x, nn.y, nn.z, 0.0)
			_count += 1
	_mat.set_shader_parameter("wash_points", _wash)
	_mat.set_shader_parameter("wash_normals", _washn)

# 刷新：重置覆尘态并旋转 4 周。
func _restart() -> void:
	_seed_dust()
	_spin4()

# 让水晶旋转 4 整圈后回正；刷新按钮图标同步转 4 圈。
func _spin4() -> void:
	_spinning = true
	_manual_rot = Vector3.ZERO
	var axis := Vector3(0.2, 1.0, 0.1).normalized()
	var tw := create_tween().set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(a: float): _world.transform = Transform3D(Basis(axis, a), Vector3.ZERO),
		0.0, TAU * 4.0, 1.9)
	tw.tween_callback(func(): _spinning = false)
	if _refresh_btn != null:
		_refresh_btn.rotation = 0.0
		create_tween().set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT) \
			.tween_property(_refresh_btn, "rotation", TAU * 4.0, 1.9)

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
render_mode blend_mix, cull_disabled, specular_schlick_ggx;

uniform vec4 wash_points[80];
uniform vec4 wash_normals[80];
uniform vec3 powder_color : source_color = vec3(0.52, 0.52, 0.54);
uniform vec3 diamond_color : source_color = vec3(0.12, 0.42, 0.92);

varying vec3 v_local;
varying vec3 v_norm;

void vertex() {
	v_local = VERTEX;
	v_norm = NORMAL;
}

void fragment() {
	vec3 fn = normalize(v_norm);
	float reveal = 0.0;
	for (int i = 0; i < 80; i++) {
		float r = wash_points[i].w;
		// 只冲刷命中的那一面：片元法线需与冲刷点命中面法线同向。
		if (r > 0.0 && dot(fn, wash_normals[i].xyz) > 0.15) {
			float d = distance(v_local, wash_points[i].xyz);
			reveal = max(reveal, 1.0 - smoothstep(r * 0.6, r, d));
		}
	}
	// 菲涅尔：边缘更实、正对更透，像水晶。
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	float crystal_alpha = mix(0.22, 0.85, fres);
	ALBEDO = mix(powder_color, diamond_color, reveal);
	ROUGHNESS = mix(1.0, 0.02, reveal);        // 灰尘纯漫反射 → 水晶镜面光滑
	METALLIC = mix(0.0, 0.3, reveal);
	SPECULAR = mix(0.0, 1.0, reveal);          // 灰尘无镜面 → 水晶强镜面
	// 程序化环境强反光：按反射方向生成“影棚”亮斑，随视角移动，纯黑背景下也能强反光。
	vec3 fn2 = normalize(NORMAL);                                        // 视图空间法线
	vec3 rd = reflect(-normalize(VIEW), fn2);
	vec3 rw = (INV_VIEW_MATRIX * vec4(rd, 0.0)).xyz;
	float env = smoothstep(0.15, 1.0, rw.y) * 0.5;                       // 顶部大面光
	env += pow(max(dot(rw, normalize(vec3(0.8, 0.7, 0.4))), 0.0), 50.0); // 亮斑 1
	env += pow(max(dot(rw, normalize(vec3(-0.7, 0.5, 0.6))), 0.0), 70.0);// 亮斑 2
	float fres2 = pow(1.0 - clamp(dot(fn2, normalize(VIEW)), 0.0, 1.0), 4.0);
	EMISSION = diamond_color * (0.25 * reveal) + diamond_color * env * (0.7 + 1.4 * fres2) * reveal;
	ALPHA = mix(1.0, crystal_alpha, reveal);    // 灰尘不透明 → 冲刷露出后透明
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
	var inv := _mesh.global_transform.affine_inverse()
	var local: Vector3 = inv * (hit.position as Vector3)
	# 命中面法线取“最近顶点的着色法线”，与 shader 里的 fn 同源；
	# 这样即便某些面法线被建模翻反了，也能一致匹配、正常清除。
	var bi := 0
	var bd := INF
	for vi in _verts.size():
		var dd := _verts[vi].distance_squared_to(local)
		if dd < bd:
			bd = dd
			bi = vi
	var lnorm: Vector3 = _norms[bi].normalized()
	# 找最近的、同一面（法线相近）的已存在冲刷点：够近则扩大，否则新增。
	var best := -1
	var bestd := INF
	for i in _count:
		if Vector3(_washn[i].x, _washn[i].y, _washn[i].z).dot(lnorm) < 0.3:
			continue                          # 不同面，不合并
		var d := local.distance_to(Vector3(_wash[i].x, _wash[i].y, _wash[i].z))
		if d < bestd:
			bestd = d
			best = i
	var grow := _wash_r * 0.35
	if best >= 0 and bestd < _wash_r * 0.7 and _wash[best].w < _wash_r * 2.4:
		_wash[best] = Vector4(_wash[best].x, _wash[best].y, _wash[best].z, _wash[best].w + grow)
	elif _count < MAXW:
		_wash[_count] = Vector4(local.x, local.y, local.z, _wash_r)
		_washn[_count] = Vector4(lnorm.x, lnorm.y, lnorm.z, 0.0)
		_count += 1
	elif best >= 0:
		_wash[best] = Vector4(_wash[best].x, _wash[best].y, _wash[best].z, minf(_wash[best].w + grow, _wash_r * 2.4))
	_mat.set_shader_parameter("wash_points", _wash)
	_mat.set_shader_parameter("wash_normals", _washn)

# ---------- 每帧 ----------

func _process(delta: float) -> void:
	if _spinning:
		return                                # 旋转 4 周动画期间由 tween 接管
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
