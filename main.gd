extends Node3D
## DeskFeel — 真 3D 桌板（Godot 版）。
## 紫绒布板随手机重力倾斜、聚光灯打光、令牌可拖拽并有落桌声。
## 三枚令牌：🧩 解谜大师 / ✝️ 异端分子 / 👻 阎罗。
## iOS 与 Web（GitHub Pages）同一套代码。场景全部脚本生成。

const BOARD_SCALE := 3.0                    # GLB 模型放大倍数
const MODEL_HX := 0.4887                    # 模型半宽（X，来自 GLB 包围盒）
const MODEL_HY := 0.0417                    # 模型半厚（Y）
const MODEL_HZ := 0.4896                    # 模型半深（Z）
const TOP_SURF := MODEL_HY * BOARD_SCALE    # 缩放后毛毯面高度
const BOARD_SIZE := Vector2(MODEL_HX * 2.0 * BOARD_SCALE, MODEL_HZ * 2.0 * BOARD_SCALE)
const TOKEN_RADIUS := 0.22
const TOKEN_HEIGHT := 0.014                 # 纸板厚度
const BUTTON_RADIUS := 0.11                 # 小纽扣半径
const BUTTON_HEIGHT := 0.012
# 4 枚小纽扣：板面下方约 3/4 处一排（z=1.10、x 居中）；2 拼图 + 2 红书。
const BUTTONS := [
	{"pos": Vector3(-0.54, 0.0, 1.10), "face": "res://textures/button_puzzle.png", "label": "醉酒"},
	{"pos": Vector3(-0.18, 0.0, 1.10), "face": "res://textures/button_book.png", "label": "选择"},
	{"pos": Vector3(0.18, 0.0, 1.10), "face": "res://textures/button_book.png", "label": "即将死亡"},
	{"pos": Vector3(0.54, 0.0, 1.10), "face": "res://textures/button_puzzle.png", "label": "已猜测"},
]
const MAX_TILT_DEG := 22.0                 # 重力最大倾角
const ROT_SENS := 0.0024                   # 拖拽旋转灵敏度（弧度/像素）
const MIN_ZOOM := 2.6                       # 相机最近距离
const MAX_ZOOM := 9.5                       # 相机最远距离

# 三枚令牌：emoji、中文名、顶面色。
const TOKENS := [
	{"emoji": "🧩", "name": "解谜大师", "color": Color(0.28, 0.60, 0.68), "pos": Vector3(-0.78, 0.0, 0.36), "face": "res://textures/face_puzzle.png"},
	{"emoji": "✝️", "name": "异端分子", "color": Color(0.76, 0.22, 0.24), "pos": Vector3(0.78, 0.0, 0.36), "face": "res://textures/face_cross.png"},
	{"emoji": "👻", "name": "阎罗", "color": Color(0.46, 0.36, 0.72), "pos": Vector3(0.0, 0.0, -0.56), "face": "res://textures/face_book.png"},
]

var _camera: Camera3D
var _table: Node3D                         # 桌板 + 令牌的枢轴，随重力倾斜
var _dragging: StaticBody3D = null
var _pieces: Array[StaticBody3D] = []       # 所有令牌+纽扣，用于相互不重叠的分离
var _touches := {}                           # 活跃触点 index→位置，用于双指缩放
var _pinching := false
var _pinch_dist := 0.0

var _manual_rot := Vector3.ZERO             # 拖拽累积的板子旋转（俯仰 x / 自转 y）
var _rotating := false                       # 正在拖动板面/空白旋转板子
var _intro := false                          # 开场翻转动画进行中（暂停常规旋转）
var _intro_tween: Tween

var _font: FontFile
var _sfx_pick: AudioStreamPlayer
var _sfx_drop: AudioStreamPlayer
var _sfx_click: AudioStreamPlayer

var _dir: DirectionalLight3D                 # 主光/聚光/环境，用于日夜切换
var _spot: SpotLight3D
var _env: Environment
var _night := false
var _toggle_btn: Button
var _refresh_btn: Button

func _ready() -> void:
	randomize()                               # 每次启动随机（令牌位置/歪斜）
	_load_font()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_table = Node3D.new()
	add_child(_table)
	_build_board()
	_spawn_tokens()
	_build_toggle()
	_play_intro()

# 开场：板子快速上下翻转 4 周后停下。
func _play_intro() -> void:
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()               # 连点刷新：杀掉上一个，从 0 重启翻转
	_intro = true
	_manual_rot = Vector3.ZERO
	_table.rotation = Vector3.ZERO
	# 绕一个略偏离水平轴的方向翻 4 整圈（整圈=回正）。开头极快、末尾长长降速。
	var axis := Vector3(1.0, 0.16, 0.1).normalized()
	_intro_tween = create_tween().set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_intro_tween.tween_method(
		func(a: float): _table.transform = Transform3D(Basis(axis, a), Vector3.ZERO),
		0.0, TAU * 4.0, 1.9)
	# 刷新按钮同步绕中心转 4 圈（同参数、同时长）。
	if _refresh_btn != null:
		_refresh_btn.rotation = 0.0
		_intro_tween.parallel().tween_property(_refresh_btn, "rotation", TAU * 4.0, 1.9)
	_intro_tween.chain().tween_callback(_end_intro)

func _end_intro() -> void:
	_table.rotation = Vector3.ZERO            # 4 周 = 回正，重置避免 _process 回绕
	if _refresh_btn != null:
		_refresh_btn.rotation = 0.0
	_intro = false

# 右上角日/夜切换按钮：☀️ 暖黄光 ↔ 🌙 冷蓝光。
func _build_toggle() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_toggle_btn = Button.new()
	_toggle_btn.flat = true
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	_toggle_btn.anchor_left = 0.0                  # 左上角
	_toggle_btn.anchor_right = 0.0
	_toggle_btn.offset_left = 40.0
	_toggle_btn.offset_top = 80.0                 # 从角落往里挪，避开刘海安全区
	_toggle_btn.offset_right = 164.0
	_toggle_btn.offset_bottom = 204.0
	var emoji_font := load("res://fonts/NotoEmoji-toggle.ttf")
	_toggle_btn.add_theme_font_override("font", emoji_font)
	_toggle_btn.add_theme_font_size_override("font_size", 74)
	_toggle_btn.text = "☀️"
	_toggle_btn.pressed.connect(_on_toggle)
	layer.add_child(_toggle_btn)

	# 右上角刷新按钮：重跑开场（重新随机放置 + 翻转 4 周）。
	_refresh_btn = Button.new()
	_refresh_btn.flat = true
	_refresh_btn.focus_mode = Control.FOCUS_NONE
	_refresh_btn.anchor_left = 1.0
	_refresh_btn.anchor_right = 1.0
	_refresh_btn.offset_left = -164.0
	_refresh_btn.offset_top = 80.0
	_refresh_btn.offset_right = -40.0
	_refresh_btn.offset_bottom = 204.0
	_refresh_btn.pivot_offset = Vector2(62.0, 62.0)          # 绕中心旋转（124x124）
	_refresh_btn.icon = load("res://textures/icon_refresh.png")   # 白色线条刷新图标（透明底）
	_refresh_btn.expand_icon = true
	_refresh_btn.pressed.connect(_restart)
	layer.add_child(_refresh_btn)

# 重新开始：清掉现有令牌/纽扣，重新随机放置并重播开场翻转。
func _restart() -> void:
	_sfx_click.play()
	_dragging = null
	_rotating = false
	for p in _pieces:
		p.queue_free()
	_pieces.clear()
	_spawn_tokens()
	_play_intro()

func _on_toggle() -> void:
	_night = not _night
	_sfx_click.play()
	_apply_lighting(true)

# 应用日/夜光照；animate=true 时 0.5s 渐变过渡。
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

func _load_font() -> void:
	# 中文小字用 Noto Sans SC 子集（已含令牌名与纽扣文案）。不再用 emoji。
	_font = load("res://fonts/NotoSansSC-subset.ttf")

# 小字标签：始终朝相机，贴在圆片下方边缘（背面镜像）。
func _add_label(parent: Node3D, text: String, is_top: bool, y_off: float, z_off: float, fsize: int) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font = _font
	lbl.font_size = fsize
	lbl.pixel_size = 0.0016
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(1, 1, 1)
	lbl.outline_size = 10
	lbl.outline_modulate = Color(0, 0, 0, 0.75)
	var s := 1.0 if is_top else -1.0
	lbl.position = Vector3(0.0, s * y_off, s * z_off)
	parent.add_child(lbl)

# 令牌面材质：圆外已透明，用 alpha scissor 得到干净的圆形边缘。
func _face_material(path: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(path)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0            # 纸类：完全漫反射
	m.metallic = 0.0
	m.metallic_specular = 0.0    # 压低镜面反射，去掉高光
	return m

# 在圆片某一面贴一张躺平的图（quad），y_off 是相对中心的高度，rot_x 决定朝上/朝下，radius 决定大小。
func _add_face(parent: Node3D, y_off: float, rot_x: float, mat: StandardMaterial3D, radius: float) -> void:
	var face := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(radius * 2.0, radius * 2.0)
	face.mesh = quad
	face.material_override = mat
	face.rotation_degrees = Vector3(rot_x, 0.0, 0.0)
	face.position = Vector3(0.0, y_off, 0.0)
	parent.add_child(face)

func _build_audio() -> void:
	_sfx_pick = _make_player("res://sounds/pick.wav", 0.0)
	_sfx_drop = _make_player("res://sounds/drop.wav", 2.0)
	_sfx_click = _make_player("res://sounds/click.wav", 0.0)

func _make_player(path: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.volume_db = volume_db
	add_child(p)
	return p

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.05, 0.03, 0.09)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.42, 0.36, 0.52)
	_env.ambient_light_energy = 0.45
	we.environment = _env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)                        # 先入树，保证 look_at 用有效全局变换
	_camera.position = Vector3(0.0, 4.6, 1.9)  # 约 3/4 俯视，基本正对绒布面
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true                    # 关键：脚本相机必须显式设为当前

func _build_lights() -> void:
	# 主平行光。
	_dir = DirectionalLight3D.new()
	_dir.rotation_degrees = Vector3(-58.0, -32.0, 0.0)
	_dir.light_color = Color(1.0, 0.94, 0.85)
	_dir.light_energy = 0.9
	_dir.shadow_enabled = true
	add_child(_dir)
	# 头顶聚光：在板面投一圈光池，令牌顶面有高光——“光照感”。灯固定，板倾斜时高光会游走。
	_spot = SpotLight3D.new()
	add_child(_spot)
	_spot.position = Vector3(0.0, 3.3, 0.5)
	_spot.look_at(Vector3(0.0, 0.0, 0.0), Vector3.FORWARD)
	_spot.light_color = Color(1.0, 0.88, 0.66)
	_spot.light_energy = 6.0
	_spot.spot_range = 9.0
	_spot.spot_angle = 42.0
	_spot.spot_attenuation = 1.2
	_spot.shadow_enabled = true

func _build_board() -> void:
	# 用 GLB 模型（木板 + 已带的紫毛毯）作板子，居中放大。
	# 带盒碰撞体：挡住射线，免得从正面透过板子抓到背面的令牌。
	var body := StaticBody3D.new()
	var model := (load("res://models/board.glb") as PackedScene).instantiate()
	model.scale = Vector3(BOARD_SCALE, BOARD_SCALE, BOARD_SCALE)
	body.add_child(model)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(MODEL_HX * 2.0 * BOARD_SCALE, MODEL_HY * 2.0 * BOARD_SCALE, MODEL_HZ * 2.0 * BOARD_SCALE)
	col.shape = shape
	body.add_child(col)
	_table.add_child(body)

func _spawn_tokens() -> void:
	# 三个位置随机分配给三枚令牌；正面、背面各自独立随机。
	var front_slots := []
	for data in TOKENS:
		front_slots.append(data.pos)
	var back_slots := front_slots.duplicate()
	front_slots.shuffle()
	back_slots.shuffle()
	var i := 0
	for data in TOKENS:
		_make_token(data, true, front_slots[i])
		_make_token(data, false, back_slots[i])
		i += 1
	# 每面（正/反）下方中间各一排 3 枚。
	# 4 个纽扣的位置随机分配，仍是相邻一排；正面、背面各自独立随机。
	var bfront := []
	for bdata in BUTTONS:
		bfront.append(bdata.pos)
	var bback := bfront.duplicate()
	bfront.shuffle()
	bback.shuffle()
	var j := 0
	for bdata in BUTTONS:
		_make_button(bdata, true, bfront[j])
		_make_button(bdata, false, bback[j])
		j += 1

# 小纽扣：紫色小圆片（带各自符号），正反两面贴，可拖拽（无浮标）。
func _make_button(data: Dictionary, is_top: bool, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BUTTON_RADIUS
	cyl.bottom_radius = BUTTON_RADIUS
	cyl.height = BUTTON_HEIGHT
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.15, 0.36)   # 深紫边
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mesh.material_override = mat
	body.add_child(mesh)

	var fmat := _face_material(data.face)
	_add_face(body, BUTTON_HEIGHT * 0.5 + 0.0006, -90.0, fmat, BUTTON_RADIUS)
	_add_face(body, -BUTTON_HEIGHT * 0.5 - 0.0006, 90.0, fmat, BUTTON_RADIUS)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = BUTTON_RADIUS
	shape.height = BUTTON_HEIGHT
	col.shape = shape
	body.add_child(col)

	# 纽扣小字，浮在纽扣上沿以上 0.3 直径处。
	_add_label(body, data.label, is_top, BUTTON_HEIGHT * 0.5 + 0.01, -(BUTTON_RADIUS * 1.6), 38)

	var base_y := (TOP_SURF + BUTTON_HEIGHT * 0.5) if is_top else -(TOP_SURF + BUTTON_HEIGHT * 0.5)
	# 背面那份 z 取反：翻面（180°）后它们同样落在该面的下方边缘。
	var z: float = pos.z if is_top else -pos.z
	body.position = Vector3(pos.x, base_y, z)
	body.set_meta("token", true)
	body.set_meta("plane_y", base_y)
	body.set_meta("radius", BUTTON_RADIUS)
	_table.add_child(body)
	_pieces.append(body)

func _make_token(data: Dictionary, is_top: bool, pos: Vector3) -> void:
	var body := StaticBody3D.new()

	# 薄纸板圆盘：边缘米色（略染各自的色），正反面贴令牌图。
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = TOKEN_RADIUS
	cyl.bottom_radius = TOKEN_RADIUS
	cyl.height = TOKEN_HEIGHT
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.86, 0.79, 0.64).lerp(data.color, 0.25)   # 纸板米色
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mesh.material_override = mat
	body.add_child(mesh)

	# 各角色自己的牌面（合成在圆片上），贴在正反两面；圆形已在贴图里透明切好。
	var fmat := _face_material(data.face)
	_add_face(body, TOKEN_HEIGHT * 0.5 + 0.0008, -90.0, fmat, TOKEN_RADIUS)
	_add_face(body, -TOKEN_HEIGHT * 0.5 - 0.0008, 90.0, fmat, TOKEN_RADIUS)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = TOKEN_RADIUS
	shape.height = TOKEN_HEIGHT
	col.shape = shape
	body.add_child(col)

	# 令牌所在面的高度：正面坐在毛毯面上，背面坐在木板底面。
	var base_y := (TOP_SURF + TOKEN_HEIGHT * 0.5) if is_top else -(TOP_SURF + TOKEN_HEIGHT * 0.5)
	# 名字：小字，浮在令牌上沿以上 0.3 直径处（-Z 为屏幕上方）。
	_add_label(body, data.name, is_top, TOKEN_HEIGHT * 0.5 + 0.02, -(TOKEN_RADIUS * 1.6), 52)

	body.position = Vector3(pos.x, base_y, pos.z)
	body.set_meta("token", true)
	body.set_meta("plane_y", base_y)   # 拖拽时贴着自己这一面移动
	body.set_meta("radius", TOKEN_RADIUS)
	_table.add_child(body)
	_pieces.append(body)

# 拖拽板子/空白 → 累积旋转板子：上下拖=俯仰(绕X)，左右拖=自转(绕Y)。两轴均无限旋转。
func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

## 每帧：板子 = 重力倾斜（有传感器才动）+ 拖拽累积的手动旋转。
func _process(delta: float) -> void:
	if _intro:
		return                                # 开场动画期间不做常规旋转/分离
	var g := Input.get_gravity()
	var grav := Vector3.ZERO
	if g.length() > 0.5:
		var gx := clampf(g.x / 9.8, -1.0, 1.0)
		var gz := clampf(g.z / 9.8, -1.0, 1.0)
		# 手机怎么斜板子怎么斜；真机上若方向相反把符号翻一下。
		grav = Vector3(deg_to_rad(MAX_TILT_DEG) * gz, 0.0, deg_to_rad(-MAX_TILT_DEG) * gx)
	var target := Vector3(grav.x + _manual_rot.x, _manual_rot.y, grav.z)
	var weight := 1.0 - pow(0.002, delta)     # 平滑趋近
	_table.rotation = _table.rotation.lerp(target, weight)
	_separate()

## 物料互不重叠：同一面上的圆片按半径相互推开（被拖的那个不动，推开别的），再夹在板内。
func _separate() -> void:
	var hx := BOARD_SIZE.x * 0.5
	var hz := BOARD_SIZE.y * 0.5
	for _it in 2:
		for i in _pieces.size():
			for j in range(i + 1, _pieces.size()):
				var a: StaticBody3D = _pieces[i]
				var b: StaticBody3D = _pieces[j]
				var pya: float = a.get_meta("plane_y")
				var pyb: float = b.get_meta("plane_y")
				if signf(pya) != signf(pyb):
					continue                       # 不同面（正/反）不互相干涉
				var dx := b.position.x - a.position.x
				var dz := b.position.z - a.position.z
				var d := sqrt(dx * dx + dz * dz)
				var ra: float = a.get_meta("radius")
				var rb: float = b.get_meta("radius")
				var mind := ra + rb
				if d >= mind:
					continue
				var nx := 1.0
				var nz := 0.0
				if d > 0.0001:
					nx = dx / d
					nz = dz / d
				var push := mind - maxf(d, 0.0001)
				if a == _dragging:
					b.position += Vector3(nx * push, 0.0, nz * push)
				elif b == _dragging:
					a.position -= Vector3(nx * push, 0.0, nz * push)
				else:
					a.position -= Vector3(nx * push * 0.5, 0.0, nz * push * 0.5)
					b.position += Vector3(nx * push * 0.5, 0.0, nz * push * 0.5)
	for p in _pieces:
		var r: float = p.get_meta("radius")
		var pp: Vector3 = p.position
		pp.x = clampf(pp.x, -hx + r, hx - r)
		pp.z = clampf(pp.z, -hz + r, hz - r)
		p.position = pp

## 交互：按下→命中令牌抓起（响“嗒”）；拖动→贴板面平移（滑动“哒”）；松开→放下（“咚”）。
func _unhandled_input(event: InputEvent) -> void:
	# --- 缩放：双指捏合 / 触控板 / 鼠标滚轮 ---
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() >= 2:
			_pinching = true               # 双指：只缩放，不拖不转
			_dragging = null
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
				_zoom_by(_pinch_dist / d)  # 两指分开→d变大→拉近
			_pinch_dist = d
			return
	elif event is InputEventMagnifyGesture:
		_zoom_by(1.0 / event.factor)       # 触控板放大手势
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

	# --- 拖令牌 / 旋转板子 ---
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			# 命中令牌→拖令牌；点到木板或空白→旋转板子。
			_try_pick(event.position)
		else:
			if _dragging != null:
				# 松手瞬间随机歪斜 ±15°（绕自身垂直轴，像随手一放）。
				_dragging.rotation = Vector3(0.0, randf_range(-deg_to_rad(15.0), deg_to_rad(15.0)), 0.0)
				_sfx_drop.play()
			_dragging = null
			_rotating = false
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		if _dragging != null:
			_drag_to(event.position)
		elif _rotating:
			_rotate_by(event.relative)

func _two_touch_dist() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

# 相机沿视线拉近/推远：ratio<1 拉近，>1 推远。
func _zoom_by(ratio: float) -> void:
	var d := clampf(_camera.position.length() * ratio, MIN_ZOOM, MAX_ZOOM)
	_camera.position = _camera.position.normalized() * d
	_camera.look_at(Vector3.ZERO, Vector3.UP)

func _try_pick(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 100.0)
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.collider.has_meta("token"):
		_dragging = hit.collider               # 点到令牌 → 拖令牌
		_sfx_pick.play()
	else:
		_rotating = true                       # 点到木板或空白背景 → 旋转板子

func _drag_to(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var py: float = _dragging.get_meta("plane_y")
	var hit = _board_plane(py).intersects_ray(from, dir)
	if hit == null:
		return
	var local: Vector3 = _table.to_local(hit)
	var hx := BOARD_SIZE.x * 0.5 - TOKEN_RADIUS
	var hz := BOARD_SIZE.y * 0.5 - TOKEN_RADIUS
	local.x = clampf(local.x, -hx, hx)
	local.z = clampf(local.z, -hz, hz)
	local.y = py
	_dragging.position = local

## 令牌所在面（随 _table 倾斜）的世界平面，用于把屏幕拖拽反投影到板上。
func _board_plane(plane_y: float) -> Plane:
	var n := _table.global_transform.basis.y.normalized()
	var p := _table.to_global(Vector3(0.0, plane_y, 0.0))
	return Plane(n, p)
