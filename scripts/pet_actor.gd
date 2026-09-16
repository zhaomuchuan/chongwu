extends Node2D
## 3D 小兔子（Kenney cube pets GLB），SubViewport 渲染进 2D 场景。
## 动作系统：GLB 内嵌 AnimationPlayer 的 7 段动画（idle/walk/run/eat/dance/
## gesture-positive/gesture-negative）+ 少量程序化补充（好奇张望、呼吸起伏）。
## 数值层 PetBrain 结算后发信号，本节点只负责「演出来」，绝不改数值。

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

const PET_SCENE := preload("res://assets/models/animal-bunny.glb")
const VIEW_SIZE := 420
const SPRITE_SCALE := 0.82
const BASE_YAW := -0.50   # 微微侧站，露出圆尾巴

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_GREEN := Color(0.224, 1.0, 0.314)

const IDLE_ANIMS := ["idle", "walk", "run"]
const HAPPY_EXPR := ["excited", "happy"]
const SAD_EXPR := ["sad", "distress"]

var _viewport: SubViewport
var _world: Node3D
var _cam_rig: Node3D        # 相机轨道架：拖动鼠标时绕宠物旋转
var _pivot: Node3D          # 居中 + 整体朝向/起伏（自定义动作层）
var _pet: Node3D            # GLB 实例（AnimationPlayer 驱动这一层）
var _player: AnimationPlayer
var _cam: Camera3D
var _hit: Control           # 宠物点击/拖拽热区
var _bubble: Control        # 头顶对话气泡
var _bubble_hide_at := -1.0
var _cyan_light: OmniLight3D
var _pink_light: OmniLight3D
var _sprite: Sprite2D

var _t := 0.0
var _expression := "neutral"
var _reacting := false
var _token := 0             # 反应代际：新反应使旧反应的回 idle 失效
var _look_until := -1.0     # 好奇张望结束时间
var _pivot_base_y := 0.0

# 鼠标轨道视角
var _pressing := false
var _dragging := false
var _orbit_yaw := 0.0
var _orbit_pitch := deg_to_rad(-8.0)
const ORBIT_SENS := 0.009
const HIT_HALF := 175       # 热区半边长（2D 像素）
const DRAG_THRESHOLD := 7.0

# 长时间无交互 → 自己跑近跑远撒欢
var _last_interact_t := 0.0
var _roam_id := 0
var _roaming := false
var _roam_start := 0.0
var _roam_depth := 0.0          # 当前沿相机轴向的深度（负=跑近，正=跑远）
var _roam_prev_depth := 0.0
var _roam_far := ROAM_FAR       # 本轮撒欢最远点（活泼特质会拉远）
var _nuzzle_start := -1.0       # 温顺特质：被摸头蹭蹭的时间窗
var _nuzzle_until := -1.0
var _pivot_home := Vector3.ZERO
var _cam_base_size := 2.0
var _view_scale := 1.0         # 当前透视缩放（近>1 远<1），2D 光环跟随
const ROAM_DELAY := 30.0        # 空闲多久后开始
const ROAM_DURATION := 6.5      # 一次撒欢时长
const ROAM_NEAR := -1.25
const ROAM_FAR := 2.6
const ROAM_TRIPS := 1.5         # 近远往复次数


func _ready() -> void:
	_build_view()
	PetState.state_changed.connect(_on_state_changed)
	PetBrain.interaction_applied.connect(play_interaction)
	PetBrain.chat_sentiment_applied.connect(play_chat)
	_on_state_changed()
	_start_idle()
	_ambient_loop()
	_roam_loop()


# ---------- 场景搭建 ----------

func _build_view() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(VIEW_SIZE, VIEW_SIZE)
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_world = Node3D.new()
	_viewport.add_child(_world)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.26, 0.45)
	env.ambient_light_energy = 0.9
	env_node.environment = env
	_world.add_child(env_node)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -35, 0)
	key.light_energy = 1.25
	key.shadow_enabled = false
	_world.add_child(key)

	_cyan_light = OmniLight3D.new()
	_cyan_light.light_color = NEON_CYAN
	_cyan_light.light_energy = 1.6
	_cyan_light.position = Vector3(-2.2, 0.8, 1.6)
	_world.add_child(_cyan_light)

	_pink_light = OmniLight3D.new()
	_pink_light.light_color = NEON_PINK
	_pink_light.light_energy = 1.3
	_pink_light.position = Vector3(2.2, 1.1, -1.2)
	_world.add_child(_pink_light)

	# 相机挂在轨道架上：架子绕宠物转，相机本身只负责距离
	_cam_rig = Node3D.new()
	_cam_rig.position = Vector3(0, 0.12, 0)
	_cam_rig.rotation = Vector3(_orbit_pitch, _orbit_yaw, 0)
	_world.add_child(_cam_rig)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.position = Vector3(0, 0, 3.3)
	_cam_rig.add_child(_cam)

	# pivot 承担居中和程序化动作，GLB 内部动画不受影响
	_pivot = Node3D.new()
	_world.add_child(_pivot)
	_pet = PET_SCENE.instantiate() as Node3D
	_pivot.add_child(_pet)
	_player = _find_animation_player(_pet)

	var aabb := _merged_aabb(_pet)
	# AABB 中心对齐相机原点（略向下偏，脚贴近地面光环）；取景按模型尺寸自适应，换动物也不裁切
	_pivot.position = -aabb.get_center() + Vector3(0, 0.16, 0)
	_pivot_home = _pivot.position
	_pivot_base_y = _pivot.position.y
	_cam.size = maxf(aabb.size.x, aabb.size.y) * 1.45
	_cam_base_size = _cam.size

	_sprite = Sprite2D.new()
	_sprite.texture = _viewport.get_texture()
	_sprite.centered = true
	_sprite.scale = Vector2.ONE * SPRITE_SCALE
	add_child(_sprite)

	# 透明热区：点击=戳一戳，按住拖动=360° 旋转视角。
	# 位于 UI CanvasLayer 之下，被按钮/对话框覆盖的区域不会抢事件。
	_hit = Control.new()
	_hit.size = Vector2.ONE * HIT_HALF * 2.0
	_hit.position = Vector2.ONE * -HIT_HALF
	_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_hit.gui_input.connect(_on_hit_gui_input)
	_hit.mouse_entered.connect(_on_hit_entered)
	_hit.mouse_exited.connect(_on_hit_exited)
	add_child(_hit)

	# 宠物头顶气泡（在热区之上，不挡鼠标）
	_bubble = load("res://scripts/ui/speech_bubble.gd").new()
	add_child(_bubble)


# 在兔子头顶显示一句台词，按字数停留后淡出
func show_bubble(text: String) -> void:
	if text.strip_edges() == "":
		return
	var s: Vector2 = _bubble.set_message(text)
	_bubble.position = Vector2(-s.x * 0.5, -150.0 - s.y)
	# 短台词 6s，长台词最多 15s
	_bubble_hide_at = _t + clampf(4.0 + text.length() * 0.28, 6.0, 15.0)


func _on_hit_entered() -> void:
	if not _dragging:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


func _on_hit_exited() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_pressing = false
	_dragging = false


# ---------- 公开 API：交互 / 聊天情感 → 动画 ----------

func play_interaction(kind: String) -> void:
	_last_interact_t = _t
	_end_roam()
	match kind:
		"pet":
			if PetBrain.has_trait("gentle"):
				_react_nuzzle()                         # 软乎乎：凑上来幸福地蹭你
			else:
				_react("gesture-positive", 2.1, 1.0)    # 眯眼享受
		"feed":
			_react("eat", 2.8, 1.0)                     # 低头吃东西
		"comfort":
			_react("gesture-positive", 2.4, 0.8)       # 慢慢放松
		"play":
			if PetState.energy >= 20.0:
				_react("dance", 3.4, 1.15)              # 蹦蹦跳跳
			else:
				_react("gesture-negative", 1.8, 1.0)    # 没力气，蔫一下
		"ignore":
			_react("gesture-negative", 2.4, 1.0)


func play_chat(kind: String, intensity: float) -> void:
	_last_interact_t = _t
	_end_roam()
	match kind:
		"warm":
			# 夸它 → 开心得蹦跳；轻声夸奖 → 满足点头
			if intensity >= 0.65:
				_react("dance", 2.9, 1.1)
			else:
				_react("gesture-positive", 1.9, 0.95)
		"playful":
			_react("run", 2.2, 1.2)                     # 活泼原地小跑
		"curious":
			_react_look_around(2.4)                     # 歪头东张西望
		"calm":
			_react("gesture-positive", 2.0, 0.7)
		"negative":
			_react("gesture-negative", 2.6, 1.0)        # 委屈缩起来
		_:
			if intensity >= 0.6:
				_react("gesture-positive", 1.2, 1.1)


# ---------- 鼠标：点击 / 拖拽环绕 ----------

func _on_hit_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_dragging = false
		else:
			var was_drag := _dragging
			_pressing = false
			_dragging = false
			Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
			if not was_drag:
				play_poke()   # 按下后没拖动 → 视为戳一戳
	elif event is InputEventMouseMotion and _pressing:
		if not _dragging and event.relative.length() >= DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			Input.set_default_cursor_shape(Input.CURSOR_MOVE)
			# 左右 = 水平环绕（不限位，可转满 360°）；上下 = 俯仰角（限位防止翻面）
			_orbit_yaw -= event.relative.x * ORBIT_SENS
			_orbit_pitch = clampf(_orbit_pitch - event.relative.y * ORBIT_SENS, deg_to_rad(-50.0), deg_to_rad(45.0))
			_cam_rig.rotation.y = _orbit_yaw
			_cam_rig.rotation.x = _orbit_pitch


# 外部（使用道具等）按语义播放反应：positive / run / dance / look
func play_reaction(reaction: String) -> void:
	match reaction:
		"run":
			_react("run", 2.4, 1.2)
		"dance":
			_react("dance", 3.0, 1.15)
		"look":
			_react_look_around(2.2)
		_:
			_react("gesture-positive", 2.0, 1.0)


# 戳一戳：随机一个短促的开心反应（纯表现，不改数值）
func play_poke() -> void:
	_last_interact_t = _t
	match randi() % 3:
		0:
			_react("gesture-positive", 1.3, 1.15)
		1:
			_react("run", 1.4, 1.25)
		_:
			_react("dance", 1.6, 1.2)


# ---------- 反应播放（定时切回 idle，带交叉淡入） ----------

func _react(anim: String, duration: float, speed: float) -> void:
	if _player == null or not _player.has_animation(anim):
		return
	_end_roam()
	_token += 1
	var my_token := _token
	_reacting = true
	_look_until = -1.0
	var clip: Animation = _player.get_animation(anim)
	var prev_loop := clip.loop_mode
	clip.loop_mode = Animation.LOOP_LINEAR   # 反应窗口内循环，时间到再淡出
	_player.speed_scale = speed
	_player.play(anim, 0.15)
	await get_tree().create_timer(duration / maxf(speed, 0.01)).timeout
	if my_token != _token:
		return
	clip.loop_mode = prev_loop
	_go_idle()


func _react_look_around(duration: float) -> void:
	# 好奇：没有现成的「歪头」动画，用 idle + pivot 快速转头来表现
	_end_roam()
	_token += 1
	var my_token := _token
	_reacting = true
	_player.speed_scale = 1.0
	_player.play("idle", 0.2)
	_look_until = _t + duration
	await get_tree().create_timer(duration).timeout
	if my_token != _token:
		return
	_look_until = -1.0
	_go_idle()


# 温顺特质解锁：被摸头时凑上前幸福地蹭两下（gesture-positive + 程序化前蹭）
func _react_nuzzle() -> void:
	_end_roam()
	_token += 1
	var my_token := _token
	_reacting = true
	_look_until = -1.0
	_player.speed_scale = 1.0
	_player.play("gesture-positive", 0.15)
	_nuzzle_start = _t
	_nuzzle_until = _t + 2.6
	await get_tree().create_timer(2.6).timeout
	if my_token != _token:
		return
	_nuzzle_start = -1.0
	_nuzzle_until = -1.0
	_go_idle()


func _start_idle() -> void:
	if _player == null:
		return
	for n in IDLE_ANIMS:
		if _player.has_animation(n):
			_player.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	_player.speed_scale = _idle_speed()
	_player.play("idle", 0.0)


func _go_idle() -> void:
	_reacting = false
	if _player != null and _player.has_animation("idle"):
		_player.speed_scale = _idle_speed()
		_player.play("idle", 0.25)


func _idle_speed() -> float:
	return 0.55 if _expression == "sleepy" else 1.0


# 长时间无交互：自己沿镜头方向跑近跑远撒欢；任何交互都会立刻打断
func _roam_loop() -> void:
	while true:
		await get_tree().create_timer(5.0).timeout
		if _reacting or _roaming:
			continue
		# 活泼特质（活泼好动）：空闲等待从 30s 缩短到最低 14s
		var delay: float = lerpf(ROAM_DELAY, 14.0, PetBrain.trait_strength("lively"))
		if _t - _last_interact_t < delay:
			continue
		var my_id := _begin_roam()
		await get_tree().create_timer(ROAM_DURATION).timeout
		if my_id == _roam_id:
			_end_roam()


func _begin_roam() -> int:
	_roam_id += 1
	_roaming = true
	_roam_start = _t
	_roam_depth = 0.0
	_roam_prev_depth = 0.0
	# 活泼特质：最远点从 2.6 拉到 3.5，跑得更远、缩得更小
	_roam_far = lerpf(ROAM_FAR, 3.5, PetBrain.trait_strength("lively"))
	_look_until = -1.0
	_player.speed_scale = 1.15
	_player.play("run", 0.3)
	return _roam_id


func _end_roam() -> void:
	if not _roaming:
		return
	_roam_id += 1   # 作废等待中的 roam 协程
	_roaming = false
	_roam_depth = 0.0
	if not _reacting:
		_go_idle()


# 没人理它时的自主小动作：开心点头、饿了啃食、难过耷拉、困了慢速呼吸
func _ambient_loop() -> void:
	while true:
		await get_tree().create_timer(randf_range(9.0, 17.0)).timeout
		if _reacting:
			continue
		match _expression:
			"excited", "happy":
				_react("gesture-positive", 1.5, 0.9)
			"hungry":
				_react("eat", 2.0, 0.9)
			"sad", "distress":
				_react("gesture-negative", 1.8, 0.85)
			"neutral":
				if randf() < 0.3:
					_react("gesture-positive", 1.2, 0.9)


# ---------- 每帧：程序化补充动作 + 灯光呼吸 ----------

func _process(delta: float) -> void:
	_t += delta

	var yaw := BASE_YAW + sin(_t * 0.9) * 0.10
	var phase := 0.0
	if _t < _look_until:
		# 左看、右看、再回正
		phase = sin(_t * 3.4)
		yaw = BASE_YAW + phase * 0.55
	_pivot.rotation.z = (phase * 0.10) if _t < _look_until else sin(_t * 0.7) * 0.015

	# 呼吸式起伏；开心时带小跳
	var bob := sin(_t * 2.4) * 0.025
	if not _reacting and not _roaming and _expression in HAPPY_EXPR:
		bob += absf(sin(_t * 3.6)) * 0.05
	var pos := _pivot_home + Vector3.UP * bob
	if _t < _nuzzle_until and _nuzzle_start >= 0.0:
		# 温顺特质的蹭蹭：沿相机轴向主人凑两下
		var nk: float = absf(sin((_t - _nuzzle_start) * 6.0))
		pos += _cam_rig.transform.basis.z * (-0.28) * nk

	# 困了一点点头；开心微微仰起
	var pitch := 0.0
	if not _reacting and not _roaming:
		match _expression:
			"sleepy":
				pitch = 0.16
			"sad", "distress":
				pitch = -0.10
			"excited":
				pitch = 0.05
	if _t < _nuzzle_until and _nuzzle_start >= 0.0:
		pitch = -0.12 * absf(sin((_t - _nuzzle_start) * 6.0))

	if _roaming:
		# 深度曲线：sin 包络淡入淡出，里面在「近 ↔ 远」间往复 1.5 趟
		var p: float = clampf((_t - _roam_start) / ROAM_DURATION, 0.0, 1.0)
		var envelope := sin(p * PI)
		var k := cos(p * TAU * ROAM_TRIPS) * 0.5 + 0.5
		_roam_prev_depth = _roam_depth
		_roam_depth = lerpf(ROAM_NEAR, _roam_far, k) * envelope
		# 沿当前相机轴向移动：无论视角怎么转，都是朝镜头跑近、朝远处跑远
		pos += _cam_rig.transform.basis.z * _roam_depth
		# depth 减小 = 正在跑近 → 正面朝镜头；增大 = 跑远 → 背对镜头
		yaw = _orbit_yaw + (0.0 if _roam_depth < _roam_prev_depth else PI)
		# 正交相机没有透视，用取景大小模拟近大远小：近处放大，远处明显缩小
		var closeness: float = clampf((_roam_far - _roam_depth) / (_roam_far - ROAM_NEAR), 0.0, 1.0)
		_cam.size = _cam_base_size * lerpf(2.45, 0.62, closeness)
	else:
		_cam.size = lerpf(_cam.size, _cam_base_size, minf(delta * 4.0, 1.0))
	_view_scale = _cam_base_size / _cam.size
	if _roaming:
		queue_redraw()   # 地面光环跟随透视缩放

	_pivot.rotation.y = yaw
	_pivot.rotation.x = pitch
	_pivot.position = pos

	_cyan_light.light_energy = 1.5 + sin(_t * 2.0) * 0.25
	_pink_light.light_energy = 1.2 + cos(_t * 1.7) * 0.25

	# 气泡到时淡出
	if _bubble.visible and _bubble_hide_at > 0.0:
		if _t > _bubble_hide_at:
			_bubble.modulate.a = maxf(0.0, _bubble.modulate.a - delta * 1.8)
			if _bubble.modulate.a <= 0.01:
				_bubble.visible = false
				_bubble_hide_at = -1.0


# ---------- 地面光环（随心情变色） ----------

func _draw() -> void:
	# 跑远时光环跟着缩小、略微上移，避免兔子「飘」在固定光环上
	var s: float = _view_scale
	var ground := Vector2(0, 86.0 - (1.0 - s) * 52.0)
	var mood := NEON_CYAN
	if _expression in HAPPY_EXPR:
		mood = NEON_PINK
	elif _expression == "hungry":
		mood = NEON_GREEN
	var dim: float = 0.35 if _expression in SAD_EXPR or _expression == "sleepy" else 0.85
	draw_circle(ground, 62.0 * s, Color(0, 0, 0, 0.32))
	draw_arc(ground, 66.0 * s, 0, TAU, 48, Color(mood, 0.45 * dim), 2.0, true)
	draw_arc(ground, 73.0 * s, 0, TAU, 48, Color(mood, 0.15 * dim), 1.0, true)


# ---------- 工具 ----------

func _on_state_changed() -> void:
	_expression = PetBrain.derive_expression()
	queue_redraw()
	# 空闲时进入/退出瞌睡的慢速 idle
	if not _reacting and _player != null and _player.current_animation == "idle":
		_player.speed_scale = _idle_speed()


func _find_animation_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var found := _find_animation_player(c)
		if found != null:
			return found
	return null


func _merged_aabb(root_node: Node3D) -> AABB:
	var total := AABB()
	var first := true
	for m in _find_meshes(root_node):
		var box: AABB = m.get_aabb()
		box = _relative_transform(root_node, m) * box
		if first:
			total = box
			first = false
		else:
			total = total.merge(box)
	return total


func _find_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_meshes(c))
	return out


func _relative_transform(root_node: Node, m: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = m
	while cur != null and cur != root_node:
		t = cur.transform * t
		cur = cur.get_parent()
	return t
