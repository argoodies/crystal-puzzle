extends Node3D
## 擦水晶 — 粉末冲刷。一枚拼图状钻石（GLB 模型）表面覆盖白粉；
## 触击并保持长按 → 向指到的位置持续喷水冲刷，露出下面光滑的蓝钻表面；拖动可移动冲刷点。
## 冲刷用模型局部空间的“冲刷点”做遮罩：冲刷点附近由白粉过渡为钻石。
## 单指=冲刷；双指=缩放+旋转视角。保留日/夜灯光。iOS 与 Web 同一套代码。

const TARGET_W := 3.6                    # 模型最长边世界尺寸（放大 2 倍）
const ROT_SENS := 0.006
const MIN_ZOOM := 3.08                    # 最近：水晶约占屏宽 120%
const MAX_ZOOM := 10.85                   # 最远：水晶约占屏宽 34%
const SAVE_STATE := "user://wipe_state.json" # 偏好：日/夜 + 已解锁
const MSZ := 1024                        # 冲刷遮罩纹理尺寸（更高→边缘更细腻）
const WASH_UV_R := 0.124                  # 冲刷笔刷半径（UV 空间，面积约 2 倍）
const SEED_UV_R := 0.013                  # 初始无尘点半径（UV 空间）

const MODELS := ["res://models/puzzle.glb", "res://models/chariot.glb"]

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
var _circle_btn: Button                     # 底部中央：达标圆圈→交付对勾
var _play_btn: Button                       # 底部中央：▶️ 随机下一关
var _spinning := false                     # 旋转4周动画中，暂停常规旋转/冲刷

const ST_REFRESH := 0                       # 右上角按钮状态：刷新
const ST_CIRCLE := 1                        # 可交付：圆圈
const ST_DELIVERED := 2                     # 已交付：对勾
var _btn_state := ST_REFRESH
var _deliver_lock := false                  # 交付对勾后 1 秒锁定（不可点）
var _intro_btns := false                     # 覆尘关卡：右上画廊+播放当前是否显示（开局显示，操作后淡出，闲置回归）
var _idle_time := 0.0                         # 覆尘态无擦拭/旋转的累计秒数（≥3s 让右上按钮重新出现）
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
var _godray_layer: CanvasLayer
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

# ---------- 成就空间（完成过的模型按次数漂浮展示）----------
const ROOM_CAP := 200                          # 每种模型最多实例数（性能上限）
const TABLE_SPACING := 2.6                      # 桌面上模型的密堆积间距
const TABLE_DISP := 0.55                        # 模型在桌上的显示缩放（相对 TARGET_W）
const BOARD_LEN := 40.0                         # 桌板长边（约拼图的 20 倍，拼图桌上显示 ~2 单位）
const ROOM_CENTER_Y := 2.0                      # 相机注视点高度（桌面之上）
const ELEV_MIN := 0.05                            # 相机仰角下限：略高于棋盘平面（不得转到平面以下）
const ELEV_MAX := 1.52                            # 上限：近俯视
var _map_btn: Button
var _in_room := false
var _room_root: Node3D                        # 成就空间根
var _room_yaw := 0.0
var _room_pitch := 1.22                          # 相机仰角(弧度)，默认 ~70°
var _room_dist := 30.0                          # 相机到注视点距离（随规模自适应）
var _room_dragging := false
var _room_touches: Dictionary = {}              # 空间内多点触摸（拖拽=旋转，双指=缩放）
var _room_pinch := 0.0                           # 上一帧双指间距
var _room_yaw_vel := 0.0                         # 松手后惯性角速度（弧度/秒）
var _room_pitch_vel := 0.0
var _room_grab_mmi: MultiMeshInstance3D          # 正在拖动的水晶所属 MultiMesh
var _room_grab_idx := -1                          # 正在拖动的实例索引
var _cam_saved := Transform3D.IDENTITY
var _counts: Dictionary = {}                  # 模型 path -> 完成(交付)次数
var _centered_cache: Dictionary = {}          # path -> 居中归一化后的 ArrayMesh 缓存
var _centered_h: Dictionary = {}              # path -> 归一化后 Y 半高（用于贴桌面）

func _ready() -> void:
	randomize()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_build_spray_fx()
	_world = Node3D.new()
	add_child(_world)
	_load_prefs()                             # 只读 日/夜 + 已解锁（不保存半程进度）
	_build_godrays()
	_build_toggle()
	if _night:
		_apply_lighting(false)
	# 每次启动都是一个新的未完成水晶。
	_load_random_level()

# ---------- 存档 ----------

# 只持久化偏好：日/夜 + 已解锁模型（不保存半程擦拭进度）。
func _save_state() -> void:
	var f := FileAccess.open(SAVE_STATE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"night": _night, "counts": _counts}))
		f.close()

func _load_prefs() -> void:
	if not FileAccess.file_exists(SAVE_STATE):
		return
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(SAVE_STATE))
	if cfg is Dictionary:
		_night = bool(cfg.get("night", false))
		var cnt = cfg.get("counts", {})
		if cnt is Dictionary:
			for p in cnt:
				if p in MODELS:
					_counts[p] = int(cnt[p])
		# 兼容旧存档：unlocked 数组 → 各计 1 次
		var ul = cfg.get("unlocked", [])
		if ul is Array:
			for p in ul:
				if p in MODELS and not _counts.has(p):
					_counts[p] = 1

# 按当前 _btn_state 恢复底部按钮显示。
func _apply_bottom_state() -> void:
	if _btn_state == ST_CIRCLE:
		_show_circle()
	elif _btn_state == ST_DELIVERED:
		_show_intro_btns(false)
	else:
		_hide_bottom_ui()

# 载入一个随机的未完成(覆尘)水晶，重新开始擦拭。
func _load_random_level() -> void:
	_btn_state = ST_REFRESH
	_delivered = false
	_model_path = MODELS[randi() % MODELS.size()]
	_mask_img = Image.create(MSZ, MSZ, false, Image.FORMAT_L8)
	_build_model(_model_path)
	_seed_dust()
	_spin4()
	_show_intro_btns()                          # 开局右上先亮画廊+播放，首次擦拭/旋转后淡出
	_save_state()

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
	_wire_press(_toggle_btn)
	_apply_glass(_toggle_btn)
	layer.add_child(_toggle_btn)

	# 底部中央：达标圆圈 / 交付对勾（同一个按钮切换图标）。
	_circle_btn = _make_flat_btn("res://textures/icon_circle.png")
	_circle_btn.pressed.connect(_on_circle)
	_circle_btn.visible = false
	layer.add_child(_circle_btn)

	# 底部中央双按钮：画廊 + ▶️ 随机下一关（交付后出现）。
	_map_btn = _make_flat_btn("res://textures/icon_map.png")
	_map_btn.pressed.connect(_toggle_gallery)
	_map_btn.visible = false
	_apply_glass(_map_btn)
	layer.add_child(_map_btn)
	_play_btn = _make_flat_btn("res://textures/icon_play.png")
	_play_btn.pressed.connect(_play_next)
	_play_btn.visible = false
	_apply_glass(_play_btn)
	layer.add_child(_play_btn)

	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)

# 毛玻璃透镜底：半透明白 + 圆角 + 亮边 + 柔光，营造 2D 玻璃按钮质感。
func _glass_style(pressed := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 1.0, 1.0, 0.06 if pressed else 0.0)
	sb.set_corner_radius_all(44)
	sb.set_border_width_all(2)
	sb.border_color = Color(1.0, 1.0, 1.0, 0.24)
	sb.shadow_color = Color(0.6, 0.8, 1.0, 0.08)   # 淡蓝柔光（减弱）
	sb.shadow_size = 8
	sb.set_content_margin_all(18.0)                # 图标内缩，四周留玻璃边
	return sb

func _apply_glass(b: Button) -> void:
	b.flat = false
	b.add_theme_stylebox_override("normal", _glass_style())
	b.add_theme_stylebox_override("hover", _glass_style())
	b.add_theme_stylebox_override("pressed", _glass_style(true))
	b.add_theme_stylebox_override("focus", _glass_style())

func _make_flat_btn(icon_path: String) -> Button:
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.icon = load(icon_path)
	b.expand_icon = true
	_wire_press(b)
	return b

# 给按钮加"按下弹一下"反馈：绕中心先放大再缩回。
func _wire_press(b: BaseButton) -> void:
	b.button_down.connect(func(): _press_pop(b))

func _press_pop(b: Control) -> void:
	if not is_instance_valid(b):
		return
	b.pivot_offset = b.size * 0.5             # 绕中心缩放
	var tw := create_tween().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(b, "scale", Vector2(1.4, 1.4), 0.10).set_ease(Tween.EASE_OUT)
	tw.tween_property(b, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_IN_OUT)

func _apply_safe_area() -> void:
	var btn := 144.0                           # 左上日/夜按钮
	var bbtn := 200.0                          # 底部一排按钮（更大）
	var m := 40.0
	var vis := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	var top := m
	var left := m
	var right := m
	var bottom := m
	if win.x > 1.0 and win.y > 1.0:
		var sc := Vector2(vis.x / win.x, vis.y / win.y)
		var safe := DisplayServer.get_display_safe_area()
		top = safe.position.y * sc.y + m
		left = safe.position.x * sc.x + m
		right = (win.x - (safe.position.x + safe.size.x)) * sc.x + m
		bottom = (win.y - (safe.position.y + safe.size.y)) * sc.y + m
	# 日/夜：左上角
	_toggle_btn.offset_left = left
	_toggle_btn.offset_right = left + btn
	_toggle_btn.offset_top = top
	_toggle_btn.offset_bottom = top + btn
	# 圆圈：底部中央（靠近下方，但抬高一些）。
	if _circle_btn != null:
		var yb := bottom + 210.0
		_circle_btn.anchor_left = 0.5
		_circle_btn.anchor_right = 0.5
		_circle_btn.anchor_top = 1.0
		_circle_btn.anchor_bottom = 1.0
		_circle_btn.offset_left = -bbtn * 0.5
		_circle_btn.offset_right = bbtn * 0.5
		_circle_btn.offset_bottom = -yb
		_circle_btn.offset_top = -yb - bbtn
	# 交付后：画廊 + 播放，右上角横向排列，与日/夜同大(btn)。播放最靠右，画廊在其左。
	var g := 28.0                              # 两按钮间距
	if _play_btn != null:
		_play_btn.anchor_left = 1.0
		_play_btn.anchor_right = 1.0
		_play_btn.offset_right = -right
		_play_btn.offset_left = -right - btn
		_play_btn.offset_top = top
		_play_btn.offset_bottom = top + btn
	if _map_btn != null:
		_map_btn.anchor_left = 1.0
		_map_btn.anchor_right = 1.0
		_map_btn.offset_right = -right - btn - g
		_map_btn.offset_left = -right - btn - g - btn
		_map_btn.offset_top = top
		_map_btn.offset_bottom = top + btn

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

# —— 针对任意网格生成"约 20% 已擦"的种子遮罩（画廊未完成关用，手感同主游戏）——
func _make_seeded_mask(verts: PackedVector3Array, uvs: PackedVector2Array, diag: float) -> Image:
	var img := Image.create(MSZ, MSZ, false, Image.FORMAT_L8)
	img.fill(Color(0, 0, 0))
	if verts.is_empty() or uvs.is_empty():
		return img
	var guard := 0
	while _mask_coverage(img, uvs) < 0.20 and guard < 30:
		_seed_stroke(img, verts, uvs, diag)
		guard += 1
	return img

func _seed_stroke(img: Image, verts: PackedVector3Array, uvs: PackedVector2Array, diag: float) -> void:
	var idx := randi() % verts.size()
	var dir := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
	var stride: float = diag * 0.02
	for step in 24:
		_paint_into(img, uvs[idx], WASH_UV_R)
		var target: Vector3 = verts[idx] + dir * stride
		var best := idx
		var bd := INF
		for vi in verts.size():
			var d := verts[vi].distance_squared_to(target)
			if d < bd:
				bd = d
				best = vi
		if best == idx:
			break
		dir = ((verts[best] - verts[idx]).normalized() * 0.7 + dir * 0.3).normalized()
		idx = best

func _mask_coverage(img: Image, uvs: PackedVector2Array) -> float:
	if uvs.is_empty():
		return 1.0
	var cleaned := 0
	for i in uvs.size():
		var px := clampi(int(uvs[i].x * MSZ), 0, MSZ - 1)
		var py := clampi(int(uvs[i].y * MSZ), 0, MSZ - 1)
		if img.get_pixel(px, py).r > 0.5:
			cleaned += 1
	return float(cleaned) / float(uvs.size())

func _paint_into(img: Image, uv: Vector2, r: float) -> void:
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
			if v > img.get_pixel(x, y).r:
				img.set_pixel(x, y, Color(v, v, v))

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

# ---------- 底部按钮：圆圈 / 对勾 / 双按钮(画廊+播放) ----------

func _hide_bottom_ui() -> void:
	if _circle_btn != null:
		_circle_btn.visible = false
	if _map_btn != null:
		_map_btn.visible = false
	if _play_btn != null:
		_play_btn.visible = false

# 显示达标圆圈（淡入），隐藏双按钮。
func _show_circle() -> void:
	_hide_bottom_ui()
	_circle_btn.icon = load("res://textures/icon_circle.png")
	_circle_btn.disabled = false
	_circle_btn.modulate.a = 0.0
	_circle_btn.visible = true
	create_tween().tween_property(_circle_btn, "modulate:a", 1.0, 0.3)

# 显示双按钮（画廊 + ▶️）。animate=true 时淡入。
func _reveal_dual(animate: bool) -> void:
	if _circle_btn != null:
		_circle_btn.visible = false
	_map_btn.visible = true
	_play_btn.visible = true
	var a0 := 0.0 if animate else 1.0
	_map_btn.modulate.a = a0
	_play_btn.modulate.a = a0
	if animate:
		var tw := create_tween().set_parallel(true)
		tw.tween_property(_map_btn, "modulate:a", 1.0, 0.4)
		tw.tween_property(_play_btn, "modulate:a", 1.0, 0.4)

# 右上画廊+播放显示为"活跃可淡出"态（擦拭/旋转淡出，静止 3s 回归）。覆尘态与交付态共用。
func _show_intro_btns(animate := true) -> void:
	_reveal_dual(animate)
	_intro_btns = true
	_idle_time = 0.0

# 首次擦拭/旋转 → 让开局的画廊+播放淡出隐藏。
func _fade_out_intro_btns() -> void:
	if not _intro_btns:
		return
	_intro_btns = false
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_map_btn, "modulate:a", 0.0, 0.4)
	tw.tween_property(_play_btn, "modulate:a", 0.0, 0.4)
	tw.chain().tween_callback(func():
		if _map_btn != null: _map_btn.visible = false
		if _play_btn != null: _play_btn.visible = false)

# 冲刷达标 → 底部中央淡入圆圈（仍可继续擦拭）。
func _enter_circle() -> void:
	_btn_state = ST_CIRCLE
	_show_circle()
	_sfx_ding.play()                        # 首次达 99% → 短“叮”提示可完成
	_save_state()

# 点击圆圈 → 交付：圆圈变对勾、奖励音、禁冲刷；1 秒后对勾渐隐，双按钮渐现。
func _on_circle() -> void:
	if _deliver_lock:
		return
	_enter_delivered()

func _enter_delivered() -> void:
	_btn_state = ST_DELIVERED
	_delivered = true
	_washing = false
	_sfx_water.stop()
	_sfx_reward.play()
	_counts[_model_path] = int(_counts.get(_model_path, 0)) + 1   # 完成次数 +1
	_save_state()
	# 圆圈变对勾并锁定，1 秒后对勾渐隐 → 双按钮渐现。
	_circle_btn.icon = load("res://textures/icon_check.png")
	_circle_btn.modulate.a = 1.0
	_circle_btn.visible = true
	_deliver_lock = true
	var tw := create_tween()
	tw.tween_interval(1.0)
	tw.tween_property(_circle_btn, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func():
		_circle_btn.visible = false
		_deliver_lock = false
		if _btn_state == ST_DELIVERED:
			_show_intro_btns())          # 刚完成额外显示；之后旋转淡出、静止回归

# ▶️ 播放：换关（随机一个未清洗水晶）。换关本身只出按键音。
# 稍等一下再换关，让按钮"变大"动效先播完（否则底部按钮会立刻隐藏，看不到弹动）。
func _play_next() -> void:
	_sfx_click.play()
	var tw := create_tween()
	tw.tween_interval(0.22)
	tw.tween_callback(_load_random_level)

# 冲刷进度检测：无尘顶点占比达 100% → 进入可交付态。
func _check_coverage() -> void:
	if _btn_state != ST_REFRESH or _uvs.is_empty():
		return
	if _coverage() >= 1.0:
		_enter_circle()

# 让水晶旋转 4 整圈后停在随机朝向。
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

# 屏幕空间体积光（丁达尔/神光）：以水晶屏幕位置为光心，把亮部沿放射方向拖成光柱叠加。
func _build_godrays() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0                          # 在 3D 之上、UI 按钮(layer 1)之下
	add_child(layer)
	_godray_layer = layer
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

# ---------- 成就空间 ----------
# 点画廊按钮进入一个沉浸空间：按完成次数摆放你清扫过的每种模型（如 10 个 puzzle、5 个车），
# 全在空间里漂浮 + 轻微自转，拖屏旋转整个空间的视角。
# 性能：每种模型用一个 MultiMeshInstance3D（1 次 draw call 画任意数量），
#       不透明材质（写深度，硬件早 Z 天然做遮挡剔除），自转/浮动放到顶点着色器里（零 CPU）。

func _toggle_gallery() -> void:
	_sfx_click.play()
	if _in_room:
		_close_room()
	else:
		_open_room()

func _open_room() -> void:
	_in_room = true
	_touches.clear()
	_world.visible = false
	_spray_fx.emitting = false
	_spray_fx.visible = false
	_toggle_btn.visible = false
	_hide_bottom_ui()
	if _map_btn != null:
		_map_btn.visible = true                   # 保留地图按钮作返回（再点退出）
		_map_btn.modulate.a = 1.0
	# 神光保留开启（下面 _process 里把光心设到空间中心）。
	_cam_saved = _camera.transform
	_room_yaw = 0.0
	_room_pitch = 1.22
	_room_dragging = false
	_room_touches.clear()
	if _room_root != null and is_instance_valid(_room_root):
		_room_root.queue_free()
	_room_root = Node3D.new()
	add_child(_room_root)
	# 格子边长 = 车的桌面占地（≈ TARGET_W * 显示缩放），让车刚好占一格。
	var cell := TARGET_W * TABLE_DISP * 1.12
	# 中心向外的格子中心列表（一物一格），全局按类型顺序分配。
	var total := 0
	for path in MODELS:
		total += mini(int(_counts.get(path, 0)), ROOM_CAP)
	var cells := _gen_cells(maxi(total, 1), cell)
	# 透明水晶棋盘格：格子随视野铺满，中心向外自适应大小。
	var grid_half: float = sqrt(float(maxi(total, 1))) * cell * 0.9 + cell * 3.0
	var board: float = maxf(24.0, grid_half * 2.0)
	var plane := MeshInstance3D.new()
	var pmesh := PlaneMesh.new()
	pmesh.size = Vector2(board, board)
	plane.mesh = pmesh
	var pmat := ShaderMaterial.new()
	pmat.shader = _make_light_plane_shader()
	pmat.set_shader_parameter("board", board)
	plane.material_override = pmat
	_room_root.add_child(plane)
	# 真实灯光照亮水晶：高处俯照 + 中心补光。
	var top := SpotLight3D.new()
	top.position = Vector3(0, 36, 0)
	top.rotation = Vector3(-PI * 0.5, 0, 0)                     # 朝下
	top.light_energy = 14.0; top.spot_range = 120.0; top.spot_angle = 46.0
	top.light_color = Color(0.85, 0.92, 1.0); top.shadow_enabled = false
	_room_root.add_child(top)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0, 4, 0); fill.light_energy = 3.0; fill.omni_range = board
	fill.light_color = Color(0.5, 0.65, 1.0); fill.shadow_enabled = false
	_room_root.add_child(fill)
	# 每种"完成过"的模型 → 一个 MultiMeshInstance3D，一物一格摆在棋盘上。
	var g := 0
	for path in MODELS:
		var cnt := mini(int(_counts.get(path, 0)), ROOM_CAP)
		if cnt <= 0:
			continue
		_room_root.add_child(_build_room_multimesh(path, cnt, g, cells))
		g += cnt
	# 相机距离随棋盘范围自适应。
	_room_dist = clampf(grid_half * 2.0 + 10.0, 16.0, 120.0)
	_update_room_cam()

# 生成 n 个"中心向外"排序的格子中心（世界 XZ），每格间隔 cell。
func _gen_cells(n: int, cell: float) -> PackedVector2Array:
	var k := int(ceil(sqrt(float(n)))) + 2
	var all: Array = []
	for c in range(-k, k + 1):
		for r in range(-k, k + 1):
			all.append(Vector2(float(c), float(r)))
	all.sort_custom(func(a, b): return a.length_squared() < b.length_squared())
	var out := PackedVector2Array()
	for i in mini(n, all.size()):
		out.append((all[i] as Vector2) * cell)
	return out

func _close_room() -> void:
	_in_room = false
	if _room_root != null and is_instance_valid(_room_root):
		_room_root.queue_free()
		_room_root = null
	_world.visible = true
	_spray_fx.visible = true
	_toggle_btn.visible = true
	_apply_bottom_state()
	_camera.transform = _cam_saved
	_touches.clear()
	_room_touches.clear()
	_room_release()

# 归一化+居中后的 ArrayMesh（顶点减去中心、乘缩放），供 MultiMesh 复用；同时缓存半高。
func _centered_mesh(path: String) -> ArrayMesh:
	if _centered_cache.has(path):
		return _centered_cache[path]
	var scene := (load(path) as PackedScene).instantiate()
	var m := _find_mesh(scene)
	var out := ArrayMesh.new()
	var halfy := TARGET_W * 0.5
	if m != null and m.mesh != null:
		var ab := m.get_aabb()
		var ext: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
		var sc := TARGET_W / maxf(ext, 0.0001)
		halfy = ab.size.y * sc * 0.5                 # 归一化后 Y 半高
		var center := ab.get_center()
		var arrays := m.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nv := PackedVector3Array(); nv.resize(verts.size())
		for i in verts.size():
			nv[i] = (verts[i] - center) * sc
		arrays[Mesh.ARRAY_VERTEX] = nv
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	scene.queue_free()
	_centered_cache[path] = out
	_centered_h[path] = halfy
	return out

func _build_room_multimesh(path: String, count: int, start_g: int, cells: PackedVector2Array) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _centered_mesh(path)
	mm.instance_count = count
	var lift: float = float(_centered_h.get(path, TARGET_W * 0.5)) * TABLE_DISP   # 底面贴平面
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hash(path)) + start_g * 7919
	for i in count:
		# 一物一格：按全局中心向外顺序落在棋盘格中心。
		var g := start_g + i
		var c2: Vector2 = cells[g] if g < cells.size() else Vector2.ZERO
		var pos := Vector3(c2.x, lift, c2.y)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * TABLE_DISP)
		mm.set_instance_transform(i, Transform3D(basis, pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = _make_room_shader()
	mmi.material_override = mat
	return mmi

func _update_room_cam() -> void:
	# 球坐标环绕桌面注视点：仰角 _room_pitch 受限([60°,88°])，桌板倾斜≤30°。
	var e := _room_pitch
	var center := Vector3(0.0, ROOM_CENTER_Y, 0.0)
	var dirv := Vector3(cos(e) * sin(_room_yaw), sin(e), cos(e) * cos(_room_yaw))
	_camera.transform = Transform3D(Basis.IDENTITY, center + dirv * _room_dist)
	_camera.look_at(center, Vector3.UP)

# 成就空间内触摸：单指拖拽旋转视角，双指捏合缩放；鼠标滚轮也可缩放。
func _room_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_room_touches[event.index] = event.position
			_room_yaw_vel = 0.0                       # 抓住时停止惯性
			_room_pitch_vel = 0.0
			if _room_touches.size() == 1:
				_room_pick(event.position)            # 单指落在水晶上 → 拿起它
		else:
			_room_touches.erase(event.index)
			if _room_touches.size() == 0:
				_room_release()
		if _room_touches.size() == 2:
			_room_release()                           # 双指改缩放，放下水晶
			_room_pinch = _room_two_dist()
	elif event is InputEventScreenDrag:
		if _room_touches.has(event.index):
			_room_touches[event.index] = event.position
		if _room_touches.size() == 1:
			if _room_grab_idx >= 0:
				_room_move(event.position)            # 拖动水晶
			else:
				_room_orbit(event.relative)           # 拖动空白 → 旋转视角
		elif _room_touches.size() == 2:
			var d := _room_two_dist()
			if _room_pinch > 0.0:
				_room_zoom(d - _room_pinch)       # 张开=拉近，收拢=拉远
			_room_pinch = d
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_room_dragging = event.pressed
			if event.pressed:
				_room_yaw_vel = 0.0
				_room_pitch_vel = 0.0
				_room_pick(event.position)
			else:
				_room_release()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_room_zoom(40.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_room_zoom(-40.0)
	elif event is InputEventMouseMotion:
		if _room_dragging:
			if _room_grab_idx >= 0:
				_room_move((event as InputEventMouseMotion).position)
			else:
				_room_orbit((event as InputEventMouseMotion).relative)

const ROOM_PICK_R := 1.4                          # 拾取阈值（世界半径）

# 射线拾取离视线最近的水晶实例；命中则记为"拿起"。
func _room_pick(pos: Vector2) -> void:
	_room_grab_mmi = null
	_room_grab_idx = -1
	if _room_root == null or not is_instance_valid(_room_root):
		return
	var from := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	var best_t := INF
	for child in _room_root.get_children():
		if not (child is MultiMeshInstance3D):
			continue
		var mm: MultiMesh = (child as MultiMeshInstance3D).multimesh
		for i in mm.instance_count:
			var o := mm.get_instance_transform(i).origin
			var t: float = (o - from).dot(dir)
			if t < 0.1:
				continue
			var perp := (from + dir * t).distance_to(o)
			if perp < ROOM_PICK_R and t < best_t:
				best_t = t
				_room_grab_mmi = child
				_room_grab_idx = i

func _room_release() -> void:
	_room_grab_mmi = null
	_room_grab_idx = -1

# 把拿起的水晶沿桌面(其所在高度水平面)移到手指处，限制在桌板内。
func _room_move(pos: Vector2) -> void:
	if _room_grab_idx < 0 or _room_grab_mmi == null or not is_instance_valid(_room_grab_mmi):
		return
	var mm: MultiMesh = _room_grab_mmi.multimesh
	var xf := mm.get_instance_transform(_room_grab_idx)
	var from := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	if absf(dir.y) < 0.0001:
		return
	var t := (xf.origin.y - from.y) / dir.y          # 与该高度水平面求交
	if t < 0.0:
		return
	var hit := from + dir * t
	var lim := BOARD_LEN * 0.5 - 1.0
	var np := Vector3(clampf(hit.x, -lim, lim), xf.origin.y, clampf(hit.z, -lim, lim))
	mm.set_instance_transform(_room_grab_idx, Transform3D(xf.basis, np))

func _room_two_dist() -> float:
	var pts := _room_touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _room_orbit(rel: Vector2) -> void:
	var dyaw := -rel.x * ROT_SENS
	var dpitch := rel.y * ROT_SENS
	_room_yaw += dyaw
	_room_pitch = clampf(_room_pitch + dpitch, ELEV_MIN, ELEV_MAX)   # 仰角受限，桌板俯视≤30°倾斜
	var dt := maxf(get_process_delta_time(), 0.0001)
	_room_yaw_vel = dyaw / dt                                        # 记录角速度供松手惯性
	_room_pitch_vel = dpitch / dt
	_update_room_cam()

func _room_zoom(delta_px: float) -> void:
	_room_dist = clampf(_room_dist - delta_px * 0.03, 4.0, 60.0)   # 拉近/拉远
	_update_room_cam()

# 不透明"成就水晶"材质：顶点着色器做每实例自转 + 上下浮动（零 CPU），
# 写深度 → 硬件早 Z 天然做遮挡剔除，避免透明叠加与排序开销。
func _make_room_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back, specular_schlick_ggx;
uniform vec3 tint : source_color = vec3(0.16, 0.45, 0.95);
void vertex() {
	float sd = float(INSTANCE_ID) * 2.3999632;
	float ang = TIME * 0.3 + sd;
	float s = sin(ang), c = cos(ang);
	mat2 R = mat2(vec2(c, -s), vec2(s, c));
	VERTEX.xz = R * VERTEX.xz;                     // 绕竖直轴在桌面上原地慢转
	NORMAL.xz = R * NORMAL.xz;
}
void fragment() {
	vec3 N = normalize(NORMAL);
	float fres = pow(1.0 - clamp(dot(N, normalize(VIEW)), 0.0, 1.0), 2.5);
	ALBEDO = tint * 0.35;
	METALLIC = 0.35;
	ROUGHNESS = 0.12;
	SPECULAR = 0.9;
	EMISSION = tint * (0.35 + 1.5 * fres);        // 边缘辉光，像发光水晶
}
"""
	return sh

# 透明水晶板（代替桌板）：半透明泛蓝玻璃质感，中心微微内发光，边缘淡出。
func _make_light_plane_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, specular_schlick_ggx;
uniform vec3 tint : source_color = vec3(0.32, 0.56, 1.0);
uniform float board = 40.0;
varying vec3 wpos;
void vertex() { wpos = VERTEX; }        // PlaneMesh 在原点无缩放 → 局部即世界 XZ
void fragment() {
	float d = length(wpos.xz);
	float fade = smoothstep(board * 0.5, board * 0.30, d);  // 边缘淡出
	ALBEDO = tint;
	METALLIC = 0.2;
	ROUGHNESS = 0.06;
	SPECULAR = 0.9;
	EMISSION = tint * 0.18;                        // 淡淡内发光
	ALPHA = 0.22 * fade;                           // 半透明水晶
}
"""
	return sh

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
	if _in_room:                              # 成就空间：自转/浮动在 shader 里跑
		# 松手后的旋转惯性（不在拖拽时才滑行，带指数衰减）。
		var dragging := _room_dragging or _room_touches.size() >= 1
		if not dragging and (absf(_room_yaw_vel) > 0.002 or absf(_room_pitch_vel) > 0.002):
			_room_yaw += _room_yaw_vel * delta
			var pv := _room_pitch + _room_pitch_vel * delta
			_room_pitch = clampf(pv, ELEV_MIN, ELEV_MAX)
			if _room_pitch != pv:
				_room_pitch_vel = 0.0             # 撞到仰角上下限就停竖直惯性
			var damp := pow(0.05, delta)
			_room_yaw_vel *= damp
			_room_pitch_vel *= damp
			_update_room_cam()
		if _godray_mat != null:                   # 神光光心 = 空间中心
			var rvp := get_viewport().get_visible_rect().size
			if rvp.x > 0.0 and rvp.y > 0.0:
				_godray_mat.set_shader_parameter("light_uv", _camera.unproject_position(Vector3.ZERO) / rvp)
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
	# 覆尘态与交付态：擦拭中清零；否则累计闲置，满 3s 让右上按钮重新淡入。
	if _btn_state == ST_REFRESH or _btn_state == ST_DELIVERED:
		if _washing:
			_idle_time = 0.0
		elif not _intro_btns:
			_idle_time += delta
			if _idle_time >= 3.0:
				_show_intro_btns()
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
		_idle_time = 0.0
		_fade_out_intro_btns()             # 首次擦拭 → 右上按钮淡出
		_wash_screen = pos
		_spray(pos)                        # 先把发射点移到当前触点，否则 restart 会在上次松手位置喷出残留水珠
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
	if _in_room:
		_room_input(event)
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
	if delta.length() > 1.0:
		_idle_time = 0.0                       # 旋转即活跃，重置闲置计时
		if _intro_btns:                        # 旋转 → 右上按钮淡出
			_fade_out_intro_btns()
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
