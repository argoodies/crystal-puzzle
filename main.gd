extends Node3D
## 擦水晶 — 粉末冲刷。一枚拼图状钻石（GLB 模型）表面覆盖白粉；
## 触击并保持长按 → 向指到的位置持续喷水冲刷，露出下面光滑的蓝钻表面；拖动可移动冲刷点。
## 冲刷用模型局部空间的“冲刷点”做遮罩：冲刷点附近由白粉过渡为钻石。
## 单指=冲刷；双指=缩放+旋转视角。保留日/夜灯光。iOS 与 Web 同一套代码。

const TARGET_W := 3.6                    # 模型最长边世界尺寸（放大 2 倍）
const ROT_SENS := 0.006
const MIN_ZOOM := 3.08                    # 最近：水晶约占屏宽 120%
const MAX_ZOOM := 10.85                   # 最远：水晶约占屏宽 34%
const SAVE_MASK := "user://wipe_mask.png"    # 擦拭进度遮罩
const SAVE_STATE := "user://wipe_state.json" # 按钮态/交付/日夜
const MSZ := 1024                        # 冲刷遮罩纹理尺寸（更高→边缘更细腻）
const WASH_UV_R := 0.124                  # 冲刷笔刷半径（UV 空间，面积约 2 倍）
const SEED_UV_R := 0.013                  # 初始无尘点半径（UV 空间）

const MODELS := ["res://models/diamond.glb", "res://models/puzzle2.glb"]

var _camera: Camera3D
var _world: Node3D
var _mesh: MeshInstance3D
var _model_root: Node3D                    # 当前模型实例（换模型时释放）
var _core_light: OmniLight3D              # 模型内部光源
var _model_path := MODELS[0]              # 当前模型（存档）
var _mat: ShaderMaterial
var _verts: PackedVector3Array            # 模型顶点（局部空间）
var _uvs: PackedVector2Array              # 对应 UV，用于把冲刷画进遮罩
var _mask_img: Image                      # 冲刷遮罩：0=覆尘, 1=已冲刷露出
var _mask_tex: ImageTexture
var _refresh_btn: Button
var _spinning := false                     # 旋转4周动画中，暂停常规旋转/冲刷

const ST_REFRESH := 0                       # 右上角按钮状态：刷新
const ST_CIRCLE := 1                        # 可交付：圆圈
const ST_DELIVERED := 2                     # 已交付：对勾
var _btn_state := ST_REFRESH
var _delivered := false                     # 已交付：禁冲刷，只旋转
var _cov_tick := 0                          # 覆盖率检测节流

var _touches := {}
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO
var _manual_rot := Vector3.ZERO
var _rotating := false
var _bg_rotating := false                 # 单指/拖背景旋转画面
var _washing := false
var _wash_screen := Vector2.ZERO

var _sfx_water: AudioStreamPlayer
var _sfx_reward: AudioStreamPlayer
var _sfx_ding: AudioStreamPlayer
var _sfx_click: AudioStreamPlayer
var _sfx_whoosh: AudioStreamPlayer
var _godray_mat: ShaderMaterial
var _spray_fx: CPUParticles3D             # 喷水水花粒子
var _droplet_mat: StandardMaterial3D      # 水珠共享材质（松手时整体淡出）
var _fade_tween: Tween                     # 松手后整体淡出的 tween
const DROP_ALPHA := 0.2                     # 水珠透明度
var _wash_hitting := false                 # 正在擦拭且射线命中了模型
var _moved := false                         # 本帧手指是否移动：移动才喷水珠
var _dir: DirectionalLight3D
var _spot: SpotLight3D
var _env: Environment
var _night := false
var _toggle_btn: Button

# ---------- 解锁画廊 ----------
const GAL_ORIGIN := Vector3(0.0, 40.0, 0.0)  # 画廊远离水晶
var _map_btn: Button
var _in_gallery := false
var _gallery_root: Node3D
var _unlocked: Array = []                    # 解锁过(擦净交付)的模型 path
var _gal_yaw := 0.0
var _gal_pitch := 0.0
var _gal_drag := false
var _cam_saved := Transform3D.IDENTITY

func _ready() -> void:
	randomize()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_build_spray_fx()
	_world = Node3D.new()
	add_child(_world)
	var loaded := _load_state()               # 成功则填好 _mask_img/_model_path/状态
	if not loaded:
		_model_path = MODELS[randi() % MODELS.size()]
		_mask_img = Image.create(MSZ, MSZ, false, Image.FORMAT_L8)
	_build_model(_model_path)
	if not loaded:
		_seed_dust()                          # 新开局：随机覆尘（需 _uvs，故在建模后）
	_build_godrays()
	_build_toggle()
	_apply_loaded_ui()                        # 恢复存档的按钮态/日夜
	_spin4()                                  # 初始也旋转 4 周

# ---------- 存档 ----------

func _save_state() -> void:
	if _mask_img != null:
		_mask_img.save_png(SAVE_MASK)
	var f := FileAccess.open(SAVE_STATE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"btn": _btn_state, "delivered": _delivered, "night": _night, "model": _model_path, "unlocked": _unlocked}))
		f.close()

# 读存档：成功则填好 _mask_img + 状态，返回 true。
func _load_state() -> bool:
	if not FileAccess.file_exists(SAVE_MASK):
		return false
	var img := Image.load_from_file(SAVE_MASK)
	if img == null or img.get_width() != MSZ or img.get_height() != MSZ:
		return false
	img.convert(Image.FORMAT_L8)
	_mask_img = img
	if FileAccess.file_exists(SAVE_STATE):
		var cfg = JSON.parse_string(FileAccess.get_file_as_string(SAVE_STATE))
		if cfg is Dictionary:
			_btn_state = int(cfg.get("btn", ST_REFRESH))
			_delivered = bool(cfg.get("delivered", false))
			_night = bool(cfg.get("night", false))
			var mp := str(cfg.get("model", MODELS[0]))
			if mp in MODELS:
				_model_path = mp
			var ul = cfg.get("unlocked", [])
			if ul is Array:
				for p in ul:
					if p in MODELS and not _unlocked.has(p):
						_unlocked.append(p)
	return true

# 按已读入的状态设置按钮图标与日夜光照。
func _apply_loaded_ui() -> void:
	if _btn_state == ST_CIRCLE:
		_refresh_btn.icon = load("res://textures/icon_circle.png")
	elif _btn_state == ST_DELIVERED:
		_refresh_btn.icon = load("res://textures/icon_check.png")
		if _map_btn != null:
			_map_btn.visible = true
	if _night:
		_apply_lighting(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_save_state()

# ---------- 基础环境 ----------

func _build_audio() -> void:
	_sfx_water = AudioStreamPlayer.new()
	_sfx_water.stream = load("res://sounds/water.wav")
	_sfx_water.volume_db = 0.0
	add_child(_sfx_water)
	_sfx_reward = AudioStreamPlayer.new()
	_sfx_reward.stream = load("res://sounds/reward.wav")
	_sfx_reward.volume_db = 0.0
	add_child(_sfx_reward)
	_sfx_ding = AudioStreamPlayer.new()
	_sfx_ding.stream = load("res://sounds/ding.wav")
	_sfx_ding.volume_db = 0.0
	add_child(_sfx_ding)
	_sfx_click = AudioStreamPlayer.new()
	_sfx_click.stream = load("res://sounds/click.wav")
	_sfx_click.volume_db = 0.0
	add_child(_sfx_click)
	_sfx_whoosh = AudioStreamPlayer.new()
	_sfx_whoosh.stream = load("res://sounds/shroud.wav")
	_sfx_whoosh.volume_db = 0.0
	add_child(_sfx_whoosh)

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
	_env.glow_hdr_threshold = 1.1                 # 只有很亮的水晶高光才泛光，哑光灰尘不泛
	_env.set_glow_level(4, 1.0)
	_env.set_glow_level(5, 0.6)
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	_camera.keep_aspect = Camera3D.KEEP_WIDTH   # 以屏幕宽度为基准，缩放按宽度占比稳定
	add_child(_camera)
	_camera.position = Vector3(0.0, 0.5, 7.36)  # 距离≈7.38：水晶约占屏宽 50%
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
	_refresh_btn.pressed.connect(_on_topbtn)
	layer.add_child(_refresh_btn)

	# 刷新按钮下方：地图按钮（交付后可见，看解锁模型画廊）。
	_map_btn = Button.new()
	_map_btn.flat = true
	_map_btn.focus_mode = Control.FOCUS_NONE
	_map_btn.anchor_left = 1.0
	_map_btn.anchor_right = 1.0
	_map_btn.icon = load("res://textures/icon_map.png")
	_map_btn.expand_icon = true
	_map_btn.visible = false
	_map_btn.pressed.connect(_toggle_gallery)
	layer.add_child(_map_btn)

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
	if _map_btn != null:
		var my := top + btn + 24.0            # 刷新按钮下方
		_map_btn.offset_right = -right
		_map_btn.offset_left = -right - btn
		_map_btn.offset_top = my
		_map_btn.offset_bottom = my + btn

func _on_toggle() -> void:
	_night = not _night
	_sfx_click.play()
	_apply_lighting(true)
	_save_state()

func _apply_lighting(animate: bool) -> void:
	var dir_c := Color(0.62, 0.74, 1.0) if _night else Color(1.0, 0.94, 0.85)
	var spot_c := Color(0.5, 0.68, 1.0) if _night else Color(1.0, 0.9, 0.72)
	var bg_c := Color(0, 0, 0)                 # 背景始终纯黑
	var amb_c := Color(0.30, 0.40, 0.60) if _night else Color(0.42, 0.36, 0.52)
	# 月光模式：整体更暗
	var dir_e := 0.45 if _night else 1.05
	var spot_e := 3.0 if _night else 6.5
	var amb_e := 0.32 if _night else 0.6
	_toggle_btn.text = "🌙" if _night else "☀️"
	if animate:
		var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
		tw.tween_property(_dir, "light_color", dir_c, 0.5)
		tw.tween_property(_spot, "light_color", spot_c, 0.5)
		tw.tween_property(_env, "background_color", bg_c, 0.5)
		tw.tween_property(_env, "ambient_light_color", amb_c, 0.5)
		tw.tween_property(_dir, "light_energy", dir_e, 0.5)
		tw.tween_property(_spot, "light_energy", spot_e, 0.5)
		tw.tween_property(_env, "ambient_light_energy", amb_e, 0.5)
	else:
		_dir.light_color = dir_c
		_spot.light_color = spot_c
		_env.background_color = bg_c
		_env.ambient_light_color = amb_c
		_dir.light_energy = dir_e
		_spot.light_energy = spot_e
		_env.ambient_light_energy = amb_e

# ---------- 覆粉钻石 ----------

# 用给定模型搭建覆尘水晶：网格 + 遮罩材质 + 碰撞 + 内部光源。可重复调用换模型。
func _build_model(path: String) -> void:
	if _model_root != null and is_instance_valid(_model_root):
		_model_root.queue_free()
	if _core_light != null and is_instance_valid(_core_light):
		_core_light.queue_free()
	var scene := (load(path) as PackedScene).instantiate()
	_model_root = scene
	_world.add_child(scene)
	_mesh = _find_mesh(scene)
	# 归一化：按局部包围盒缩放居中。
	var ab := _mesh.get_aabb()
	var ext: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	var sc := TARGET_W / ext
	scene.scale = Vector3(sc, sc, sc)
	scene.position = Vector3.ZERO
	scene.position = -(_mesh.global_transform * ab.get_center())

	# 双趟材质：灰尘层(不透明)为底，水晶层(透明)为 next_pass。
	_mat = ShaderMaterial.new()
	_mat.shader = _make_dust_shader()
	var crystal := ShaderMaterial.new()
	crystal.shader = _make_crystal_shader()
	_mat.next_pass = crystal
	var arrays := _mesh.mesh.surface_get_arrays(0)
	_verts = arrays[Mesh.ARRAY_VERTEX]
	_uvs = arrays[Mesh.ARRAY_TEX_UV]
	_mask_tex = ImageTexture.create_from_image(_mask_img)
	_mat.set_shader_parameter("wash_mask", _mask_tex)
	crystal.set_shader_parameter("wash_mask", _mask_tex)
	_mesh.material_override = _mat

	# 三角网碰撞体，供射线拾取冲刷点。
	_mesh.create_trimesh_collision()

	# 模型内部光源：从内部把水晶点亮，透过冲刷露出处透出内芒。
	_core_light = OmniLight3D.new()
	_core_light.position = Vector3.ZERO
	_core_light.light_color = Color(0.5, 0.75, 1.0)
	_core_light.light_energy = 1.8
	_core_light.omni_range = TARGET_W * 1.2
	_core_light.shadow_enabled = false
	_world.add_child(_core_light)

# 重置为初始覆尘态：清空后用几笔“隐藏随机擦拭”把无尘面积做到约 20%（像真擦过，而非撒点）。
func _seed_dust() -> void:
	_mask_img.fill(Color(0, 0, 0))          # 全部覆尘
	if not _verts.is_empty():
		var guard := 0
		while _coverage() < 0.20 and guard < 30:
			_wipe_stroke()
			guard += 1
	_mask_tex.update(_mask_img)

# 一笔连贯的随机擦拭：从随机顶点出发，沿表面朝一个逐渐转向的方向走，沿途盖笔刷。
func _wipe_stroke() -> void:
	var idx := randi() % _verts.size()
	var dir := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
	var stride: float = _mesh.get_aabb().size.length() * 0.02
	for step in 24:
		_paint(_uvs[idx], WASH_UV_R, false)
		var target: Vector3 = _verts[idx] + dir * stride
		var best := idx
		var bd := INF
		for vi in _verts.size():
			var d := _verts[vi].distance_squared_to(target)
			if d < bd:
				bd = d
				best = vi
		if best == idx:
			break                            # 走不动了（停在原地）
		dir = ((_verts[best] - _verts[idx]).normalized() * 0.7 + dir * 0.3).normalized()
		idx = best

# 无尘顶点占比（0~1）。
func _coverage() -> float:
	if _uvs.is_empty():
		return 1.0
	var cleaned := 0
	for i in _uvs.size():
		var px := clampi(int(_uvs[i].x * MSZ), 0, MSZ - 1)
		var py := clampi(int(_uvs[i].y * MSZ), 0, MSZ - 1)
		if _mask_img.get_pixel(px, py).r > 0.5:
			cleaned += 1
	return float(cleaned) / float(_uvs.size())

# 把一笔冲刷画进遮罩：以 uv 为中心的软圆，取最大值累积。
func _paint(uv: Vector2, r: float, do_update: bool = true) -> void:
	var cx := uv.x * float(MSZ)
	var cy := uv.y * float(MSZ)
	var rp := r * float(MSZ)
	var x0 := int(maxf(0.0, floor(cx - rp)))
	var x1 := int(minf(MSZ - 1, ceil(cx + rp)))
	var y0 := int(maxf(0.0, floor(cy - rp)))
	var y1 := int(minf(MSZ - 1, ceil(cy + rp)))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x - cx, y - cy).length()
			if d > rp:
				continue
			var v := 1.0 - smoothstep(rp * 0.4, rp, d)
			if v > _mask_img.get_pixel(x, y).r:
				_mask_img.set_pixel(x, y, Color(v, v, v))
	if do_update:
		_mask_tex.update(_mask_img)

# 右上角按钮：刷新 → 交付(圆圈→对勾) → 重新开始。
func _on_topbtn() -> void:
	match _btn_state:
		ST_REFRESH:
			_restart()
		ST_CIRCLE:
			_enter_delivered()
		ST_DELIVERED:
			_restart()

# 冲刷达 99% → 进入“可交付”态：按钮变圆圈（仍可继续擦拭）。
func _enter_circle() -> void:
	_btn_state = ST_CIRCLE
	_refresh_btn.icon = load("res://textures/icon_circle.png")
	_sfx_ding.play()                        # 首次达 99% → 短“叮”提示可完成
	_save_state()

# 点击圆圈 → 交付：变对勾、奖励音、禁冲刷（只能旋转）。
func _enter_delivered() -> void:
	_btn_state = ST_DELIVERED
	_delivered = true
	_refresh_btn.icon = load("res://textures/icon_check.png")
	_washing = false
	_sfx_water.stop()
	_sfx_reward.play()
	if not _unlocked.has(_model_path):          # 解锁当前模型
		_unlocked.append(_model_path)
	if _map_btn != null:
		_map_btn.visible = true                 # 打勾后显示地图按钮
	_save_state()

# 刷新/重新开始：重置覆尘态并旋转 4 周。
func _restart() -> void:
	_btn_state = ST_REFRESH
	_delivered = false
	_refresh_btn.icon = load("res://textures/icon_refresh.png")
	if _map_btn != null:
		_map_btn.visible = false                    # 非交付态隐藏地图按钮
	_sfx_whoosh.play()                              # 刷新音效（配合旋转）
	_model_path = MODELS[randi() % MODELS.size()]   # 随机换模型
	_mask_img = Image.create(MSZ, MSZ, false, Image.FORMAT_L8)
	_build_model(_model_path)
	_seed_dust()
	_spin4()
	_save_state()

# 冲刷进度检测：无尘顶点占比 ≥ 99.9% → 进入可交付态。
func _check_coverage() -> void:
	if _btn_state != ST_REFRESH or _uvs.is_empty():
		return
	if _coverage() >= 0.999:
		_enter_circle()

# 让水晶旋转 4 整圈后回正；刷新按钮图标同步转 4 圈。
func _spin4() -> void:
	_spinning = true
	_manual_rot = Vector3.ZERO
	var axis := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
	if axis.length() < 0.01:
		axis = Vector3.UP
	axis = axis.normalized()
	var extra := randf_range(0.0, PI)                 # 4 整圈之外再随机多转 0~180°
	var tw := create_tween().set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(a: float): _world.transform = Transform3D(Basis(axis, a), Vector3.ZERO),
		0.0, TAU * 4.0 + extra, 1.9)
	# 停在这个随机朝向（不回正）：把静止朝向记为最终欧拉角。
	tw.tween_callback(func():
		_manual_rot = _world.rotation
		_spinning = false)
	if _refresh_btn != null:
		_refresh_btn.rotation = 0.0
		create_tween().set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT) \
			.tween_property(_refresh_btn, "rotation", TAU * 4.0, 1.9)

# 屏幕空间体积光（丁达尔/神光）：以水晶屏幕位置为光心，把亮部沿放射方向拖成光柱叠加。
func _build_godrays() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0                          # 在 3D 之上、UI 按钮(layer 1)之下
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_godray_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_add;                       // 叠加：只往画面加光，不遮挡

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform vec2 light_uv = vec2(0.5, 0.5);      // 水晶屏幕位置（光心）
uniform float density = 0.7;
uniform float decayf = 0.95;
uniform float weight = 0.5;
uniform float exposure = 1.0;
uniform float threshold = 0.72;              // 亮部阈值（用最大通道，蓝水晶也算亮）

const int SAMPLES = 32;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 delta = (uv - light_uv) * density / float(SAMPLES);
	vec3 col = vec3(0.0);
	float illum = 1.0;
	vec2 samp = uv;
	for (int i = 0; i < SAMPLES; i++) {
		samp -= delta;                       // 朝光心步进
		vec3 s = texture(screen_tex, samp).rgb;
		float bright = max(s.r, max(s.g, s.b));   // 最大通道：蓝色也计入亮度
		float b = max(0.0, bright - threshold);
		col += s * b * illum * weight;
		illum *= decayf;
	}
	COLOR = vec4(col * exposure, 1.0);
}
"""
	_godray_mat.shader = sh
	rect.material = _godray_mat
	layer.add_child(rect)

# 喷水水花粒子：擦拭时从接触点喷出小水珠，拖动时拉出水痕。世界坐标模拟。
func _build_spray_fx() -> void:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.amount = 48
	p.lifetime = 0.7
	p.lifetime_randomness = 0.5              # 寿命错开，避免整批同步生灭造成的脉动
	p.explosiveness = 0.0
	p.randomness = 0.5
	p.local_coords = false                 # 世界空间：拖动时留下水痕
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE_SURFACE   # 从小球面发射，不再单点堆成一团
	p.emission_sphere_radius = 0.003
	p.direction = Vector3(0.0, 0.5, 1.0).normalized()
	p.spread = 65.0
	p.initial_velocity_min = 2.2           # 提速：新生水珠立刻飞出，没有中心团
	p.initial_velocity_max = 4.2
	p.gravity = Vector3(0.0, -5.0, 0.0)
	p.damping_min = 1.0
	p.damping_max = 2.5
	p.scale_amount_min = 0.004
	p.scale_amount_max = 0.010
	# 生命周期透明度：出生满(×base 0.08)→在 80% 处就淡到 0 并保持，
	# 让末尾(含粒子回收边界)已全透明，避免结尾闪一下。
	# 不做逐颗淡入淡出：擦拭时所有水珠恒定；整体淡出交给松手时 tween 材质透明度。
	var qm := QuadMesh.new()
	qm.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX     # 普通混合，不再加法炸光
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = load("res://textures/droplet.png")   # 圆形水珠贴图
	mat.albedo_color = Color(0.6, 0.72, 0.9, DROP_ALPHA)   # 淡水色
	_droplet_mat = mat
	qm.material = mat
	p.mesh = qm
	add_child(p)
	_spray_fx = p

func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null

# ---------- 解锁画廊 ----------

func _toggle_gallery() -> void:
	_sfx_click.play()
	_in_gallery = not _in_gallery
	if _in_gallery:
		_enter_gallery()
	else:
		_exit_gallery()

func _enter_gallery() -> void:
	_world.visible = false                       # 藏起当前水晶
	_spray_fx.emitting = false
	_spray_fx.visible = false
	_toggle_btn.visible = false
	_refresh_btn.visible = false                 # 地图按钮保留(作返回)
	_cam_saved = _camera.transform
	_gal_yaw = 0.0
	_gal_pitch = 0.0
	_touches.clear()
	_build_gallery()

func _exit_gallery() -> void:
	if _gallery_root != null and is_instance_valid(_gallery_root):
		_gallery_root.queue_free()
		_gallery_root = null
	_world.visible = true
	_spray_fx.visible = true
	_toggle_btn.visible = true
	_refresh_btn.visible = true
	_camera.transform = _cam_saved
	_touches.clear()

# 把所有解锁过的模型摆成一排(干净水晶+各自内光)，相机取景。
func _build_gallery() -> void:
	if _gallery_root != null and is_instance_valid(_gallery_root):
		_gallery_root.queue_free()
	_gallery_root = Node3D.new()
	_gallery_root.position = GAL_ORIGIN
	add_child(_gallery_root)

	var models: Array = _unlocked.duplicate()
	if models.is_empty():
		models = [_model_path]
	var n := models.size()
	var spacing := 3.0
	var disp := 1.6                              # 每个模型展示尺寸
	# 全 1 遮罩 → 水晶层不 discard，显示为完全干净的水晶。
	var white := Image.create(4, 4, false, Image.FORMAT_L8)
	white.fill(Color(1, 1, 1))
	var wtex := ImageTexture.create_from_image(white)
	for i in n:
		var holder := Node3D.new()
		holder.position = Vector3((float(i) - float(n - 1) * 0.5) * spacing, 0.0, 0.0)
		_gallery_root.add_child(holder)
		var scene := (load(models[i]) as PackedScene).instantiate()
		var m := _find_mesh(scene)
		if m != null:
			var ab := m.get_aabb()
			var ext: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
			var sc := disp / maxf(ext, 0.0001)
			scene.scale = Vector3.ONE * sc
			scene.position = -(ab.get_center()) * sc   # 居中到 holder
			var cm := ShaderMaterial.new()
			cm.shader = _make_crystal_shader()
			cm.set_shader_parameter("wash_mask", wtex)
			m.material_override = cm
		holder.add_child(scene)
		# 每个模型一盏内光
		var lt := OmniLight3D.new()
		lt.position = holder.position
		lt.light_color = Color(0.5, 0.75, 1.0)
		lt.light_energy = 1.8
		lt.omni_range = disp * 2.4
		lt.shadow_enabled = false
		_gallery_root.add_child(lt)

	# 相机取景：让整排在屏宽内(KEEP_WIDTH, fov52)。
	var span: float = maxf(float(n) * spacing, 3.0)
	var d: float = span / 0.85 / (2.0 * tan(deg_to_rad(26.0)))
	_camera.transform = Transform3D(Basis.IDENTITY, GAL_ORIGIN + Vector3(0.0, 0.2, maxf(d, 3.5)))
	_camera.look_at(GAL_ORIGIN, Vector3.UP)

func _gallery_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _touches.size() == 1:
			_gal_drag_rotate(event.relative)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_gal_drag = event.pressed
	elif event is InputEventMouseMotion:
		if _gal_drag:
			_gal_drag_rotate(event.relative)

func _gal_drag_rotate(rel: Vector2) -> void:
	_gal_yaw += rel.x * 0.006
	_gal_pitch = clampf(_gal_pitch - rel.y * 0.006, -deg_to_rad(80.0), deg_to_rad(80.0))
	if _gallery_root != null and is_instance_valid(_gallery_root):
		_gallery_root.rotation = Vector3(_gal_pitch, _gal_yaw, 0.0)

# 灰尘层：不透明、写深度、剔除背面 —— 覆尘处实心不穿模；露出处丢弃交给水晶层。
func _make_dust_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, specular_disabled;

uniform sampler2D wash_mask : filter_linear;
uniform vec3 powder_color : source_color = vec3(0.34, 0.34, 0.36);

void fragment() {
	float reveal = texture(wash_mask, UV).r;
	if (reveal > 0.5) discard;                 // 露出处交给水晶层
	ALBEDO = powder_color;
	ROUGHNESS = 1.0;                           // 纯漫反射哑光
	METALLIC = 0.0;
}
"""
	return sh

# 水晶层：透明、双面、不写深度 —— 露出处通透可见背面刻面；覆尘处丢弃。
func _make_crystal_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, cull_disabled, specular_schlick_ggx;

uniform sampler2D wash_mask : filter_linear;
uniform vec3 diamond_color : source_color = vec3(0.12, 0.42, 0.92);

void fragment() {
	float reveal = texture(wash_mask, UV).r;
	if (reveal < 0.5) discard;                 // 覆尘处交给灰尘层
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	float crystal_alpha = mix(0.32, 0.9, fres);
	ALBEDO = diamond_color;
	ROUGHNESS = 0.02;
	METALLIC = 0.3;
	SPECULAR = 1.0;
	// 程序化环境强反光：按反射方向生成“影棚”亮斑，纯黑背景下也能强反光。
	vec3 fn2 = normalize(NORMAL);
	vec3 rd = reflect(-normalize(VIEW), fn2);
	vec3 rw = (INV_VIEW_MATRIX * vec4(rd, 0.0)).xyz;
	float env = smoothstep(0.15, 1.0, rw.y) * 0.5;
	env += pow(max(dot(rw, normalize(vec3(0.8, 0.7, 0.4))), 0.0), 50.0);
	env += pow(max(dot(rw, normalize(vec3(-0.7, 0.5, 0.6))), 0.0), 70.0);
	float fres2 = pow(1.0 - clamp(dot(fn2, normalize(VIEW)), 0.0, 1.0), 4.0);
	EMISSION = diamond_color * 0.55 + diamond_color * env * (0.7 + 1.4 * fres2);
	ALPHA = crystal_alpha;
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
		_wash_hitting = false                    # 拖到模型外：不喷水（由 _process 统一控制 emitting）
		return
	_wash_hitting = true
	_spray_fx.global_position = hit.position     # 水花从接触点喷出
	# 命中处最近顶点的 UV → 在遮罩上冲刷（UV 分岛天然只作用命中的那一面）。
	var local: Vector3 = _mesh.global_transform.affine_inverse() * (hit.position as Vector3)
	var bi := 0
	var bd := INF
	for vi in _verts.size():
		var dd := _verts[vi].distance_squared_to(local)
		if dd < bd:
			bd = dd
			bi = vi
	_paint(_uvs[bi], WASH_UV_R)

# ---------- 每帧 ----------

func _process(delta: float) -> void:
	if _in_gallery:                           # 画廊：只更新神光光心到画廊中心
		if _godray_mat != null:
			var gvp := get_viewport().get_visible_rect().size
			if gvp.x > 0.0 and gvp.y > 0.0:
				_godray_mat.set_shader_parameter("light_uv", _camera.unproject_position(GAL_ORIGIN) / gvp)
		return
	if _spinning:
		return                                # 旋转 4 周动画期间由 tween 接管
	if _washing:
		_spray(_wash_screen)                 # 更新 _wash_hitting
		if not _sfx_water.playing:
			_sfx_water.play()
		_cov_tick += 1
		if _cov_tick >= 12:                        # 节流：约每 12 帧查一次覆盖率
			_cov_tick = 0
			_check_coverage()
	else:
		_wash_hitting = false
	# 只在"擦拭中 + 命中模型 + 本帧手指移动"时喷水珠：停下/松手就不再生成，避免叠加变亮。
	var want_emit := _washing and _wash_hitting and _moved
	if _spray_fx.emitting != want_emit:
		_spray_fx.emitting = want_emit
	_moved = false                            # 每帧消费，无余量
	var target := _manual_rot
	var weight := 1.0 - pow(0.002, delta)
	_world.rotation = _world.rotation.lerp(target, weight)
	# 神光光心 = 水晶中心（原点）的屏幕位置。
	if _godray_mat != null:
		var vp := get_viewport().get_visible_rect().size
		if vp.x > 0.0 and vp.y > 0.0:
			var sp := _camera.unproject_position(Vector3.ZERO)
			_godray_mat.set_shader_parameter("light_uv", sp / vp)

# ---------- 输入 ----------

func _set_washing(on: bool, pos: Vector2) -> void:
	if on and not _washing:
		_washing = true
		_wash_screen = pos
		if _fade_tween != null and _fade_tween.is_valid():
			_fade_tween.kill()              # 取消淡出
		var c := _droplet_mat.albedo_color
		c.a = DROP_ALPHA                    # 恢复满透明度
		_droplet_mat.albedo_color = c
		_spray_fx.restart()                # 清掉上次残留(淡透明但未死)的水珠，避免第二下"突然一堆"
	elif not on and _washing:
		_washing = false
		_sfx_water.stop()
		# 松手：整个喷水系统在 0.4s 内整体淡出到 0。
		if _fade_tween != null and _fade_tween.is_valid():
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_droplet_mat, "albedo_color:a", 0.0, 0.4)
		_save_state()                       # 每次擦拭松手保存进度

func _unhandled_input(event: InputEvent) -> void:
	if _in_gallery:
		_gallery_input(event)
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() == 1:
			var pos: Vector2 = _touches.values()[0]
			if not _delivered and _hit_model(pos):
				_set_washing(true, pos)         # 指到模型 → 冲刷
			else:
				_bg_rotating = true             # 背景 / 已交付 → 只旋转画面
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
				_moved = true                   # 移动了 → 本帧喷水
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
				if not _delivered and _hit_model(event.position):
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
			_moved = true                   # 移动了 → 本帧喷水
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
