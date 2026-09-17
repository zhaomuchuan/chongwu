extends Control
## 霓虹天台跑酷：横版超级玛丽式平台跳跃。
## 实时物理（重力/跳跃/土狼时间/跳跃预输入），三关卡：跳裂缝、躲尖刺、踩故障虫、开宝箱、冲到传送门。
## 数值不在这里算：本场景只产出 {coins,kills,items,deaths,level,cleared,fainted,hp_left}，
## 由 PetBrain.settle_platformer() 确定性结算；台词/记忆全用罐头文案，LLM 不参与。

signal finished(summary: Dictionary)

const TILE := 40
const ROWS := 16
const MAX_HP := 3

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_AMBER := Color(1.0, 0.78, 0.25)
const NEON_GREEN := Color(0.224, 1.0, 0.314)
const TEXT_DIM := Color(0.5, 0.62, 0.72)
const DANGER := Color(1.0, 0.28, 0.28)

# 玩家碰撞盒
const PW := 28.0
const PH := 34.0
const EW := 30.0
const EH := 26.0

const GRAVITY := 1900.0
const MAX_FALL := 920.0
const MOVE_SPEED := 245.0
const JUMP_V := 665.0
const COYOTE := 0.10
const JUMP_BUFFER := 0.12

# 宝箱掉落表（复用探索世界的权重；每次开宝箱深拷贝，性格加权不能污染常量）
const LOOT_TABLE := [
	["cap", 10], ["stone", 10], ["feather", 8], ["leaf", 8],
	["dandelion", 7], ["ribbon", 5], ["bell", 4], ["key", 2],
]

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

# 关卡状态
var _stage: int = 0                 # 0..2
var _world_w: int = 0
var _solids: Dictionary = {}        # "x,y" 实心格
var _spikes: Dictionary = {}        # "x,y" 尖刺格
var _coins: Array = []              # {cell:Vector2i, pos:Vector2(像素), taken:bool}
var _enemies: Array = []            # {pos:Vector2 顶左, vel:Vector2, dir:int, alive:bool}
var _chest_cell: Vector2i = Vector2i(-1, -1)
var _chest_opened: bool = false
var _flag_cell: Vector2i = Vector2i.ZERO
var _start_cell: Vector2i = Vector2i(2, 14)

# 玩家
var _pos := Vector2(80, 400)
var _vel := Vector2.ZERO
var _facing: int = 1
var _grounded: bool = false
var _coyote: float = 0.0
var _jump_buffer: float = -1.0
var _hp: int = MAX_HP
var _iframes: float = 0.0
var _checkpoint := Vector2(80, 400)
var _brave_charge: bool = true       # 每关一次「胆大包天」撞翻

# 跑酷累计
var _coin_count: int = 0
var _kills: int = 0
var _deaths: int = 0
var _items: Dictionary = {}

var _done: bool = false
var _t: float = 0.0
var _step_acc: float = 0.0
var _banner_text: String = ""
var _banner_until: float = 0.0
var _cam := Vector2.ZERO
var _home_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	get_viewport().gui_release_focus()   # 防止按键被底层聊天输入框吃掉
	set_process(true)
	_home_btn = Button.new()
	_home_btn.text = "撤离 · 回家"
	_home_btn.focus_mode = Control.FOCUS_NONE
	_home_btn.add_theme_font_size_override("font_size", 15)
	_home_btn.size = Vector2(132, 34)
	_home_btn.position = Vector2(1130, 14)
	_home_btn.pressed.connect(_on_home_pressed)
	add_child(_home_btn)
	_load_stage(0)
	_show_banner("霓虹天台 // STAGE-01")


# ---------- 关卡数据（程序化摆放，保证跳跃可达：裂缝≤3格、台阶≤2格高） ----------

func _load_stage(idx: int) -> void:
	_stage = idx
	_solids.clear()
	_spikes.clear()
	_coins.clear()
	_enemies.clear()
	_chest_opened = false
	_brave_charge = true

	var ground: Array = []
	var plats: Array = []
	var coin_cells: Array = []
	var enemy_cells: Array = []
	var spike_cells: Array = []
	var width: int = 56
	# 设计铁律：相邻落点垂直差 ≤2 格（跳跃极限约 2.95 格），同高裂缝 ≤3 格
	match idx:
		0:
			# 教学关：同高裂缝 + 2 格高奖励台
			width = 56
			ground = [[0, 11], [14, 29], [33, 43], [46, 55]]
			plats = [[16, 13, 19, 13], [24, 13, 26, 13], [34, 13, 38, 13]]
			coin_cells = [Vector2i(12, 12), Vector2i(13, 12), Vector2i(17, 12), Vector2i(18, 12),
				Vector2i(25, 12), Vector2i(30, 12), Vector2i(31, 12), Vector2i(36, 12),
				Vector2i(44, 12), Vector2i(45, 12), Vector2i(50, 13)]
			enemy_cells = [Vector2i(6, 14), Vector2i(26, 14), Vector2i(40, 14), Vector2i(50, 14)]
			spike_cells = []
			_chest_cell = Vector2i(17, 12)
			_flag_cell = Vector2i(52, 14)
		1:
			# 进阶：宽裂缝中放 1 格高垫脚石，地面开始出现尖刺
			width = 64
			ground = [[0, 8], [12, 17], [21, 28], [32, 35], [39, 43], [47, 52], [56, 63]]
			plats = [[10, 14, 11, 14], [19, 14, 20, 14], [29, 14, 31, 14], [37, 14, 38, 14],
				[45, 14, 46, 14], [53, 14, 55, 14],
				[24, 13, 27, 13], [40, 13, 43, 13], [58, 13, 61, 13]]
			coin_cells = [Vector2i(10, 13), Vector2i(19, 13), Vector2i(25, 12), Vector2i(26, 12),
				Vector2i(30, 13), Vector2i(37, 13), Vector2i(41, 12), Vector2i(45, 13),
				Vector2i(54, 13), Vector2i(59, 12), Vector2i(62, 13)]
			enemy_cells = [Vector2i(5, 14), Vector2i(15, 14), Vector2i(26, 14), Vector2i(34, 14), Vector2i(49, 14), Vector2i(59, 14)]
			spike_cells = [Vector2i(23, 14), Vector2i(24, 14), Vector2i(40, 14), Vector2i(50, 14)]
			_chest_cell = Vector2i(25, 12)
			_flag_cell = Vector2i(61, 14)
		_:
			# 高手关：垫脚石 + 2 格高节奏平台 + 连片尖刺
			width = 72
			ground = [[0, 6], [10, 10], [14, 15], [19, 22], [26, 29], [33, 37], [41, 44], [48, 51], [55, 59], [63, 66], [70, 71]]
			plats = [[7, 14, 8, 14], [12, 14, 13, 14], [17, 14, 18, 14], [23, 14, 24, 14],
				[30, 14, 31, 14], [38, 14, 39, 14], [45, 14, 46, 14], [52, 14, 53, 14],
				[60, 14, 61, 14], [67, 14, 68, 14], [34, 13, 36, 13]]
			coin_cells = [Vector2i(7, 13), Vector2i(12, 13), Vector2i(17, 13), Vector2i(23, 13),
				Vector2i(30, 13), Vector2i(35, 12), Vector2i(38, 13), Vector2i(45, 13),
				Vector2i(52, 13), Vector2i(60, 13), Vector2i(67, 13), Vector2i(70, 13)]
			enemy_cells = [Vector2i(4, 14), Vector2i(14, 14), Vector2i(27, 14), Vector2i(33, 14),
				Vector2i(42, 14), Vector2i(50, 14), Vector2i(58, 14), Vector2i(66, 14)]
			spike_cells = [Vector2i(20, 14), Vector2i(21, 14), Vector2i(35, 14), Vector2i(49, 14), Vector2i(57, 14), Vector2i(65, 14)]
			_chest_cell = Vector2i(35, 12)
			_flag_cell = Vector2i(70, 14)

	_world_w = width
	for seg in ground:
		_rect_solid(int(seg[0]), 15, int(seg[1]), 15)
	for pl in plats:
		_rect_solid(int(pl[0]), int(pl[1]), int(pl[2]), int(pl[3]))
	for c in coin_cells:
		_coins.append({"cell": c, "pos": (Vector2(c) + Vector2(0.5, 0.5)) * TILE, "taken": false})
	for c in enemy_cells:
		_enemies.append({"pos": Vector2(c.x * TILE + 5, c.y * TILE + TILE - EH), "vel": Vector2.ZERO,
			"dir": -1, "alive": true})
	for c in spike_cells:
		_spikes[_key(c)] = true
	_start_cell = Vector2i(2, 14)
	_pos = (Vector2(_start_cell) + Vector2(0.5, 1.0)) * TILE - Vector2(PW * 0.5, PH)
	_vel = Vector2.ZERO
	_checkpoint = _pos
	_grounded = false
	_iframes = 1.0
	_cam = _cam_target()


func _rect_solid(x0: int, y0: int, x1: int, y1: int) -> void:
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			_solids[_key(Vector2i(x, y))] = true


func _key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


func _solid_cell(cx: int, cy: int) -> bool:
	return _solids.has("%d,%d" % [cx, cy])


func _solid_at(wx: float, wy: float) -> bool:
	return _solid_cell(int(floor(wx / TILE)), int(floor(wy / TILE)))


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if _done or not (event is InputEventKey) or event.echo:
		return
	var kc: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	match kc:
		KEY_W, KEY_UP, KEY_SPACE:
			if event.pressed:
				_jump_buffer = JUMP_BUFFER
			elif _vel.y < -260.0:
				_vel.y = -260.0   # 松开跳跃键：矮跳


# ---------- 物理 ----------

func _process(delta: float) -> void:
	if _done:
		queue_redraw()
		return
	_t += delta
	if _iframes > 0.0:
		_iframes -= delta
	if _jump_buffer >= 0.0:
		_jump_buffer -= delta
	_step_acc += minf(delta, 0.05)
	var n := 0
	while _step_acc >= 1.0 / 60.0 and n < 4:
		_step(1.0 / 60.0)
		_step_acc -= 1.0 / 60.0
		n += 1
	_cam = _cam.lerp(_cam_target(), clampf(delta * 8.0, 0.0, 1.0))
	queue_redraw()


func _step(dt: float) -> void:
	var lively: float = PetBrain.trait_strength("lively")
	var speed: float = lerpf(MOVE_SPEED, 282.0, lively)
	var jump_v: float = lerpf(JUMP_V, 705.0, lively)

	var dir := 0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir -= 1
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir += 1
	if dir != 0:
		_facing = dir
	_vel.x = move_toward(_vel.x, dir * speed, 2200.0 * dt)

	# 跳跃（预输入 + 土狼时间）
	_coyote -= dt
	if _grounded:
		_coyote = COYOTE
	if _jump_buffer > 0.0 and _coyote > 0.0:
		_vel.y = -jump_v
		_grounded = false
		_coyote = 0.0
		_jump_buffer = -1.0

	_vel.y = minf(_vel.y + GRAVITY * dt, MAX_FALL)

	# X 轴移动+碰撞
	_pos.x += _vel.x * dt
	_resolve_axis(true)
	# Y 轴
	var was_bottom := _pos.y + PH
	_grounded = false
	_pos.y += _vel.y * dt
	_resolve_axis(false)

	if _grounded and _vel.y >= 0.0 and _pos.x > _checkpoint.x + TILE * 2.0 and not _over_spike(_pos):
		_checkpoint = Vector2(_pos.x, _pos.y)

	_step_enemies(dt)
	_pickup_coins(dt)
	_check_interactions(was_bottom)

	# 掉出世界
	if _pos.y > ROWS * TILE + 120.0:
		_lose_hp("脚滑掉进了数据裂缝！")


func _resolve_axis(horizontal: bool) -> void:
	var x0 := int(floor(_pos.x / TILE))
	var x1 := int(floor((_pos.x + PW - 1.0) / TILE))
	var y0 := int(floor((_pos.y + 2.0) / TILE))
	var y1 := int(floor((_pos.y + PH - 1.0) / TILE))
	for cx in range(x0, x1 + 1):
		for cy in range(y0, y1 + 1):
			if not _solid_cell(cx, cy):
				continue
			if horizontal:
				if _vel.x > 0.0:
					_pos.x = cx * TILE - PW
				elif _vel.x < 0.0:
					_pos.x = (cx + 1) * TILE
				_vel.x = 0.0
			else:
				if _vel.y > 0.0:
					_pos.y = cy * TILE - PH
					_grounded = true
				elif _vel.y < 0.0:
					_pos.y = (cy + 1) * TILE
				_vel.y = 0.0


func _over_spike(p: Vector2) -> bool:
	# 脚底中心与任一脚压到尖刺格
	for fx in [p.x + 4.0, p.x + PW - 4.0]:
		var c := Vector2i(int(floor(fx / TILE)), int(floor((p.y + PH) / TILE)))
		if _spikes.has(_key(c)):
			return true
	return false


func _step_enemies(dt: float) -> void:
	var occupied: Dictionary = {}
	for e in _enemies:
		if not bool(e["alive"]):
			continue
		# 巡逻：撞墙或前方无地则掉头
		var ahead_x: float = e["pos"].x + (EW + 4.0) * int(e["dir"])
		if _solid_at(ahead_x, e["pos"].y + EH * 0.5):
			e["dir"] = -int(e["dir"])
		if not _solid_at(ahead_x, e["pos"].y + EH + 4.0):
			e["dir"] = -int(e["dir"])
		e["vel"].x = 70.0 * int(e["dir"])
		e["vel"].y = minf(float(e["vel"].y) + GRAVITY * dt, MAX_FALL)
		e["pos"].x += float(e["vel"].x) * dt
		# 怪自己的 X 撞墙
		var ecx := int(floor((e["pos"].x + (EW if int(e["dir"]) > 0 else 0.0)) / TILE))
		var ecy := int(floor((e["pos"].y + EH * 0.5) / TILE))
		if _solid_cell(ecx, ecy):
			e["pos"].x -= float(e["vel"].x) * dt
			e["dir"] = -int(e["dir"])
		e["pos"].y += float(e["vel"].y) * dt
		var gx0 := int(floor((e["pos"].x + 2.0) / TILE))
		var gx1 := int(floor((e["pos"].x + EW - 2.0) / TILE))
		var gy := int(floor((e["pos"].y + EH + 2.0) / TILE))
		var standing := false
		for gcx in range(gx0, gx1 + 1):
			if _solid_cell(gcx, gy):
				standing = true
		if standing and float(e["vel"].y) >= 0.0:
			e["pos"].y = gy * TILE - EH
			e["vel"].y = 0.0
		occupied[_key(Vector2i(int(floor((e["pos"].x + EW * 0.5) / TILE)), int(floor((e["pos"].y + EH) / TILE))))] = true


func _pickup_coins(dt: float) -> void:
	var pc := (Vector2(_pos) + Vector2(PW, PH) * 0.5)
	var curious: float = PetBrain.trait_strength("curious")
	var magnet: float = lerpf(0.0, 120.0, curious)
	for c in _coins:
		if bool(c["taken"]):
			continue
		var cp: Vector2 = c["pos"]
		if magnet > 0.0 and pc.distance_to(cp) < magnet:
			c["pos"] = cp.lerp(pc, clampf(dt * 9.0, 0.0, 1.0))
		if pc.distance_to(cp) < 22.0:
			c["taken"] = true
			_coin_count += 1


func _check_interactions(prev_bottom: float) -> void:
	var prect := Rect2(_pos, Vector2(PW, PH))
	# 尖刺
	if _over_spike(_pos):
		_lose_hp("扎到了数据尖刺！")
		return
	# 怪物
	for e in _enemies:
		if not bool(e["alive"]):
			continue
		var erect := Rect2(e["pos"], Vector2(EW, EH))
		if not prect.intersects(erect):
			continue
		# 踩头：上一帧脚底在怪头顶附近且正在下落
		if _vel.y > 60.0 and prev_bottom <= float(e["pos"].y) + 14.0:
			e["alive"] = false
			_kills += 1
			_vel.y = -470.0
			_show_banner("嘭！踩飞一只故障虫")
		else:
			# 侧面接触：勇敢特质每关一次撞翻，否则掉血
			if _brave_charge and PetBrain.has_trait("brave"):
				e["alive"] = false
				_kills += 1
				_brave_charge = false
				_vel.x = -_facing * 260.0
				_vel.y = -300.0
				_show_banner("胆大包天！迎面撞翻故障虫")
			else:
				_lose_hp("被故障虫撞了一下！")
				return
	# 宝箱
	if not _chest_opened and _chest_cell.x >= 0:
		var crect := Rect2(Vector2(_chest_cell) * TILE, Vector2(TILE, TILE))
		if prect.intersects(crect.grow(6.0)):
			_open_chest()
	# 传送门：越过终点列即过关（防止从高处跳过门）
	if _pos.x + PW >= _flag_cell.x * TILE + 8.0 and _pos.x <= (_flag_cell.x + 2) * TILE:
		_next_stage()


func _open_chest() -> void:
	_chest_opened = true
	var table: Array = LOOT_TABLE.duplicate(true)
	if PetBrain.has_trait("curious"):
		for row in table:
			var id: String = str(row[0])
			if id == "bell" or id == "ribbon":
				row[1] = int(row[1]) + 4
			elif id == "key":
				row[1] = int(row[1]) + 3
	var total := 0
	for row in table:
		total += int(row[1])
	var roll := randi() % total
	var picked: String = "cap"
	for row in table:
		roll -= int(row[1])
		if roll < 0:
			picked = str(row[0])
			break
	_items[picked] = int(_items.get(picked, 0)) + 1
	var nm: String = PetEventDeck.ITEM_NAMES.get(picked, picked)
	_show_banner("宝箱：%s" % nm)


func _lose_hp(reason: String) -> void:
	if _done or _iframes > 0.0:
		# 无敌帧内仍要把人拉回安全处，避免卡在尖刺/裂缝上反复判定
		if _pos.y > ROWS * TILE + 120.0:
			_respawn()
		return
	_hp -= 1
	_deaths += 1
	_show_banner(reason)
	if _hp <= 0:
		_finish(true)
	else:
		_respawn()


func _respawn() -> void:
	_pos = _checkpoint
	_vel = Vector2.ZERO
	_iframes = 1.3


func _next_stage() -> void:
	if _stage >= 2:
		_finish(false)
		return
	_load_stage(_stage + 1)
	_hp = mini(MAX_HP, _hp + 1)
	_show_banner("STAGE-%02d // 生命+1" % (_stage + 1))


func _finish(fainted: bool) -> void:
	if _done:
		return
	_done = true
	var cleared: bool = (not fainted) and _stage >= 2
	# 主动撤离或晕倒：level=已通过的关数；通关：3
	var passed: int = 3 if cleared else _stage
	finished.emit({
		"coins": _coin_count,
		"kills": _kills,
		"items": _items,
		"deaths": _deaths,
		"level": passed,
		"cleared": cleared,
		"fainted": fainted,
		"hp_left": maxi(_hp, 0),
	})


func _on_home_pressed() -> void:
	_finish(false)


func _show_banner(text: String) -> void:
	_banner_text = text
	_banner_until = _t + 1.8


# ---------- 相机 ----------

func _cam_target() -> Vector2:
	const HUD_H := 56.0
	const HINT_H := 30.0
	var view_w: float = size.x
	var view_h: float = size.y - HUD_H - HINT_H
	var world_h: float = ROWS * TILE
	var pcx: float = _pos.x + PW * 0.5
	var pcy: float = _pos.y + PH * 0.5
	var cx: float = clampf(view_w * 0.5 - pcx - _facing * 60.0, view_w - _world_w * TILE, 0.0)
	var cy: float = HUD_H + clampf(view_h * 0.5 - pcy, view_h - world_h, 0.0)
	return Vector2(cx, cy)


# ---------- 绘制 ----------

func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.016, 0.04), true)
	draw_set_transform(_cam)

	# 远景视差网格
	var gx0 := int(floor(-_cam.x / TILE)) - 1
	var gx1 := int(floor((-_cam.x + size.x) / TILE)) + 1
	for gx in range(gx0, gx1 + 1):
		var x: float = gx * TILE
		draw_line(Vector2(x, 56), Vector2(x, ROWS * TILE), Color(NEON_CYAN, 0.05), 1.0)

	# 实心块
	for sk in _solids.keys():
		var parts: PackedStringArray = sk.split(",")
		var r := Rect2(Vector2(int(parts[0]) * TILE, int(parts[1]) * TILE), Vector2(TILE, TILE))
		draw_rect(r.grow(-1.0), Color(0.06, 0.09, 0.17), true)
		draw_rect(r.grow(-1.0), Color(NEON_CYAN, 0.35), false, 1.0)
		# 顶面高光线
		draw_line(Vector2(r.position.x + 3, r.position.y + 3),
			Vector2(r.position.x + TILE - 3, r.position.y + 3), Color(NEON_CYAN, 0.25), 1.0)

	# 尖刺
	for sk in _spikes.keys():
		var parts: PackedStringArray = sk.split(",")
		var ox: float = int(parts[0]) * TILE
		var oy: float = int(parts[1]) * TILE
		for k in 3:
			var tri := PackedVector2Array([
				Vector2(ox + k * 13.3 + 2, oy + TILE),
				Vector2(ox + k * 13.3 + 8.6, oy + 8),
				Vector2(ox + k * 13.3 + 15.3, oy + TILE),
			])
			draw_colored_polygon(tri, Color(DANGER, 0.55))

	# 金币（旋转的琥珀 ◆）
	for c in _coins:
		if bool(c["taken"]):
			continue
		var cp: Vector2 = c["pos"]
		var sx: float = signf(cos(_t * 4.0 + cp.x * 0.05)) * maxf(absf(cos(_t * 4.0 + cp.x * 0.05)), 0.18)
		var s := 7.0
		var dia := PackedVector2Array([
			cp + Vector2(0, -s), cp + Vector2(s * sx, 0), cp + Vector2(0, s), cp + Vector2(-s * sx, 0),
		])
		draw_colored_polygon(dia, NEON_AMBER)
		draw_polyline(dia + PackedVector2Array([dia[0]]), Color(NEON_AMBER, 0.3), 4.0, true)

	# 宝箱
	if _chest_cell.x >= 0:
		var cr := Rect2(Vector2(_chest_cell) * TILE + Vector2(6, 8), Vector2(TILE - 12, TILE - 12))
		var cc: Color = NEON_GREEN if _chest_opened else NEON_AMBER
		draw_rect(cr, Color(cc, 0.25), true)
		draw_rect(cr, cc, false, 2.0)
		# 好奇特质：未开宝箱呼吸光环 + 上方箭头
		if not _chest_opened and PetBrain.has_trait("curious"):
			var glow := 0.3 + 0.25 * sin(_t * 5.0)
			draw_rect(cr.grow(5.0 + 2.0 * sin(_t * 5.0)), Color(NEON_GREEN, glow), false, 1.5)
			var ax: float = cr.get_center().x
			draw_string(font, Vector2(ax - 6, cr.position.y - 8), "↓", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, NEON_GREEN)
		if _chest_opened:
			draw_string(font, cr.position + Vector2(8, 22), "已开", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TEXT_DIM)

	# 传送门（终点双环 + 旗杆）
	var fc := (Vector2(_flag_cell) + Vector2(0.5, 0.1)) * TILE
	var pulse := 0.5 + 0.5 * sin(_t * 3.0)
	draw_line(Vector2(fc.x, fc.y - TILE), Vector2(fc.x, fc.y + TILE * 1.2), Color(NEON_PINK, 0.7), 2.0, true)
	draw_arc(fc + Vector2(0, TILE * 0.55), 13.0 + pulse * 3.0, _t * 1.5, _t * 1.5 + TAU * 0.85, 28, NEON_PINK, 2.5, true)
	draw_arc(fc + Vector2(0, TILE * 0.55), 8.0, -_t * 2.0, -_t * 2.0 + TAU * 0.75, 24, NEON_CYAN, 2.0, true)
	draw_string(font, fc + Vector2(-28, TILE * 1.25 + 14), "终点", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, NEON_PINK)

	# 故障虫
	for e in _enemies:
		if not bool(e["alive"]):
			continue
		var ep: Vector2 = e["pos"]
		var wob: float = sin(_t * 10.0 + ep.x * 0.05) * 2.0
		draw_rect(Rect2(ep + Vector2(0, wob), Vector2(EW, EH - 4)), Color(NEON_PINK, 0.85), true)
		draw_rect(Rect2(ep + Vector2(0, wob), Vector2(EW, EH - 4)), Color(NEON_PINK, 0.3), false, 2.0)
		# 眼（朝巡逻方向）
		var ex: float = ep.x + (EW - 9 if int(e["dir"]) < 0 else 9)
		draw_circle(Vector2(ex, ep.y + 9 + wob), 3.2, Color.WHITE)
		draw_circle(Vector2(ex + int(e["dir"]) * 1.5, ep.y + 9 + wob), 1.6, Color(0.05, 0, 0.1))

	# 毛球（侧面：圆身+双耳+朝向眼；跑动挤压拉伸、跳跃拉伸）
	var blink: bool = _iframes > 0.0 and int(_t * 12.0) % 2 == 0
	if not blink:
		_draw_player()

	draw_set_transform(Vector2.ZERO)
	_draw_hud(font)


func _draw_player() -> void:
	var c := _pos + Vector2(PW, PH) * 0.5
	var squash := Vector2(1.0, 1.0)
	if not _grounded:
		squash = Vector2(0.92, 1.08)
	elif absf(_vel.x) > 20.0:
		var k: float = sin(_t * 16.0) * 0.05
		squash = Vector2(1.0 + k, 1.0 - k)
	var body_r := 14.0
	# 耳朵
	for sgn in [-1.0, 1.0]:
		var ear := PackedVector2Array([
			c + Vector2(sgn * 3, -body_r + 2) * Vector2(1, squash.y),
			c + Vector2(sgn * 9, -body_r - 12) * Vector2(1, squash.y),
			c + Vector2(sgn * 11, -body_r + 2) * Vector2(1, squash.y),
		])
		# 用中心偏移修正挤压
		ear = PackedVector2Array([
			c + Vector2(sgn * 3 * squash.x, (-body_r + 2) * squash.y),
			c + Vector2(sgn * 9 * squash.x, (-body_r - 12) * squash.y),
			c + Vector2(sgn * 11 * squash.x, (-body_r + 2) * squash.y),
		])
		draw_colored_polygon(ear, Color(1.0, 0.45, 0.62))
	# 身体
	draw_circle(c, body_r * (squash.x + squash.y) * 0.5, Color(1.0, 0.55, 0.68))
	draw_arc(c, body_r * (squash.x + squash.y) * 0.5, 0.0, TAU, 28, NEON_PINK, 2.0, true)
	# 朝向眼
	var eye := c + Vector2(_facing * 6.0, -3.0)
	draw_circle(eye, 3.4, Color.WHITE)
	draw_circle(eye + Vector2(_facing * 1.2, 0), 1.8, Color(0.05, 0, 0.1))
	# 跑动地灯
	if _grounded and absf(_vel.x) > 20.0:
		draw_arc(c + Vector2(0, body_r + 3), 6.0 + 2.0 * sin(_t * 16.0), 0.0, PI, 10, Color(NEON_PINK, 0.35), 1.5, true)


func _draw_hud(font: Font) -> void:
	draw_rect(Rect2(0, 0, size.x, 56), Color(0.035, 0.028, 0.075, 0.92), true)
	draw_rect(Rect2(0, 0, size.x, 56), Color(NEON_CYAN, 0.4), false, 1.0)
	draw_string(font, Vector2(14, 24), "霓虹天台 // STAGE-%02d" % (_stage + 1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17, NEON_PINK)
	var hearts := ""
	for i in MAX_HP:
		hearts += "♥ " if i < _hp else "♡ "
	draw_string(font, Vector2(14, 46), hearts, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
		NEON_GREEN if _hp >= 2 else DANGER)
	draw_string(font, Vector2(120, 24), "◆ 金币 %d" % _coin_count, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, NEON_AMBER)
	draw_string(font, Vector2(250, 24), "踩飞 %d" % _kills, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_DIM)
	if PetBrain.has_trait("brave"):
		draw_string(font, Vector2(120, 46), "勇敢冲撞：%s" % ("可用" if _brave_charge else "已用"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, NEON_GREEN if _brave_charge else TEXT_DIM)

	if _t < _banner_until and _banner_text != "":
		var bw: float = font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var bx := size.x * 0.5 - bw * 0.5 - 16.0
		draw_rect(Rect2(bx, 70, bw + 32, 32), Color(0.035, 0.028, 0.075, 0.9), true)
		draw_rect(Rect2(bx, 70, bw + 32, 32), Color(NEON_PINK, 0.6), false, 1.0)
		draw_string(font, Vector2(bx + 16, 92), _banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

	var hint := "A/D 或 ←/→ 奔跑 · W/↑/空格 跳跃（长按跳更高） · 跳到怪物头上踩扁它 · 小心裂缝和红尖刺"
	draw_rect(Rect2(0, size.y - 30, size.x, 30), Color(0.035, 0.028, 0.075, 0.92), true)
	draw_string(font, Vector2(14, size.y - 10), hint, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28, 12, TEXT_DIM)
