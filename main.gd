extends Node3D
## DeskFeel — 真 3D 桌板（Godot 版）。
## 紫绒布板随手机重力倾斜、聚光灯打光、令牌可拖拽并有落桌声。
## 三枚令牌：🧩 解谜大师 / ✝️ 异端分子 / 👻 阎罗。
## iOS 与 Web（GitHub Pages）同一套代码。场景全部脚本生成。

const BOARD_SIZE := Vector2(3.2, 2.2)     # 板面尺寸（米）
const BOARD_THICK := 0.12
const TOKEN_RADIUS := 0.22
const TOKEN_HEIGHT := 0.07
const TOKEN_TOP_Y := TOKEN_HEIGHT * 0.5
const MAX_TILT_DEG := 22.0                 # 重力最大倾角
const MOVE_SOUND_STEP := 0.07              # 拖动每滑过这么远响一次“哒”

# 三枚令牌：emoji、中文名、顶面色。
const TOKENS := [
	{"emoji": "🧩", "name": "解谜大师", "color": Color(0.28, 0.60, 0.68), "pos": Vector3(-0.78, 0.0, 0.36)},
	{"emoji": "✝️", "name": "异端分子", "color": Color(0.76, 0.22, 0.24), "pos": Vector3(0.78, 0.0, 0.36)},
	{"emoji": "👻", "name": "阎罗", "color": Color(0.46, 0.36, 0.72), "pos": Vector3(0.0, 0.0, -0.56)},
]

var _camera: Camera3D
var _table: Node3D                         # 桌板 + 令牌的枢轴，随重力倾斜
var _dragging: StaticBody3D = null
var _last_sound_pos := Vector3.ZERO

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
	var board := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BOARD_SIZE.x, BOARD_THICK, BOARD_SIZE.y)
	board.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.17, 0.44)    # 紫绒布
	mat.roughness = 0.95
	mat.metallic = 0.0
	board.material_override = mat
	board.position = Vector3(0.0, -BOARD_THICK * 0.5, 0.0)
	_table.add_child(board)

func _spawn_tokens() -> void:
	for data in TOKENS:
		_make_token(data)

func _make_token(data: Dictionary) -> void:
	var body := StaticBody3D.new()

	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = TOKEN_RADIUS
	cyl.bottom_radius = TOKEN_RADIUS
	cyl.height = TOKEN_HEIGHT
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = data.color
	mat.roughness = 0.5                            # 略带光泽，接暖光高光
	mat.metallic = 0.05
	mesh.material_override = mat
	body.add_child(mesh)

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
	lbl.position = Vector3(0.0, TOKEN_HEIGHT * 0.5 + 0.22, 0.0)
	body.add_child(lbl)

	var p: Vector3 = data.pos
	p.y = TOKEN_TOP_Y
	body.position = p
	body.set_meta("token", true)
	_table.add_child(body)

## 每帧：板子随手机重力倾斜（有传感器才动，Web 桌面无传感器则保持水平）。
func _process(delta: float) -> void:
	var g := Input.get_gravity()
	var target := Vector3.ZERO
	if g.length() > 0.5:
		var gx := clampf(g.x / 9.8, -1.0, 1.0)
		var gz := clampf(g.z / 9.8, -1.0, 1.0)
		# 手机怎么斜板子怎么斜（幅度限 ±MAX_TILT_DEG）；真机上若方向相反把符号翻一下。
		target = Vector3(deg_to_rad(MAX_TILT_DEG) * gz, 0.0, deg_to_rad(-MAX_TILT_DEG) * gx)
	var weight := 1.0 - pow(0.002, delta)     # 平滑趋近
	_table.rotation = _table.rotation.lerp(target, weight)

## 交互：按下→命中令牌抓起（响“嗒”）；拖动→贴板面平移（滑动“哒”）；松开→放下（“咚”）。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			_try_pick(event.position)
		elif _dragging != null:
			_sfx_drop.play()
			_dragging = null
	elif _dragging != null and (event is InputEventMouseMotion or event is InputEventScreenDrag):
		_drag_to(event.position)

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
	var hit = _board_plane().intersects_ray(from, dir)
	if hit == null:
		return
	var local: Vector3 = _table.to_local(hit)
	var hx := BOARD_SIZE.x * 0.5 - TOKEN_RADIUS
	var hz := BOARD_SIZE.y * 0.5 - TOKEN_RADIUS
	local.x = clampf(local.x, -hx, hx)
	local.z = clampf(local.z, -hz, hz)
	local.y = TOKEN_TOP_Y
	_dragging.position = local
	# 滑过一定距离响一次“哒”。
	if _dragging.global_position.distance_to(_last_sound_pos) >= MOVE_SOUND_STEP:
		_last_sound_pos = _dragging.global_position
		if not _sfx_move.playing:
			_sfx_move.play()

## 当前板面（随 _table 倾斜）的世界平面，用于把屏幕拖拽反投影到板上。
func _board_plane() -> Plane:
	var n := _table.global_transform.basis.y.normalized()
	var p := _table.to_global(Vector3(0.0, TOKEN_TOP_Y, 0.0))
	return Plane(n, p)
