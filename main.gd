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
const BUTTON_RADIUS := 0.085                # 小纽扣半径
const BUTTON_HEIGHT := 0.012
# 3 枚小纽扣：板面下方边缘附近一排（z 靠近前缘 1.25、x 居中）；1 拼图 + 2 红书。
const BUTTONS := [
	{"pos": Vector3(-0.34, 0.0, 1.25), "face": "res://textures/button_puzzle.png"},
	{"pos": Vector3(0.0, 0.0, 1.25), "face": "res://textures/button_book.png"},
	{"pos": Vector3(0.34, 0.0, 1.25), "face": "res://textures/button_book.png"},
]
const MAX_TILT_DEG := 22.0                 # 重力最大倾角
const MOVE_SOUND_STEP := 0.07              # 拖动每滑过这么远响一次“哒”
const ROT_SENS := 0.0038                   # 拖拽旋转灵敏度（弧度/像素）

# 三枚令牌：emoji、中文名、顶面色。
const TOKENS := [
	{"emoji": "🧩", "name": "解谜大师", "color": Color(0.28, 0.60, 0.68), "pos": Vector3(-0.78, 0.0, 0.36), "face": "res://textures/face_puzzle.png"},
	{"emoji": "✝️", "name": "异端分子", "color": Color(0.76, 0.22, 0.24), "pos": Vector3(0.78, 0.0, 0.36), "face": "res://textures/face_cross.png"},
	{"emoji": "👻", "name": "阎罗", "color": Color(0.46, 0.36, 0.72), "pos": Vector3(0.0, 0.0, -0.56), "face": "res://textures/face_book.png"},
]

var _camera: Camera3D
var _table: Node3D                         # 桌板 + 令牌的枢轴，随重力倾斜
var _dragging: StaticBody3D = null
var _last_sound_pos := Vector3.ZERO

var _manual_rot := Vector3.ZERO             # 拖拽累积的板子旋转（俯仰 x / 自转 y）
var _rotating := false                       # 正在拖动板面/空白旋转板子

var _font: FontFile
var _sfx_pick: AudioStreamPlayer
var _sfx_move: AudioStreamPlayer
var _sfx_drop: AudioStreamPlayer

func _ready() -> void:
	_load_font()
	_build_audio()
	_build_environment()
	_build_camera()
	_build_lights()
	_table = Node3D.new()
	add_child(_table)
	_build_board()
	_spawn_tokens()

func _load_font() -> void:
	# 中文用 Noto Sans SC 子集，emoji 回退到 Noto Color Emoji 子集（彩色）。
	_font = load("res://fonts/NotoSansSC-subset.ttf")
	var emoji: FontFile = load("res://fonts/NotoColorEmoji-subset.ttf")
	_font.fallbacks = [emoji]

# 令牌面材质：圆外已透明，用 alpha scissor 得到干净的圆形边缘。
func _face_material(path: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(path)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0            # 纸类：完全漫反射
	m.metallic = 0.0
	m.metallic_specular = 0.1    # 压低镜面反射，去掉高光
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
	_sfx_move = _make_player("res://sounds/move.wav", -6.0)
	_sfx_drop = _make_player("res://sounds/drop.wav", 2.0)

func _make_player(path: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.volume_db = volume_db
	add_child(p)
	return p

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.03, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.36, 0.52)
	env.ambient_light_energy = 0.45
	we.environment = env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	add_child(_camera)                        # 先入树，保证 look_at 用有效全局变换
	_camera.position = Vector3(0.0, 3.4, 3.7)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_camera.current = true                    # 关键：脚本相机必须显式设为当前

func _build_lights() -> void:
	# 主平行光（冷紫环境里的一缕暖光）。
	var dir := DirectionalLight3D.new()
	dir.rotation_degrees = Vector3(-58.0, -32.0, 0.0)
	dir.light_color = Color(1.0, 0.94, 0.85)
	dir.light_energy = 0.9
	dir.shadow_enabled = true
	add_child(dir)
	# 头顶聚光：在板面投一圈暖光池，令牌顶面有高光——“光照感”。灯固定，板倾斜时高光会游走。
	var spot := SpotLight3D.new()
	add_child(spot)
	spot.position = Vector3(0.0, 3.3, 0.5)
	spot.look_at(Vector3(0.0, 0.0, 0.0), Vector3.FORWARD)
	spot.light_color = Color(1.0, 0.88, 0.66)
	spot.light_energy = 6.0
	spot.spot_range = 9.0
	spot.spot_angle = 42.0
	spot.spot_attenuation = 1.2
	spot.shadow_enabled = true

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
	# 正面一副、背面镜像同样一副，都可交互。
	for data in TOKENS:
		_make_token(data, true)
		_make_token(data, false)
	# 每面（正/反）下方中间各一排 3 枚。
	for bdata in BUTTONS:
		_make_button(bdata, true)
		_make_button(bdata, false)

# 小纽扣：紫色小圆片（带各自符号），正反两面贴，可拖拽（无浮标）。
func _make_button(data: Dictionary, is_top: bool) -> void:
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
	mat.metallic_specular = 0.1
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

	var base_y := (TOP_SURF + BUTTON_HEIGHT * 0.5) if is_top else -(TOP_SURF + BUTTON_HEIGHT * 0.5)
	# 背面那份 z 取反：翻面（180°）后它们同样落在该面的下方边缘。
	var z := data.pos.z if is_top else -data.pos.z
	body.position = Vector3(data.pos.x, base_y, z)
	body.set_meta("token", true)
	body.set_meta("plane_y", base_y)
	_table.add_child(body)

func _make_token(data: Dictionary, is_top: bool) -> void:
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
	mat.metallic_specular = 0.1
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

	# 令牌上方的浮标：emoji + 中文名，始终朝向相机。
	var lbl := Label3D.new()
	lbl.text = "%s\n%s" % [data.emoji, data.name]
	lbl.font = _font
	lbl.font_size = 64
	lbl.pixel_size = 0.0016
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(1, 1, 1)
	lbl.outline_size = 14
	lbl.outline_modulate = Color(0, 0, 0, 0.7)
	# 令牌所在面的高度：正面坐在毛毯面上，背面坐在木板底面（浮标随之在外侧）。
	var base_y := (TOP_SURF + TOKEN_HEIGHT * 0.5) if is_top else -(TOP_SURF + TOKEN_HEIGHT * 0.5)
	var label_y := (TOKEN_HEIGHT * 0.5 + 0.22) if is_top else -(TOKEN_HEIGHT * 0.5 + 0.22)
	lbl.position = Vector3(0.0, label_y, 0.0)
	body.add_child(lbl)

	body.position = Vector3(data.pos.x, base_y, data.pos.z)
	body.set_meta("token", true)
	body.set_meta("plane_y", base_y)   # 拖拽时贴着自己这一面移动
	_table.add_child(body)

# 拖拽板子/空白 → 累积旋转板子：上下拖=俯仰(绕X)，左右拖=自转(绕Y)。两轴均无限旋转。
func _rotate_by(delta: Vector2) -> void:
	_manual_rot.x -= delta.y * ROT_SENS
	_manual_rot.y += delta.x * ROT_SENS

## 每帧：板子 = 重力倾斜（有传感器才动）+ 拖拽累积的手动旋转。
func _process(delta: float) -> void:
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

## 交互：按下→命中令牌抓起（响“嗒”）；拖动→贴板面平移（滑动“哒”）；松开→放下（“咚”）。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			# 命中令牌就拖令牌；否则（点到板面或空中）拖动旋转板子。
			_try_pick(event.position)
			_rotating = _dragging == null
		else:
			if _dragging != null:
				_sfx_drop.play()
			_dragging = null
			_rotating = false
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		if _dragging != null:
			_drag_to(event.position)
		elif _rotating:
			_rotate_by(event.relative)

func _try_pick(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 100.0)
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.collider.has_meta("token"):
		_dragging = hit.collider
		_last_sound_pos = _dragging.global_position
		_sfx_pick.play()

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
	# 滑过一定距离响一次“哒”。
	if _dragging.global_position.distance_to(_last_sound_pos) >= MOVE_SOUND_STEP:
		_last_sound_pos = _dragging.global_position
		if not _sfx_move.playing:
			_sfx_move.play()

## 令牌所在面（随 _table 倾斜）的世界平面，用于把屏幕拖拽反投影到板上。
func _board_plane(plane_y: float) -> Plane:
	var n := _table.global_transform.basis.y.normalized()
	var p := _table.to_global(Vector3(0.0, plane_y, 0.0))
	return Plane(n, p)
