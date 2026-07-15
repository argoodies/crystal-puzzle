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
var _sfx_bubble: AudioStreamPlayer
var _last_bubble_t := -1.0                   # 冲击水泡声节流时钟
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
const ROOM_ELEV := 0.5236                           # 固定俯角 30°（露出远端瓶口）
var _room_yaw := 0.0                               # 绕竖直轴方位角
var _room_yaw_vel := 0.0                           # 方位角惯性（弧度/秒）
var _map_btn: Button
var _room_next_btn: Button                          # 成就空间右上角换关（常驻）
# 成就挑战进度：底部进度条 x/目标；达标出完成圆圈 → 完成音乐 → 视频 → 进下一挑战。
const CHALLENGE_TARGETS := [10, 30]                 # 挑战 1=10、挑战 2=30（水晶总数）
var _challenge := 1                                 # 当前挑战关（1..）
var _room_prog: ProgressBar
var _room_prog_label: Label
var _room_circle_btn: Button                        # 成就空间底部完成圆圈
var _room_circle_shown := false                     # 圆圈已出现（"叮"只响一次）
var _room_circle_lock := false                      # 完成动画期间锁定
var _video_layer: CanvasLayer
var _video_player: VideoStreamPlayer
var _in_room := false
var _room_root: Node3D                        # 成就空间根
var _room_dist := 30.0                          # 相机到注视点距离（随规模自适应）
var _room_dist_min := 8.0                       # 放大上限：瓶宽=屏 80%
var _room_dist_max := 40.0                      # 缩小下限：瓶宽=屏 33%
var _room_dragging := false
var _room_touches: Dictionary = {}              # 空间内多点触摸（拖拽=旋转，双指=缩放）
var _room_pinch := 0.0                           # 上一帧双指间距
const JAR_MARGIN := 2.0                            # 瓶壁到最外水晶的余量
const MAX_RIP := 6                                 # 同时存在的涟漪数
const ROOM_ROT_SENS := 0.0032                      # 成就空间旋转灵敏度（比主游戏低）
var _room_cy := 0.0                               # 相机注视点 y（瓶内水晶中心高度）
var _room_water_mat: ShaderMaterial               # 水面材质（承载涟漪）
var _room_waterbody_mat: ShaderMaterial           # 水体材质（水内部涟漪）
var _room_water_r := 8.0                          # 水面半径
var _room_water_top := 3.0                        # 水面高度
var _room_time := 0.0                             # 涟漪时钟
var _room_rips: Array = []                        # 最近涟漪 Vector4(x, y, z, start)
var _rip_idx := 0
var _room_jar_r := 8.0                            # 瓶半径（判断是否触到瓶）
var _room_on_jar := false                         # 本次触摸是否落在瓶上（落在瓶上不旋转视角）
var _room_mmis: Array = []                        # [{node, pos, vel}] 每个水晶的实时位置/速度
var _room_moving := false                          # 是否还有水晶在动（决定是否继续模拟）
var _room_inner_r := 8.0                           # 水晶可达最大半径（不出瓶）
var _room_y_lo := -4.0
var _room_y_hi := 4.0
var _room_burst_r := 5.0                           # 一片冲击的作用半径
var _room_R := 8.0                                 # 瓶身球半径（圆瓶）
var _room_neck_r := 2.4                            # 细口半径
var _room_top := 15.0                              # 瓶口 y
var _room_body_r := 6.4                            # 水晶容纳球半径（贴瓶身内）
var _room_wall := 0.4                              # 瓶壁厚度（约束时减去，防穿模）
var _room_cr := 1.0                                # 水晶碰撞球半径
var _room_cm := 1.0                                # 水晶容纳边距（贴壁/水面时退让）
var _room_ripple := 0.0                            # 水面涟漪当前幅度（平滑跟随气泡数）
# 调试暗门：成就页面长按左上角 7s → 对应水晶数量翻倍（日光=拼图 / 月光=战车）。
var _toggle_press_t := -1.0                        # 左上角按住计时（<0=未按）
var _debug_fired := false                          # 本次长按已触发（抑制随后的日夜切换）
# 调试暗门：成就页面长按播放键 7s → 清空全部成就。
var _next_press_t := -1.0                          # 播放键按住计时（<0=未按）
var _next_fired := false                           # 本次长按已触发（抑制随后的换关）
const BUBBLE_MAX := 180                             # 气泡池容量
var _bubble_mm: MultiMesh                           # 气泡 MultiMesh
var _bub_pos: PackedVector3Array
var _bub_vel: PackedVector3Array
var _bub_life: PackedFloat32Array
var _bub_r: PackedFloat32Array
var _bub_idx := 0
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
	_build_room_progress_ui()
	_build_video_player()
	if _night:
		_apply_lighting(false)
	# 每次启动都是一个新的未完成水晶。
	_load_random_level()

# ---------- 存档 ----------

# 只持久化偏好：日/夜 + 已解锁模型（不保存半程擦拭进度）。
func _save_state() -> void:
	var f := FileAccess.open(SAVE_STATE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"night": _night, "counts": _counts, "challenge": _challenge}))
		f.close()

func _load_prefs() -> void:
	if not FileAccess.file_exists(SAVE_STATE):
		return
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(SAVE_STATE))
	if cfg is Dictionary:
		_night = bool(cfg.get("night", false))
		_challenge = maxi(1, int(cfg.get("challenge", 1)))
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
	_sfx_bubble = AudioStreamPlayer.new()
	_sfx_bubble.stream = load("res://sounds/bubble.wav")
	_sfx_bubble.volume_db = 0.0
	add_child(_sfx_bubble)

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
	_toggle_btn.button_down.connect(_on_toggle_down)   # 调试暗门：长按计时
	_toggle_btn.button_up.connect(_on_toggle_up)
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

	# 成就空间右上角：关闭按钮（进空间才显示，常驻不淡出）。
	_room_next_btn = _make_flat_btn("res://textures/icon_play.png")
	_room_next_btn.pressed.connect(_room_next_level)
	_room_next_btn.button_down.connect(_on_next_down)   # 调试暗门：长按清空成就
	_room_next_btn.button_up.connect(_on_next_up)
	_room_next_btn.visible = false
	_apply_glass(_room_next_btn)
	layer.add_child(_room_next_btn)

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
	if _room_next_btn != null:                     # 成就空间换关：右上角最右
		_room_next_btn.anchor_left = 1.0
		_room_next_btn.anchor_right = 1.0
		_room_next_btn.offset_right = -right
		_room_next_btn.offset_left = -right - btn
		_room_next_btn.offset_top = top
		_room_next_btn.offset_bottom = top + btn

func _on_toggle() -> void:
	if _debug_fired:                       # 刚触发过长按暗门 → 本次不切换日夜
		_debug_fired = false
		return
	_night = not _night
	_sfx_click.play()
	_apply_lighting(true)
	_save_state()

# 调试暗门：只在成就页面里开始按住计时（日光=拼图 / 月光=战车）。
func _on_toggle_down() -> void:
	if _in_room:
		_toggle_press_t = 0.0
		_debug_fired = false
	else:
		_toggle_press_t = -1.0

func _on_toggle_up() -> void:
	_toggle_press_t = -1.0

# 长按 7s 触发：对应模型完成数翻倍（0 则记为 1），然后按新数量重建瓶子。
func _debug_double_count() -> void:
	var path := "res://models/chariot.glb" if _night else "res://models/puzzle.glb"
	_counts[path] = maxi(1, int(_counts.get(path, 0)) * 2)
	_sfx_ding.play()                       # 反馈一声
	_save_state()
	if _in_room:                           # 按新数量重建瓶子（保住游戏相机）
		var saved := _cam_saved
		_open_room()
		_cam_saved = saved

# 调试暗门：只在成就页面开始按住播放键计时。
func _on_next_down() -> void:
	if _in_room:
		_next_press_t = 0.0
		_next_fired = false
	else:
		_next_press_t = -1.0

func _on_next_up() -> void:
	_next_press_t = -1.0

# 长按播放键 7s 触发：清空全部成就并重建（空）瓶子。
func _debug_clear_counts() -> void:
	_counts.clear()
	_sfx_ding.play()                       # 反馈一声
	_save_state()
	if _in_room:                           # 重建空瓶（保住游戏相机）
		var saved := _cam_saved
		_open_room()
		_cam_saved = saved

# ---------- 成就挑战：进度条 / 完成圆圈 / 视频 ----------

func _build_room_progress_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	# 底部完成圆圈（达标出现，点击完成）。
	_room_circle_btn = _make_flat_btn("res://textures/icon_circle.png")
	_room_circle_btn.pressed.connect(_on_room_circle)
	_room_circle_btn.visible = false
	var cb := 170.0
	_room_circle_btn.anchor_left = 0.5; _room_circle_btn.anchor_right = 0.5
	_room_circle_btn.anchor_top = 1.0; _room_circle_btn.anchor_bottom = 1.0
	_room_circle_btn.offset_left = -cb * 0.5; _room_circle_btn.offset_right = cb * 0.5
	_room_circle_btn.offset_bottom = -150.0; _room_circle_btn.offset_top = -150.0 - cb
	layer.add_child(_room_circle_btn)
	# 进度条 + x/目标 文本，底部中央。
	_room_prog = ProgressBar.new()
	_room_prog.show_percentage = false
	_room_prog.min_value = 0
	_room_prog.visible = false
	var bg := StyleBoxFlat.new(); bg.bg_color = Color(1, 1, 1, 0.12); bg.set_corner_radius_all(15)
	var fg := StyleBoxFlat.new(); fg.bg_color = Color(0.5, 0.75, 1.0, 0.92); fg.set_corner_radius_all(15)
	_room_prog.add_theme_stylebox_override("background", bg)
	_room_prog.add_theme_stylebox_override("fill", fg)
	_room_prog.anchor_left = 0.18; _room_prog.anchor_right = 0.82
	_room_prog.anchor_top = 1.0; _room_prog.anchor_bottom = 1.0
	_room_prog.offset_left = 0; _room_prog.offset_right = 0
	_room_prog.offset_top = -120.0; _room_prog.offset_bottom = -90.0
	layer.add_child(_room_prog)
	_room_prog_label = Label.new()
	_room_prog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_room_prog_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_room_prog_label.add_theme_font_size_override("font_size", 30)
	_room_prog_label.visible = false
	_room_prog_label.anchor_left = 0.18; _room_prog_label.anchor_right = 0.82
	_room_prog_label.anchor_top = 1.0; _room_prog_label.anchor_bottom = 1.0
	_room_prog_label.offset_left = 0; _room_prog_label.offset_right = 0
	_room_prog_label.offset_top = -122.0; _room_prog_label.offset_bottom = -88.0
	layer.add_child(_room_prog_label)

func _build_video_player() -> void:
	_video_layer = CanvasLayer.new()
	_video_layer.layer = 3                     # 视频最上层
	_video_layer.visible = false
	add_child(_video_layer)
	var bg := ColorRect.new()                  # 黑底 + 挡住下方输入（点一下可跳过）
	bg.color = Color(0, 0, 0, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(_on_video_input)
	_video_layer.add_child(bg)
	_video_player = VideoStreamPlayer.new()
	_video_player.expand = true
	_video_player.loop = false
	_video_player.finished.connect(_on_video_finished)
	_video_layer.add_child(_video_player)

func _challenge_target() -> int:
	return int(CHALLENGE_TARGETS[mini(_challenge - 1, CHALLENGE_TARGETS.size() - 1)])

func _total_crystals() -> int:
	var t := 0
	for k in _counts:
		t += int(_counts[k])
	return t

func _show_room_progress(on: bool) -> void:
	# 不显示进度条/数字（仅保留达标完成圆圈逻辑）。
	if _room_prog != null:
		_room_prog.visible = false
		_room_prog_label.visible = false
	if not on and _room_circle_btn != null:
		_room_circle_btn.visible = false

func _update_room_progress() -> void:
	if _room_prog == null:
		return
	var target := _challenge_target()
	var total := _total_crystals()
	_room_prog.max_value = target
	_room_prog.value = mini(total, target)
	_room_prog_label.text = "%d/%d" % [total, target]
	if _room_circle_lock:
		return
	if total >= target:                        # 达标 → 出现完成圆圈（"叮"一次）
		if not _room_circle_shown:
			_room_circle_shown = true
			_room_circle_btn.icon = load("res://textures/icon_circle.png")
			_room_circle_btn.disabled = false
			_room_circle_btn.modulate.a = 0.0
			_room_circle_btn.visible = true
			create_tween().tween_property(_room_circle_btn, "modulate:a", 1.0, 0.3)
			_sfx_ding.play()                   # 可完成提示音
	else:
		_room_circle_shown = false
		_room_circle_btn.visible = false

# 点击完成圆圈 → 完成音乐 + 变对勾 → 播放挑战视频 → 进下一挑战。
func _on_room_circle() -> void:
	if _room_circle_lock:
		return
	_room_circle_lock = true
	_sfx_reward.play()                         # 完成音乐
	_room_circle_btn.icon = load("res://textures/icon_eye.png")   # 变全视之眼
	_room_circle_btn.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(0.9)
	tw.tween_callback(_play_challenge_video)

func _play_challenge_video() -> void:
	if _video_player == null:
		_finish_challenge(); return
	_room_circle_btn.visible = false
	var vs := load("res://video/challenge1.ogv")
	if vs == null:
		_finish_challenge(); return
	_video_player.stream = vs
	# 保持视频宽高比、居中适配屏幕。
	var vp := get_viewport().get_visible_rect().size
	var va := 540.0 / 838.0
	var w := vp.x
	var h := w / va
	if h > vp.y:
		h = vp.y; w = h * va
	_video_player.anchor_left = 0.5; _video_player.anchor_right = 0.5
	_video_player.anchor_top = 0.5; _video_player.anchor_bottom = 0.5
	_video_player.offset_left = -w * 0.5; _video_player.offset_right = w * 0.5
	_video_player.offset_top = -h * 0.5; _video_player.offset_bottom = h * 0.5
	_video_layer.visible = true
	_video_player.play()

func _on_video_input(event: InputEvent) -> void:
	# 视频播放中点一下 → 跳过。
	if _video_layer.visible and event is InputEventScreenTouch and event.pressed:
		_on_video_finished()
	elif _video_layer.visible and event is InputEventMouseButton and event.pressed:
		_on_video_finished()

func _on_video_finished() -> void:
	if not _video_layer.visible:
		return
	_video_player.stop()
	_video_layer.visible = false
	_finish_challenge()

func _finish_challenge() -> void:
	if _challenge < CHALLENGE_TARGETS.size():
		_challenge += 1                        # 进入下一挑战（如 x/30）
	_counts.clear()                            # 完成后清空成就水晶，保留 1 个（不清到 0）
	_counts[MODELS[0]] = 1
	_room_circle_lock = false
	_room_circle_shown = false
	if _room_circle_btn != null:
		_room_circle_btn.visible = false
	_save_state()
	if _in_room:                               # 重建空瓶（保住游戏相机），并刷新进度
		var saved := _cam_saved
		_open_room()
		_cam_saved = saved
	else:
		_update_room_progress()

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
	_toggle_btn.visible = true                    # 左上角灯光调整：常驻
	_toggle_btn.modulate.a = 1.0
	_hide_bottom_ui()
	if _map_btn != null:
		_map_btn.visible = false                  # 空间内不需要画廊按钮
	if _room_next_btn != null:
		_room_next_btn.visible = true                 # 右上角换关：常驻
		_room_next_btn.modulate.a = 1.0
	_room_circle_lock = false
	_room_circle_shown = false
	_show_room_progress(true)                         # 底部进度条 + 达标圆圈
	_update_room_progress()
	# 神光保留开启（下面 _process 里把光心设到空间中心）。
	_cam_saved = _camera.transform
	_room_yaw = 0.0
	_room_yaw_vel = 0.0
	_room_dragging = false
	_room_touches.clear()
	if _room_root != null and is_instance_valid(_room_root):
		_room_root.queue_free()
	_room_root = Node3D.new()
	add_child(_room_root)
	# 涟漪状态复位。
	_room_time = 0.0
	_last_bubble_t = -1.0                            # 水泡声节流时钟复位（否则重开后一段时间不响）
	_rip_idx = 0
	_room_rips.clear()
	for i in MAX_RIP:
		_room_rips.append(Vector4(0.0, 0.0, 0.0, -1.0))   # w=start<0 → 未激活
	# 瓶身球半径固定，不随内部水晶数量变化（数量多则挤得更密）。
	var disp := TARGET_W * TABLE_DISP
	_room_R = disp * 3.5                                         # 瓶身球半径（固定）
	# 仿照 round-bottom 烧瓶母线的程序化比例（颈≈0.32R、颈口≈2.29R、带卷唇）。
	_room_neck_r = _room_R * (0.098 / 0.31)                      # 颈半径 ≈ 0.32R
	_room_top = _room_R * 1.7                                   # 颈口 y（短颈）
	_room_wall = minf(_room_R * 0.025, _room_neck_r * 0.3)     # 薄玻璃壁
	# 水晶容纳球：瓶身球(R) 再退一个水晶半径(≈0.6·disp)，网格不穿壁。
	_room_body_r = minf(_room_R * 0.8, _room_R - disp * 0.6)
	_room_cr = disp * 0.45                                       # 水晶碰撞半径
	_room_cm = disp * 0.6                                        # 水晶容纳边距
	_room_cy = 0.0                                               # 瓶身球心=原点
	var neck_base := _room_R * 1.05                              # 肩颈交界高度
	_room_water_top = neck_base + 0.5 * (_room_top - neck_base)  # 水到瓶颈 50% 高度
	_room_water_r = _room_R
	_room_burst_r = _room_R * 1.15
	_room_water_mat = null                          # 下面建水体时赋值（水面涟漪材质）
	_room_waterbody_mat = null                      # 水体无独立涟漪材质
	_room_mmis.clear()
	_room_moving = false

	# 玻璃外壳：程序化 round-bottom 烧瓶（旋转体），透明玻璃 shader，含薄壁与卷唇。
	var glass := MeshInstance3D.new()
	glass.mesh = _make_bottle_surface(1.0, _room_top, false, _room_wall)
	var gmat := ShaderMaterial.new(); gmat.shader = _make_jar_shader()
	glass.material_override = gmat
	_room_root.add_child(glass)
	var water := MeshInstance3D.new()
	water.mesh = _make_bottle_surface(0.96, _room_water_top, true)
	var wmat := ShaderMaterial.new(); wmat.shader = _make_water_still_shader()
	wmat.set_shader_parameter("water_y", _room_water_top)
	wmat.set_shader_parameter("band", _room_R * 0.25)
	wmat.set_shader_parameter("wscale", 1.0 / maxf(_room_R, 0.001))
	water.material_override = wmat
	_room_water_mat = wmat                           # 存下 → _process 逐帧驱动涟漪
	_room_root.add_child(water)
	# 灯光：上方俯照 + 中心补光。
	var top := SpotLight3D.new()
	top.position = Vector3(0, _room_top + 8.0, 0)
	top.rotation = Vector3(-PI * 0.5, 0, 0)
	top.light_energy = 12.0; top.spot_range = _room_R * 8.0; top.spot_angle = 50.0
	top.light_color = Color(0.85, 0.92, 1.0); top.shadow_enabled = false
	_room_root.add_child(top)
	var fill := OmniLight3D.new()
	fill.position = Vector3.ZERO; fill.light_energy = 3.0; fill.omni_range = _room_R * 6.0
	fill.light_color = Color(0.5, 0.65, 1.0); fill.shadow_enabled = false
	_room_root.add_child(fill)
	# 每种"完成过"的模型 → 一个 MultiMeshInstance3D，悬浮在圆瓶身水中。
	var g := 0
	for path in MODELS:
		var cnt := mini(int(_counts.get(path, 0)), ROOM_CAP)
		if cnt <= 0:
			continue
		_room_root.add_child(_build_room_multimesh(path, cnt, g))
		g += cnt
	# 气泡池（自旋水晶周围冒泡上浮）。
	_bubble_mm = MultiMesh.new()
	_bubble_mm.transform_format = MultiMesh.TRANSFORM_3D
	var bsph := SphereMesh.new()
	bsph.radius = 1.0; bsph.height = 2.0; bsph.radial_segments = 8; bsph.rings = 4
	_bubble_mm.mesh = bsph
	_bubble_mm.instance_count = BUBBLE_MAX
	var bmmi := MultiMeshInstance3D.new()
	bmmi.multimesh = _bubble_mm
	var bmat := ShaderMaterial.new(); bmat.shader = _make_bubble_shader()
	bmmi.material_override = bmat
	_room_root.add_child(bmmi)
	_bub_pos = PackedVector3Array(); _bub_pos.resize(BUBBLE_MAX)
	_bub_vel = PackedVector3Array(); _bub_vel.resize(BUBBLE_MAX)
	_bub_life = PackedFloat32Array(); _bub_life.resize(BUBBLE_MAX)
	_bub_r = PackedFloat32Array(); _bub_r.resize(BUBBLE_MAX)
	_bub_idx = 0
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in BUBBLE_MAX:
		_bub_life[i] = 0.0
		_bubble_mm.set_instance_transform(i, hidden)
	_room_moving = true                             # 开场即开始下沉/沉底
	# 缩放边界：瓶最宽=2·_room_R，占屏宽比 f 时距离 d=_room_R/(f·tan(fov/2))。
	# 放大上限=瓶宽占屏 80%（最近），缩小下限=占屏 33%（最远）。
	var half_tan := tan(deg_to_rad(_camera.fov) * 0.5)
	_room_dist_min = _room_R / (0.80 * half_tan)
	_room_dist_max = _room_R / (0.33 * half_tan)
	_room_dist = clampf(_room_R * 3.2 + _room_top * 0.5, _room_dist_min, _room_dist_max)
	_update_room_cam()

func _spawn_bubble(at: Vector3, radius: float) -> void:
	var i := _bub_idx
	_bub_idx = (_bub_idx + 1) % BUBBLE_MAX
	_bub_pos[i] = at
	_bub_vel[i] = Vector3(randf_range(-0.3, 0.3), randf_range(2.2, 3.4), randf_range(-0.3, 0.3))
	_bub_life[i] = randf_range(1.5, 2.8)
	_bub_r[i] = radius

func _close_room() -> void:
	if not _in_room:
		return
	_sfx_click.play()
	_in_room = false
	if _room_next_btn != null:
		_room_next_btn.visible = false
	_show_room_progress(false)                        # 隐藏进度条 + 完成圆圈
	if _room_root != null and is_instance_valid(_room_root):
		_room_root.queue_free()
		_room_root = null
	_env.fog_enabled = false                          # 恢复主游戏环境（黑底、无雾）
	_apply_lighting(false)
	_world.visible = true
	_spray_fx.visible = true
	_toggle_btn.visible = true
	_apply_bottom_state()
	_camera.transform = _cam_saved
	_touches.clear()
	_room_touches.clear()

# 成就空间右上角换关：退出空间并随机换一关。
func _room_next_level() -> void:
	if _next_fired:                        # 刚触发过长按清空 → 本次不换关
		_next_fired = false
		return
	_close_room()
	_load_random_level()

# 模型在成就空间里的水平半径（柱体半径）：归一化到 TARGET_W 后再乘 TABLE_DISP。
func _model_room_radius(path: String) -> float:
	var scene := (load(path) as PackedScene).instantiate()
	var m := _find_mesh(scene)
	var r := TARGET_W * TABLE_DISP * 0.3
	if m != null and m.mesh != null:
		var ab := m.get_aabb()
		var ext: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
		var sc := TARGET_W / maxf(ext, 0.0001)
		r = maxf(ab.size.x, ab.size.z) * 0.5 * sc * TABLE_DISP
	scene.queue_free()
	return r

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

func _build_room_multimesh(path: String, count: int, start_g: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _centered_mesh(path)
	mm.instance_count = count
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hash(path)) + start_g * 7919
	var GA := 2.3999632
	var positions := PackedVector3Array()
	var vels := PackedVector3Array()
	var avels := PackedVector3Array()
	for i in count:
		# 球体内低差异分布：随机分布在瓶身球内（不出瓶）。
		var g := float(start_g + i) + 0.5
		var rr := _room_body_r * pow(fposmod(g * 0.7548776662, 1.0), 1.0 / 3.0)
		var ct := 1.0 - 2.0 * fposmod(g * 0.5698402910, 1.0)
		var stt := sqrt(maxf(0.0, 1.0 - ct * ct))
		var theta := g * GA
		var pos := Vector3(rr * stt * cos(theta), rr * ct, rr * stt * sin(theta))
		# 随机整体朝向（在水里各朝各方向）+ 统一显示缩放。
		var ax := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if ax.length() < 0.01:
			ax = Vector3.UP
		var basis := Basis(ax.normalized(), rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * TABLE_DISP)
		mm.set_instance_transform(i, Transform3D(basis, pos))
		positions.append(pos)
		vels.append(Vector3.ZERO)
		avels.append(Vector3.ZERO)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = _make_room_shader()
	mmi.material_override = mat
	_room_mmis.append({"node": mmi, "pos": positions, "vel": vels, "avel": avels})   # 位置/速度/角速度
	return mmi

func _update_room_cam() -> void:
	# 只绕竖直轴旋转：固定俯角 ROOM_ELEV，方位角 _room_yaw 决定绕 Y 环绕位置。
	# 注视点=瓶子竖直中心（瓶底 -R 到颈口 _room_top 的中点），缩放沿固定 30° 视线纯推拉，
	# 瓶子始终居中，缩放不改变俯视角/构图。
	var center := Vector3(0.0, (-_room_R + _room_top) * 0.5, 0.0)
	var ce := cos(ROOM_ELEV)
	var offset := Vector3(ce * sin(_room_yaw), sin(ROOM_ELEV), ce * cos(_room_yaw)) * _room_dist
	_camera.transform = Transform3D.IDENTITY.looking_at(-offset, Vector3.UP)
	_camera.transform.origin = center + offset

# 成就空间内触摸：单指落下=点水起涟漪、拖拽=旋转视角，双指捏合缩放；鼠标滚轮缩放。
func _room_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_room_touches[event.index] = event.position
			_room_yaw_vel = 0.0
			if _room_touches.size() == 1:
				_room_on_jar = _ray_hits_jar(event.position)   # 落在瓶上 → 玩水不旋转
				if _room_on_jar:
					_room_impact(event.position)
		else:
			_room_touches.erase(event.index)
			if _room_touches.size() == 0:
				_room_on_jar = false
		if _room_touches.size() == 2:
			_room_pinch = _room_two_dist()
	elif event is InputEventScreenDrag:
		if _room_touches.has(event.index):
			_room_touches[event.index] = event.position
		if _room_touches.size() == 1:
			if _room_on_jar:
				_room_impact(event.position)          # 在瓶上拖 → 连续起涟漪，不旋转
			else:
				_room_orbit(event.relative)           # 瓶外拖 → 旋转视角
		elif _room_touches.size() == 2:
			var d := _room_two_dist()
			if _room_pinch > 0.0:
				_room_zoom(d - _room_pinch)
			_room_pinch = d
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_room_dragging = event.pressed
			if event.pressed:
				_room_yaw_vel = 0.0
				_room_on_jar = _ray_hits_jar(event.position)
				if _room_on_jar:
					_room_impact(event.position)
			else:
				_room_on_jar = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_room_zoom(40.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_room_zoom(-40.0)
	elif event is InputEventMouseMotion:
		if _room_dragging:
			if _room_on_jar:
				_room_impact((event as InputEventMouseMotion).position)
			else:
				_room_orbit((event as InputEventMouseMotion).relative)

# 物理模拟：涟漪波前经过 → 给冲量；每帧积分位置，水阻力(阻尼)减速，限制在瓶内。
func _room_sim(delta: float) -> void:
	var DRAG := exp(-0.4 * delta)                     # 水阻力更小 → 漂得更久
	var GRAV := 2.2                                   # 重力：最终沉底
	var moving := false
	var bub_budget := 6                               # 每帧最多新气泡
	for entry in _room_mmis:
		var node: MultiMeshInstance3D = entry.get("node")
		if not is_instance_valid(node):
			continue
		var mm: MultiMesh = node.multimesh
		var pos: PackedVector3Array = entry.get("pos")
		var vel: PackedVector3Array = entry.get("vel")
		var avel: PackedVector3Array = entry.get("avel")
		var ADRAG := exp(-0.5 * delta)                # 角速度水阻力（放缓，维持 ~1 圈/秒）
		for i in pos.size():
			var p := pos[i]
			var v := vel[i]
			v *= DRAG                                 # 水阻力减速
			v.y -= GRAV * delta                       # 重力下沉
			p += v * delta
			# 约束在瓶内：横向贴瓶壁母线(可沿颈上升)，竖直不越过瓶颈水面、不穿底；撞壁反弹。
			var REST := 0.85
			var y_hi := _room_water_top - _room_cm     # 顶：不越过瓶颈水面
			var y_lo := -_room_R + _room_cm            # 底：不穿瓶底
			if p.y > y_hi:
				p.y = y_hi
				if v.y > 0.0:
					v.y = -v.y * REST
			elif p.y < y_lo:
				p.y = y_lo
				if v.y < 0.0:
					v.y = -v.y * REST
			var maxr := maxf(0.0, _bottle_radius(p.y) - _room_cm)   # 该高度处瓶内可用半径
			var hxz := Vector2(p.x, p.z)
			var hl := hxz.length()
			if hl > maxr and hl > 0.0001:
				var hn := hxz / hl
				p.x = hn.x * maxr; p.z = hn.y * maxr
				var vn := v.x * hn.x + v.z * hn.y
				if vn > 0.0:
					v.x -= hn.x * (1.0 + REST) * vn
					v.z -= hn.y * (1.0 + REST) * vn
			pos[i] = p
			vel[i] = v
			# 冲击自旋：绕角速度轴转动 basis，之后衰减（shader 的慢自转仍叠加其上）。
			var a := avel[i]
			var b := mm.get_instance_transform(i).basis
			var asp := a.length()
			if asp > 0.01:
				b = Basis(a / asp, asp * delta) * b
				a *= ADRAG
				avel[i] = a
			mm.set_instance_transform(i, Transform3D(b, p))
			# 自旋足够快 → 周围随机冒气泡。
			if asp > 5.0 and bub_budget > 0 and randf() < asp * 0.012:
				var off := Vector3(randf_range(-1, 1), randf_range(-0.4, 0.6), randf_range(-1, 1)).normalized() * (TARGET_W * TABLE_DISP * 0.5)
				_spawn_bubble(p + off, randf_range(0.12, 0.28))
				bub_budget -= 1
			if v.length() > 0.03 or asp > 0.05:
				moving = true
		entry["pos"] = pos
		entry["vel"] = vel
		entry["avel"] = avel
	# 水晶两两碰撞（在墙约束之后统一解算）。
	if _room_collide():
		moving = true
	# 更新气泡：上浮 + 轻微晃动 + 到水面/寿命尽消失。
	if _bubble_mm != null:
		var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
		for i in BUBBLE_MAX:
			if _bub_life[i] <= 0.0:
				continue
			_bub_life[i] -= delta
			var bv := _bub_vel[i]
			bv.x += randf_range(-0.7, 0.7) * delta
			bv.z += randf_range(-0.7, 0.7) * delta
			var bp := _bub_pos[i] + bv * delta
			if _bub_life[i] <= 0.0 or bp.y >= _room_water_top:
				_bub_life[i] = 0.0
				_bubble_mm.set_instance_transform(i, hidden)
				continue
			# 收进瓶身内壁（内壁=外半径-壁厚，再退一个气泡半径 → 不穿壁；细口处漏斗收拢）。
			var lim := maxf(0.0, _bottle_radius(bp.y) - _room_wall - _bub_r[i])
			var bxz := Vector2(bp.x, bp.z)
			if bxz.length() > lim:
				bxz = bxz.normalized() * lim
				bp.x = bxz.x; bp.z = bxz.y
			_bub_vel[i] = bv
			_bub_pos[i] = bp
			var fade := clampf(_bub_life[i], 0.0, 1.0)
			var sc := _bub_r[i] * (0.5 + 0.5 * fade)
			_bubble_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sc), bp))
			moving = true                              # 有气泡仍在动 → 继续模拟
	_room_moving = moving

# 把位置夹回瓶内：竖直限在[瓶底, 瓶颈水面]，横向贴瓶壁母线（可进颈，不越水面）。
func _room_clamp_pos(p: Vector3) -> Vector3:
	p.y = clampf(p.y, -_room_R + _room_cm, _room_water_top - _room_cm)
	var maxr := maxf(0.0, _bottle_radius(p.y) - _room_cm)
	var hxz := Vector2(p.x, p.z)
	if hxz.length() > maxr:
		hxz = hxz.normalized() * maxr
		p.x = hxz.x; p.z = hxz.y
	return p

# 水晶两两碰撞：均匀网格加速 + 冲量分离；碰撞后重新贴回瓶内。返回是否有碰撞发生。
func _room_collide() -> bool:
	var cr := _room_cr
	if cr <= 0.0:
		return false
	var mind := cr * 2.0
	# 收集所有实例到扁平数组。
	var gpos := PackedVector3Array()
	var gvel := PackedVector3Array()
	for entry in _room_mmis:
		var node: MultiMeshInstance3D = entry.get("node")
		if not is_instance_valid(node):
			continue
		var pos: PackedVector3Array = entry.get("pos")
		var vel: PackedVector3Array = entry.get("vel")
		for i in pos.size():
			gpos.append(pos[i])
			gvel.append(vel[i])
	var n := gpos.size()
	if n < 2:
		return false
	# 均匀网格（格边=碰撞直径），只查相邻 27 格 → 近 O(n)。
	var cell := mind
	var grid := {}
	for k in n:
		var c := Vector3i(int(floor(gpos[k].x / cell)), int(floor(gpos[k].y / cell)), int(floor(gpos[k].z / cell)))
		if not grid.has(c):
			grid[c] = PackedInt32Array()
		grid[c].append(k)
	var REST := 0.3
	var changed := false                                          # 有位置分离 → 需写回
	var active := false                                           # 有明显靠近碰撞 → 保持模拟
	for a in n:
		var ca := Vector3i(int(floor(gpos[a].x / cell)), int(floor(gpos[a].y / cell)), int(floor(gpos[a].z / cell)))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var cc := ca + Vector3i(dx, dy, dz)
					if not grid.has(cc):
						continue
					for b in grid[cc]:
						if b <= a:
							continue
						var d := gpos[b] - gpos[a]
						var dist := d.length()
						if dist >= mind or dist < 0.0001:
							continue
						var nrm := d / dist
						var overlap := mind - dist
						gpos[a] -= nrm * (overlap * 0.5)          # 分离重叠
						gpos[b] += nrm * (overlap * 0.5)
						var rv := (gvel[b] - gvel[a]).dot(nrm)
						if rv < 0.0:                              # 相互靠近 → 交换法向动量
							var j := -(1.0 + REST) * rv * 0.5
							gvel[a] -= nrm * j
							gvel[b] += nrm * j
							if rv < -0.15:                        # 明显碰撞才唤醒模拟（静置接触不算）
								active = true
						changed = true
	if not changed:
		return false
	# 写回各 entry 并更新 MultiMesh 变换（保留自转 basis，只改位置），顺便再夹回瓶内。
	var k2 := 0
	for entry in _room_mmis:
		var node: MultiMeshInstance3D = entry.get("node")
		if not is_instance_valid(node):
			continue
		var mm: MultiMesh = node.multimesh
		var pos: PackedVector3Array = entry.get("pos")
		var vel: PackedVector3Array = entry.get("vel")
		for i in pos.size():
			var p := _room_clamp_pos(gpos[k2])                   # 碰撞后夹回瓶内（含颈/水面）
			pos[i] = p
			vel[i] = gvel[k2]
			var basis := mm.get_instance_transform(i).basis
			mm.set_instance_transform(i, Transform3D(basis, p))
			k2 += 1
		entry["pos"] = pos
		entry["vel"] = vel
	return active

# 相机射线是否真正打到圆瓶身球（否则瓶外背景 → 旋转，不冲击）。
func _ray_hits_jar(pos: Vector2) -> bool:
	var from := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	var oc := from - Vector3(0.0, _room_cy, 0.0)   # 球心=(0,_room_cy,0)
	var b := oc.dot(dir)
	var disc := b * b - (oc.dot(oc) - _room_R * _room_R)
	if disc < 0.0:
		return false                               # 射线未与瓶身球相交
	return (-b + sqrt(disc)) >= 0.0                # 交点在相机前方

# 点击处投射到水中一点，产生"一片冲击"：对该处一定范围内的水晶施加即时爆发冲量。
func _room_impact(pos: Vector2) -> void:
	var from := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	if absf(dir.y) < 0.0001:
		return
	var t := (_room_cy - from.y) / dir.y
	if t < 0.0:
		return
	var hit := from + dir * t
	var p := Vector2(hit.x, hit.z)
	if p.length() > _room_water_r:
		p = p.normalized() * _room_water_r
	var center := Vector3(p.x, _room_cy, p.y)
	# 冲击水泡声：拖拽会连续触发，节流到 ~0.14s 一次，随机音高更自然。
	if _sfx_bubble != null and (_last_bubble_t < 0.0 or _room_time - _last_bubble_t > 0.14):
		_last_bubble_t = _room_time
		_sfx_bubble.pitch_scale = randf_range(0.85, 1.2)
		_sfx_bubble.play()
	# 视觉：记录冲击中心（水面/水体会闪一团渐隐光）。
	_room_rips[_rip_idx] = Vector4(center.x, center.y, center.z, _room_time)
	_rip_idx = (_rip_idx + 1) % MAX_RIP
	var pk := PackedVector4Array(_room_rips)
	if _room_water_mat != null:
		_room_water_mat.set_shader_parameter("rips", pk)
	if _room_waterbody_mat != null:
		_room_waterbody_mat.set_shader_parameter("rips", pk)
	# 物理：竖直柱状冲击——按水平距离判定，把该列水晶（含已沉底的）向外+强烈向上掀起。
	var STR := 13.0
	var c2 := Vector2(center.x, center.z)
	for entry in _room_mmis:
		var node: MultiMeshInstance3D = entry.get("node")
		if not is_instance_valid(node):
			continue
		var poss: PackedVector3Array = entry.get("pos")
		var vels: PackedVector3Array = entry.get("vel")
		var avels: PackedVector3Array = entry.get("avel")
		for i in poss.size():
			var pxz := Vector2(poss[i].x, poss[i].z)
			var d := pxz.distance_to(c2)
			if d < _room_burst_r:
				var fall := 1.0 - d / _room_burst_r
				var dh := pxz - c2
				var dirh := Vector3(dh.x, 0.0, dh.y)
				if dirh.length() < 0.001:
					dirh = Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1))
				vels[i] += (dirh.normalized() * 0.7 + Vector3.UP * 0.9) * (STR * fall)
				# 冲击也随机造成自旋。
				var rax := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
				if rax.length() < 0.01:
					rax = Vector3.UP
				avels[i] += rax.normalized() * (randf_range(24.0, 26.5) * fall)   # ≈4 圈/秒
		entry["vel"] = vels
		entry["avel"] = avels
	_room_moving = true

func _room_two_dist() -> float:
	var pts := _room_touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1])

func _room_orbit(rel: Vector2) -> void:
	# 只用水平分量绕竖直轴转；竖直拖拽忽略。
	var dx := -rel.x * ROOM_ROT_SENS
	_room_yaw += dx
	var dt := maxf(get_process_delta_time(), 0.0001)
	_room_yaw_vel = dx / dt                                         # 记录角速度供松手惯性
	_update_room_cam()

func _room_zoom(delta_px: float) -> void:
	_room_dist = clampf(_room_dist - delta_px * 0.03, _room_dist_min, _room_dist_max)   # 拉近/拉远
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
	// 每实例绕一个随机轴缓慢旋转（在水里各朝各方向漂转）。
	float id = float(INSTANCE_ID);
	vec3 axis = normalize(vec3(sin(id * 1.13 + 0.3), sin(id * 2.31 + 1.7), sin(id * 3.71 + 4.1)));
	float ang = TIME * 0.14 + id * 1.7;
	float s = sin(ang), c = cos(ang);
	VERTEX = VERTEX * c + cross(axis, VERTEX) * s + axis * dot(axis, VERTEX) * (1.0 - c);
	NORMAL = NORMAL * c + cross(axis, NORMAL) * s + axis * dot(axis, NORMAL) * (1.0 - c);
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

# 气泡：透明小球，中心清透、边缘亮（菲涅尔），像水里的气泡。
func _make_bubble_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, specular_schlick_ggx;
void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
	ALBEDO = vec3(0.75, 0.88, 1.0);
	ROUGHNESS = 0.0;
	METALLIC = 0.0;
	SPECULAR = 1.0;
	EMISSION = vec3(0.35, 0.55, 0.95) * fres * 0.6;
	ALPHA = clamp(0.06 + 0.8 * fres, 0.0, 0.9);   // 中心透、边缘亮
}
"""
	return sh

# 烧瓶母线：接近纯球的圆肚 → 顶部收肩 → 直颈（无卷唇）。
func _bottle_radius(y: float) -> float:
	var R := _room_R
	var nr := _room_neck_r
	var body_top := R * 0.94                       # 球身收口高度（接近纯球顶）
	var neck_start := R * 1.0                        # 进入直颈
	if y <= body_top:
		return sqrt(maxf(0.0, R * R - y * y))       # 圆肚（纯球身）
	elif y <= neck_start:
		var r0 := sqrt(maxf(0.0, R * R - body_top * body_top))
		var t := (y - body_top) / (neck_start - body_top)
		return lerpf(r0, nr, smoothstep(0.0, 1.0, t))   # 肩部
	return nr                                        # 直颈

# 旋转母线生成瓶面 ArrayMesh（rscale 缩放半径；y 从 -R 到 y_top；cap_top 加水面盖）。
# wall>0：双层壁（外壁 + 内壁向内缩 wall + 口沿圈），瓶壁有厚度。
func _make_bottle_surface(rscale: float, y_top: float, cap_top: bool, wall := 0.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var SEG := 48
	var RN := 72
	var y0 := -_room_R
	# 外壁
	for j in RN + 1:
		var y := lerpf(y0, y_top, float(j) / float(RN))
		var r := _bottle_radius(y) * rscale
		for a in SEG + 1:
			var ang := TAU * float(a) / float(SEG)
			st.set_uv(Vector2(float(a) / float(SEG), float(j) / float(RN)))
			st.add_vertex(Vector3(r * cos(ang), y, r * sin(ang)))
	for j in RN:
		for a in SEG:
			var i0 := j * (SEG + 1) + a
			var i1 := i0 + 1
			var i2 := i0 + (SEG + 1)
			var i3 := i2 + 1
			st.add_index(i0); st.add_index(i2); st.add_index(i1)
			st.add_index(i1); st.add_index(i2); st.add_index(i3)
	if wall > 0.0:
		# 内壁（半径向内缩 wall，绕序翻转 → 法线朝内）。
		var inner_base := (RN + 1) * (SEG + 1)
		for j in RN + 1:
			var y := lerpf(y0, y_top, float(j) / float(RN))
			var r := maxf(0.0, _bottle_radius(y) * rscale - wall)
			for a in SEG + 1:
				var ang := TAU * float(a) / float(SEG)
				st.set_uv(Vector2(float(a) / float(SEG), float(j) / float(RN)))
				st.add_vertex(Vector3(r * cos(ang), y, r * sin(ang)))
		for j in RN:
			for a in SEG:
				var i0 := inner_base + j * (SEG + 1) + a
				var i1 := i0 + 1
				var i2 := i0 + (SEG + 1)
				var i3 := i2 + 1
				st.add_index(i0); st.add_index(i1); st.add_index(i2)
				st.add_index(i1); st.add_index(i3); st.add_index(i2)
		# 口沿圈：把外壁顶缘和内壁顶缘连成环（瓶口可见厚度）。
		var ot := _bottle_radius(y_top) * rscale
		var it := maxf(0.0, ot - wall)
		var rim := (RN + 1) * (SEG + 1) * 2
		for a in SEG + 1:
			var ang := TAU * float(a) / float(SEG)
			st.set_uv(Vector2(float(a) / float(SEG), 1.0))
			st.add_vertex(Vector3(ot * cos(ang), y_top, ot * sin(ang)))
		for a in SEG + 1:
			var ang := TAU * float(a) / float(SEG)
			st.set_uv(Vector2(float(a) / float(SEG), 0.98))
			st.add_vertex(Vector3(it * cos(ang), y_top, it * sin(ang)))
		for a in SEG:
			var o0 := rim + a
			var o1 := o0 + 1
			var n0 := rim + (SEG + 1) + a
			var n1 := n0 + 1
			st.add_index(o0); st.add_index(n0); st.add_index(o1)
			st.add_index(o1); st.add_index(n0); st.add_index(n1)
	if cap_top:                                    # 仅水面用（wall=0）
		var rt := _bottle_radius(y_top) * rscale
		var base := (RN + 1) * (SEG + 1)
		st.set_uv(Vector2(0.5, 1.0)); st.add_vertex(Vector3(0.0, y_top, 0.0))   # 中心
		for a in SEG + 1:
			var ang := TAU * float(a) / float(SEG)
			st.set_uv(Vector2(float(a) / float(SEG), 1.0))
			st.add_vertex(Vector3(rt * cos(ang), y_top, rt * sin(ang)))
		for a in SEG:
			st.add_index(base); st.add_index(base + 1 + a); st.add_index(base + 2 + a)
	st.generate_normals()
	return st.commit()

# 静止水体：半透明蓝玻璃质感（无涟漪）。
func _make_water_still_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, specular_schlick_ggx;
uniform vec3 wtint : source_color = vec3(0.2, 0.45, 0.9);
uniform float rtime = 0.0;
uniform float ripple = 0.0;        // 闪光强度（有气泡时增大，0=不闪）
uniform float water_y = 0.0;       // 水面 y
uniform float band = 1.0;          // 水面往下多少内算"表面"
uniform float wscale = 1.0;        // 密度基准（≈1/瓶半径）
varying vec3 lpos;
void vertex() { lpos = VERTEX; }
void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
	// 仅水面附近闪闪光：位置伪随机点，随时间明灭（无涟漪、无形变）。
	float top_f = smoothstep(water_y - band, water_y, lpos.y);
	vec2 cell = floor(lpos.xz * wscale * 16.0);
	float h = fract(sin(dot(cell, vec2(41.3, 289.1))) * 43758.5453);
	float tw = pow(max(sin(rtime * 3.2 + h * 6.2831), 0.0), 8.0);   // 尖锐明灭
	float spark = ripple * top_f * tw * (0.4 + 0.6 * h);
	ALBEDO = wtint;
	ROUGHNESS = 0.06;
	SPECULAR = 0.8;
	EMISSION = wtint * 0.08 + vec3(0.7, 0.85, 1.0) * spark * 1.2;   // 闪点偏白亮
	ALPHA = clamp(mix(0.06, 0.2, fres) + 0.25 * spark, 0.0, 0.6);
}
"""
	return sh

# 瓶子玻璃壳：透明、菲涅尔边缘更实、泛蓝、强反光。
func _make_jar_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, specular_schlick_ggx;
uniform vec3 tint : source_color = vec3(0.4, 0.6, 1.0);
void fragment() {
	// 硼硅玻璃：中心近乎清透、边缘强菲涅尔反光，抛光镜面。
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.4);
	ALBEDO = tint;
	METALLIC = 0.0;
	ROUGHNESS = 0.0;                              // 抛光镜面
	SPECULAR = 1.0;
	EMISSION = tint * (0.04 + 0.7 * fres);        // 边缘更亮的高光轮廓
	ALPHA = clamp(mix(0.03, 0.62, fres), 0.0, 0.7);   // 中心更清透、边缘更实（厚壁感）
}
"""
	return sh

# 水体：瓶内半透明蓝；点击处向外扩散的 3D 球面涟漪（在水里显现）。
func _make_water_body_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never;
uniform vec3 wtint : source_color = vec3(0.2, 0.45, 0.9);
uniform vec4 rips[6];      // xyz=中心, w=起始时间(<0 未激活)
uniform float rtime = 0.0;
uniform float burst = 5.0;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
	float hit = 0.0;
	for (int i = 0; i < 6; i++) {
		if (rips[i].w < 0.0) continue;
		float t = rtime - rips[i].w;
		if (t < 0.0 || t > 1.2) continue;
		float dist = distance(wpos, rips[i].xyz);     // 一团冲击：中心亮、原地渐隐
		hit += smoothstep(burst, 0.0, dist) * exp(-t * 4.0);
	}
	ALBEDO = wtint;
	ROUGHNESS = 0.1;
	EMISSION = wtint * (0.12 + 1.4 * hit);
	ALPHA = clamp(mix(0.18, 0.36, fres) + 0.5 * hit, 0.0, 0.9);
}
"""
	return sh

# 水面：半透明圆盘，点击处扩散的同心涟漪（用 3D 中心的 XZ）。
func _make_water_surface_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never;
uniform vec3 wtint : source_color = vec3(0.35, 0.6, 1.0);
uniform float radius = 8.0;
uniform vec4 rips[6];      // xyz=中心, w=起始时间(<0 未激活)
uniform float rtime = 0.0;
uniform float burst = 5.0;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float d = length(wpos.xz);
	if (d > radius) discard;
	float hit = 0.0;
	for (int i = 0; i < 6; i++) {
		if (rips[i].w < 0.0) continue;
		float t = rtime - rips[i].w;
		if (t < 0.0 || t > 1.2) continue;
		float dist = distance(wpos.xz, rips[i].xz);
		hit += smoothstep(burst, 0.0, dist) * exp(-t * 4.0);   // 一团冲击原地渐隐
	}
	float edge = smoothstep(radius, radius * 0.85, d);
	ALBEDO = wtint;
	ROUGHNESS = 0.05;
	SPECULAR = 0.9;
	EMISSION = wtint * (0.14 + 1.0 * hit);
	ALPHA = clamp(0.28 + 0.6 * hit, 0.0, 0.95) * edge;
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
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.5);
	ALBEDO = tint;
	METALLIC = 0.3;
	ROUGHNESS = 0.05;
	SPECULAR = 0.9;
	EMISSION = tint * (0.25 + 0.8 * fres);         // 水晶色 + 边缘辉光
	ALPHA = clamp(0.7 * fade, 0.0, 1.0);           // 更实的水晶（不再几乎全透）
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
	# 调试暗门：成就页面长按左上角满 7s → 对应水晶翻倍。
	if _toggle_press_t >= 0.0:
		_toggle_press_t += delta
		if _toggle_press_t >= 7.0 and not _debug_fired:
			_debug_fired = true
			_toggle_press_t = -1.0
			_debug_double_count()
	# 调试暗门：成就页面长按播放键满 7s → 清空全部成就。
	if _next_press_t >= 0.0:
		_next_press_t += delta
		if _next_press_t >= 7.0 and not _next_fired:
			_next_fired = true
			_next_press_t = -1.0
			_debug_clear_counts()
	if _in_room:                              # 成就空间：自转/浮动在 shader 里跑
		# 松手后的旋转惯性（不在拖拽时才滑行，带指数衰减）。
		var dragging := _room_dragging or _room_touches.size() >= 1
		if not dragging and absf(_room_yaw_vel) > 0.002:
			_room_yaw += _room_yaw_vel * delta
			_room_yaw_vel *= pow(0.05, delta)     # 惯性衰减
			_update_room_cam()
		_room_time += delta                       # 涟漪时钟
		if _room_water_mat != null:
			_room_water_mat.set_shader_parameter("rtime", _room_time)
			# 水面涟漪幅度随活跃气泡数增减（平滑过渡）。
			var nb := 0
			for i in BUBBLE_MAX:
				if _bub_life[i] > 0.0:
					nb += 1
			var rip_target := clampf(float(nb) / 6.0, 0.0, 1.0)
			_room_ripple = lerpf(_room_ripple, rip_target, clampf(delta * 3.0, 0.0, 1.0))
			_room_water_mat.set_shader_parameter("ripple", _room_ripple)
		if _room_waterbody_mat != null:
			_room_waterbody_mat.set_shader_parameter("rtime", _room_time)
		# 涟漪冲击 → 给水中模型冲量，之后靠水阻力停下（有涟漪或还在动才模拟）。
		var any_rip := false
		for rip in _room_rips:
			if (rip as Vector4).w >= 0.0 and (_room_time - (rip as Vector4).w) < 3.0:
				any_rip = true
				break
		if any_rip or _room_moving:
			_room_sim(delta)
		if _godray_mat != null:                   # 神光光心 = 瓶内中心
			var rvp := get_viewport().get_visible_rect().size
			if rvp.x > 0.0 and rvp.y > 0.0:
				_godray_mat.set_shader_parameter("light_uv", _camera.unproject_position(Vector3(0.0, _room_cy, 0.0)) / rvp)
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
	# 命中模型：手指移动时喷水珠（停下不再生成，避免叠加变亮）。
	# 离开模型到背景：仍在清洗则继续在最后命中处喷，亮球留在原地不消失。
	var want_emit := _washing and (not _wash_hitting or _moved)
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
