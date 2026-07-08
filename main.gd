extends Node3D
## DeskFeel — 真 3D 桌板（Godot 版）。
## 紫绒布板 + 圆柱厚片令牌，可拖拽。iOS 与 Web（GitHub Pages）同一套代码。
## 场景整体用脚本程序化生成，避免手写 .tscn 出错。

const BOARD_SIZE := Vector2(3.2, 2.2)   # 板面尺寸（米）
const BOARD_THICK := 0.12
const TOKEN_RADIUS := 0.16
const TOKEN_HEIGHT := 0.06
const TOKEN_TOP_Y := TOKEN_HEIGHT * 0.5

var _camera: Camera3D
var _dragging: StaticBody3D = null
# 令牌在这块水平面上移动（板面之上半个令牌高度）。
var _drag_plane := Plane(Vector3.UP, TOKEN_TOP_Y)

func _ready() -> void:
	_build_environment()
	_build_camera()
	_build_lights()
	_build_board()
	_spawn_tokens()

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.06, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.48, 0.62)
	env.ambient_light_energy = 0.7
	we.environment = env
	add_child(we)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 52.0
	_camera.position = Vector3(0.0, 3.0, 3.2)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	add_child(_camera)

func _build_lights() -> void:
	var dir := DirectionalLight3D.new()
	dir.rotation_degrees = Vector3(-60.0, -30.0, 0.0)
	dir.light_energy = 1.1
	dir.shadow_enabled = true
	add_child(dir)

func _build_board() -> void:
	var board := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BOARD_SIZE.x, BOARD_THICK, BOARD_SIZE.y)
	board.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.17, 0.44)   # 紫绒布
	mat.roughness = 0.95
	board.material_override = mat
	board.position = Vector3(0.0, -BOARD_THICK * 0.5, 0.0)
	add_child(board)

func _spawn_tokens() -> void:
	var tints := [
		Color(0.86, 0.30, 0.30), Color(0.30, 0.55, 0.86), Color(0.95, 0.78, 0.35),
		Color(0.45, 0.80, 0.45), Color(0.75, 0.45, 0.85),
	]
	var n := tints.size()
	for i in n:
		var ang := TAU * float(i) / float(n)
		var pos := Vector3(cos(ang) * 0.95, TOKEN_TOP_Y, sin(ang) * 0.70)
		_make_token(tints[i], pos)

func _make_token(tint: Color, pos: Vector3) -> void:
	var body := StaticBody3D.new()

	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = TOKEN_RADIUS
	cyl.bottom_radius = TOKEN_RADIUS
	cyl.height = TOKEN_HEIGHT
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.85
	mesh.material_override = mat
	body.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = TOKEN_RADIUS
	shape.height = TOKEN_HEIGHT
	col.shape = shape
	body.add_child(col)

	body.position = pos
	body.set_meta("token", true)
	add_child(body)

## 交互：按下→命中令牌则抓起；移动→令牌贴着板面平移；松开→放下。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			_try_pick(event.position)
		else:
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

func _drag_to(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var hit = _drag_plane.intersects_ray(from, dir)
	if hit == null:
		return
	var p: Vector3 = hit
	var hx := BOARD_SIZE.x * 0.5 - TOKEN_RADIUS
	var hz := BOARD_SIZE.y * 0.5 - TOKEN_RADIUS
	p.x = clampf(p.x, -hx, hx)
	p.z = clampf(p.z, -hz, hz)
	p.y = TOKEN_TOP_Y
	_dragging.position = p
