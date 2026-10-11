extends Control
## 探索世界：俯视角赛博数据废墟（程序化生成 + _draw 绘制，无外部资源）。
## 回合制 Roguelike：撞怪攻击、挖宝、下潜；性格特质提供加成；
## 成果由 main 交给 PetBrain.settle_expedition 做确定性结算，本场景不改养成数值。

signal finished(summary: Dictionary)

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

const TILE := 40
const COLS := 30
const ROWS := 20
const MAX_HP := 7
# 大招范围：以毛球为中心的 5×5（切比雪夫半径 2，完全对称）
const ULT_RADIUS := 2
const ULT_FX_DUR := 0.6  # 冲击波动画时长

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_AMBER := Color(1.0, 0.78, 0.25)
const NEON_GREEN := Color(0.224, 1.0, 0.314)
const TEXT_DIM := Color(0.62, 0.72, 0.82)
const DANGER := Color(1.0, 0.30, 0.30)

# 挖宝掉落权重（好奇特质提升稀有档）
const LOOT_TABLE := [["cap", 10], ["stone", 10], ["feather", 8], ["leaf", 8],
	["dandelion", 7], ["ribbon", 5], ["bell", 4], ["key", 2]]

var _depth := 1
var _walls: Dictionary = {}
var _digs: Dictionary = {}
var _monsters: Array = []
var _portal := Vector2i.ZERO
var _player_pos := Vector2i(1, 1)
var _facing := Vector2i(0, 1)
var _hp := MAX_HP
var _items: Dictionary = {}
var _kills := 0
var _digs_count := 0

var _path: Array = []                 # 点击寻路队列（Array[Vector2i]）
var _pending_dig := false
var _pending_attack := Vector2i.ZERO
var _has_pending_attack := false
var _step_acc := 0.0

var _banner_text := ""
var _banner_until := 0.0
var _done := false
var _t := 0.0
var _shake := 0.0

var _ult_ready := true    # 大招：每层可用一次，_descend() 时刷新
var _ult_fx := -1.0       # 冲击波动画计时（秒），<0 表示不在播放
var _ult_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	get_viewport().gui_release_focus()   # 防止按键被底层聊天输入框吃掉
	_gen_level()
	_banner("第 %d 层 // GRID-%02d" % [_depth, _depth], 2.4)
	var btn := Button.new()
	btn.text = "撤离 · 回家"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 15)
	btn.size = Vector2(132, 34)
	btn.position = Vector2(1130, 14)
	btn.pressed.connect(_on_home_pressed)
	add_child(btn)
	# 大招按钮（键盘 E 同效，鼠标玩家也能点）
	_ult_btn = Button.new()
	_ult_btn.focus_mode = Control.FOCUS_NONE
	_ult_btn.add_theme_font_size_override("font_size", 15)
	_ult_btn.size = Vector2(160, 34)
	_ult_btn.position = Vector2(962, 14)
	_ult_btn.pressed.connect(_use_ult)
	add_child(_ult_btn)
	_refresh_ult_ui()
	set_process(true)


# ---------- 关卡生成 ----------

func _key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]


func _gen_level() -> void:
	_walls.clear()
	_digs.clear()
	_monsters.clear()
	# 反复生成直到主连通区足够大（防止墙簇把出生点角落封死）
	var dist: Dictionary = {}
	for attempt in 24:
		_walls.clear()
		# 边界墙 + 内部数据块簇
		for x in COLS:
			for y in ROWS:
				if x == 0 or y == 0 or x == COLS - 1 or y == ROWS - 1:
					_walls[_key(Vector2i(x, y))] = true
		for c in 46:
			var cx: int = 2 + (randi() % (COLS - 4))
			var cy: int = 2 + (randi() % (ROWS - 4))
			var size: int = 1 + randi() % 3
			for i in size:
				var p := Vector2i(cx + randi() % 3 - 1, cy + randi() % 3 - 1)
				if p.x > 0 and p.x < COLS - 1 and p.y > 0 and p.y < ROWS - 1:
					_walls[_key(p)] = true
		# 出生点附近清出 4×4 安全区
		for dx in 4:
			for dy in 4:
				_walls.erase(_key(Vector2i(1 + dx, 1 + dy)))
		dist = _bfs_from(Vector2i(1, 1))
		var ge8 := 0
		for p in dist.keys():
			if int(dist[p]) >= 8:
				ge8 += 1
		if dist.size() >= 300 and ge8 >= 30:
			break
	var spots: Array = []
	for p in dist.keys():
		if int(dist[p]) >= 4:
			spots.append(p)
	spots.shuffle()

	# 传送门：离出生点最远的可达格之一
	var far: Array = []
	for p in dist.keys():
		if int(dist[p]) >= 8:
			far.append(p)
	if far.is_empty():
		far = spots.duplicate()
	_portal = far[randi() % far.size()]
	spots.erase(_portal)

	# 矿藏
	var used: Dictionary = {_key(_portal): true, _key(Vector2i(1, 1)): true}
	for i in mini(9, spots.size()):
		_digs[_key(spots[i])] = true
		used[_key(spots[i])] = true
	# 怪物：随层数增多、精英概率提高
	var n: int = mini(4 + _depth * 2, 12)
	for p in spots:
		if n <= 0:
			break
		if int(dist.get(p, 0)) < 6 or used.has(_key(p)):
			continue
		used[_key(p)] = true
		var elite: bool = randf() < clampf(0.12 + _depth * 0.08, 0.0, 0.6)
		var hp: int = 3 if elite else 2
		# 两种皮肤（数据史莱姆 / 病毒孢体）：仅外观与名字不同，数值与 AI 完全共用
		var kind := "virus" if randf() < 0.5 else "slime"
		_monsters.append({"pos": p, "hp": hp, "max_hp": hp, "elite": elite, "kind": kind})
		n -= 1
	_player_pos = Vector2i(1, 1)
	_facing = Vector2i(0, 1)
	_path.clear()


# ---------- BFS 寻路 ----------

func _walkable(p: Vector2i) -> bool:
	return not _walls.has(_key(p))


func _bfs_from(start: Vector2i) -> Dictionary:
	var dist := {start: 0}
	var q: Array = [start]
	var head := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		for d in dirs:
			var np: Vector2i = cur + d
			if not _walkable(np) or dist.has(np):
				continue
			dist[np] = int(dist[cur]) + 1
			q.append(np)
	return dist


# 返回从 start 到 goal 的路径（不含 start）；不可达返回空
func _bfs_path(start: Vector2i, goal: Vector2i) -> Array:
	if start == goal:
		return []
	var prev: Dictionary = {_key(start): _key(start)}
	var q: Array = [start]
	var head := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var found := false
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		if cur == goal:
			found = true
			break
		for d in dirs:
			var np: Vector2i = cur + d
			var nk := _key(np)
			if not _walkable(np) or prev.has(nk):
				continue
			prev[nk] = _key(cur)
			q.append(np)
	if not found:
		return []
	var out: Array = []
	var cur_k := _key(goal)
	while cur_k != _key(start):
		var parts := cur_k.split(",")
		var cp := Vector2i(int(parts[0]), int(parts[1]))
		out.push_front(cp)
		cur_k = str(prev[cur_k])
	return out


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if _done or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var d := Vector2i.ZERO
	var kc: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	match kc:
		KEY_W, KEY_UP:
			d = Vector2i(0, -1)
		KEY_S, KEY_DOWN:
			d = Vector2i(0, 1)
		KEY_A, KEY_LEFT:
			d = Vector2i(-1, 0)
		KEY_D, KEY_RIGHT:
			d = Vector2i(1, 0)
		KEY_SPACE:
			_dig_facing()
			return
		KEY_E:
			_use_ult()
			return
	if d != Vector2i.ZERO:
		_path.clear()
		_has_pending_attack = false
		_try_move(d)


func _gui_input(event: InputEvent) -> void:
	if _done or not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var target := _screen_to_tile(event.position)
	if target.x < 0 or target.x >= COLS or target.y < 0 or target.y >= ROWS:
		return
	# 点怪物 → 走到相邻格后攻击；已经贴脸则立刻打
	var mp = _monster_at(target)
	if mp != null:
		_has_pending_attack = true
		_pending_attack = target
		_pending_dig = false
		if _manhattan(_player_pos, target) == 1:
			_path.clear()
			_attack(mp)
			_after_player_turn()
			_has_pending_attack = false
		else:
			_click_adjacent(target)
		return
	if not _walkable(target):
		return
	if _digs.has(_key(target)):
		_pending_dig = true
		_has_pending_attack = false
	else:
		_pending_dig = false
		_has_pending_attack = false
	_path = _bfs_path(_player_pos, target)


# 走到目标格的某个相邻可行格（用于贴脸打怪）
func _click_adjacent(target: Vector2i) -> void:
	var best: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var a: Vector2i = target + d
		if _walkable(a) and _monster_at(a) == null:
			var p := _bfs_path(_player_pos, a)
			if (a == _player_pos or not p.is_empty()) and (best.is_empty() or p.size() < best.size()):
				best = p
	_path = best


func _screen_to_tile(screen_pos: Vector2) -> Vector2i:
	var cam := _cam_offset()
	return Vector2i(floori((screen_pos.x - cam.x) / TILE), floori((screen_pos.y - cam.y) / TILE))


# ---------- 回合 ----------

func _try_move(d: Vector2i) -> void:
	_facing = d
	var np := _player_pos + d
	var mp = _monster_at(np)
	if mp != null:
		_attack(mp)
		_after_player_turn()
		return
	if not _walkable(np):
		return
	_player_pos = np
	PetBrain.last_interaction_msec = Time.get_ticks_msec()
	if np == _portal:
		_descend()
		return
	_after_player_turn()


func _dig_facing() -> void:
	PetBrain.last_interaction_msec = Time.get_ticks_msec()
	for p in [_player_pos + _facing, _player_pos]:
		if _digs.has(_key(p)):
			_dig(p)
			_after_player_turn()
			return


func _dig(p: Vector2i) -> void:
	_digs.erase(_key(p))
	_digs_count += 1
	# 能量核心：低概率回 1 生命
	if _hp < MAX_HP and randf() < 0.08:
		_hp += 1
		_banner("挖到能量核心！生命 +1", 1.6)
		return
	_grant_loot()
	# 好奇特质：15% 概率双黄
	if PetBrain.has_trait("curious") and randf() < 0.15:
		_grant_loot()


func _grant_loot() -> void:
	# 必须深拷贝：内层权重数组会被好奇特质改写，浅拷贝会污染常量
	var table: Array = LOOT_TABLE.duplicate(true)
	if PetBrain.has_trait("curious"):
		# 提升稀有档权重
		for row in table:
			if row[0] == "key":
				row[1] = 6
			elif row[0] == "bell":
				row[1] = 7
			elif row[0] == "ribbon":
				row[1] = 8
	var total := 0
	for row in table:
		total += int(row[1])
	var roll := randf() * total
	var acc := 0
	var item_id := "cap"
	for row in table:
		acc += int(row[1])
		if roll <= acc:
			item_id = str(row[0])
			break
	_items[item_id] = int(_items.get(item_id, 0)) + 1
	_banner("挖到【%s】！" % PetEventDeck.ITEM_NAMES.get(item_id, item_id), 1.4)


# 大招「数据湮灭」：清掉毛球周围 5×5 范围内的所有怪物，每层一次。
# 不触发战利品（大招是清场手段，不算打死的）；击杀照常计入 kills 参与结算。
func _use_ult() -> void:
	if _done:
		return
	if not _ult_ready:
		_banner("大招这一层已经用掉了", 1.2)
		return
	var hit: Array = []
	for m in _monsters:
		if _in_ult_area(m["pos"]):
			hit.append(m)
	# 范围内没怪就不消耗，留给真正被围住的时候
	if hit.is_empty():
		_banner("附近没有怪物，大招先留着", 1.2)
		return
	for m in hit:
		_monsters.erase(m)
	_kills += hit.size()
	_ult_ready = false
	_ult_fx = 0.0
	_shake = 0.28
	PetBrain.last_interaction_msec = Time.get_ticks_msec()
	_banner("数据湮灭！清理 %d 只怪物" % hit.size(), 1.6)
	_refresh_ult_ui()


# 大招范围：以毛球为中心、半径 2 的方形区（5×5，上下左右完全对称）
func _in_ult_area(p: Vector2i) -> bool:
	var d: Vector2i = p - _player_pos
	return absi(d.x) <= ULT_RADIUS and absi(d.y) <= ULT_RADIUS


func _refresh_ult_ui() -> void:
	if _ult_btn == null:
		return
	_ult_btn.text = "大招 · 湮灭（E）" if _ult_ready else "大招 · 本层已用"
	_ult_btn.disabled = not _ult_ready


func _attack(mp: Dictionary) -> void:
	PetBrain.last_interaction_msec = Time.get_ticks_msec()
	var dmg: int = 2 if PetBrain.has_trait("brave") else 1
	mp["hp"] = int(mp["hp"]) - dmg
	_shake = 0.18
	if int(mp["hp"]) <= 0:
		var elite: bool = mp["elite"]
		_monsters.erase(mp)
		_kills += 1
		_banner("击败%s！" % ("故障兽" if elite else ("病毒孢体" if str(mp.get("kind", "slime")) == "virus" else "数据史莱姆")), 1.2)
		# 35% 战斗掉落（精英必掉）
		if elite or randf() < 0.35:
			_grant_loot()
	else:
		_banner("造成 %d 伤害" % dmg, 0.8)


func _after_player_turn() -> void:
	var dist: Dictionary = _bfs_from(_player_pos)
	var occupied: Dictionary = {}
	for m in _monsters:
		occupied[_key(m["pos"])] = true
	for m in _monsters.duplicate():
		if _done:
			return
		var mp: Vector2i = m["pos"]
		var d: int = int(dist.get(mp, 999))
		var aggro: int = 7 if m["elite"] else 5
		if d > aggro:
			continue
		if d <= 1:
			_hit_player()
			continue
		# 走向距玩家更近、且没被同伴占住的格子
		var best := mp
		var best_d := d
		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var np: Vector2i = mp + step
			if not _walkable(np) or occupied.has(_key(np)):
				continue
			var nd: int = int(dist.get(np, 999))
			if nd < best_d:
				best_d = nd
				best = np
		if best != mp:
			occupied.erase(_key(mp))
			occupied[_key(best)] = true
			m["pos"] = best
			if best_d <= 1:
				_hit_player()


func _hit_player() -> void:
	_hp -= 1
	_shake = 0.28
	if _hp <= 0:
		_banner("毛球被打疼了，快跑！", 1.6)
		_finish(true)
	else:
		_banner("受击！剩余生命 %d" % _hp, 1.0)


func _descend() -> void:
	_depth += 1
	if _hp < MAX_HP:
		_hp += 1
	_path.clear()
	_ult_ready = true     # 大招每层刷新
	_refresh_ult_ui()
	_gen_level()
	_banner("深入第 %d 层 · 生命恢复 1" % _depth, 2.0)


func _on_home_pressed() -> void:
	_finish(false)


func _finish(fainted: bool) -> void:
	if _done:
		return
	_done = true
	finished.emit({
		"depth": _depth,
		"kills": _kills,
		"digs": _digs_count,
		"items": _items.duplicate(true),
		"fainted": fainted,
		"hp_left": _hp,
	})


func _banner(text: String, dur: float) -> void:
	_banner_text = text
	_banner_until = _t + dur


# ---------- 点击自动行走 ----------

func _process(delta: float) -> void:
	_t += delta
	_shake = maxf(0.0, _shake - delta)
	if _ult_fx >= 0.0:
		_ult_fx += delta
		if _ult_fx > ULT_FX_DUR:
			_ult_fx = -1.0
	if not _path.is_empty() and not _done:
		# 活泼特质：自动行走更快
		var interval: float = lerpf(0.14, 0.085, PetBrain.trait_strength("lively"))
		_step_acc -= delta
		if _step_acc <= 0.0:
			_step_acc = interval
			var np: Vector2i = _path.pop_front()
			var mp = _monster_at(np)
			if mp != null:
				_attack(mp)
				_path.clear()
				_after_player_turn()
			elif _walkable(np):
				_facing = np - _player_pos
				_player_pos = np
				PetBrain.last_interaction_msec = Time.get_ticks_msec()
				if np == _portal:
					_descend()
				else:
					_after_player_turn()
		if _path.is_empty() and not _done:
			if _pending_dig and _digs.has(_key(_player_pos)):
				_dig(_player_pos)
				_after_player_turn()
			_pending_dig = false
			if _has_pending_attack:
				var mp = _monster_at(_pending_attack)
				if mp != null and _manhattan(mp["pos"], _player_pos) == 1:
					_attack(mp)
					_after_player_turn()
				_has_pending_attack = false
	queue_redraw()


func _monster_at(p: Vector2i):
	for m in _monsters:
		if m["pos"] == p:
			return m
	return null


func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


# ---------- 绘制 ----------

func _cam_offset() -> Vector2:
	# 世界只在 HUD(56) 与底部提示条(30) 之间的区域内居中/跟随，避免出生点被 HUD 遮住
	const HUD_H := 56.0
	const HINT_H := 30.0
	var view_pos := Vector2(0.0, HUD_H)
	var view_size := Vector2(size.x, size.y - HUD_H - HINT_H)
	var world := Vector2(COLS * TILE, ROWS * TILE)
	var cam := view_pos + view_size * 0.5 - (Vector2(_player_pos) + Vector2(0.5, 0.5)) * TILE
	# 世界比可视区小时居中，否则跟随并钳制在世界边缘内
	if world.x < view_size.x:
		cam.x = view_pos.x + (view_size.x - world.x) * 0.5
	else:
		cam.x = clampf(cam.x, view_pos.x + view_size.x - world.x, view_pos.x)
	if world.y < view_size.y:
		cam.y = view_pos.y + (view_size.y - world.y) * 0.5
	else:
		cam.y = clampf(cam.y, view_pos.y + view_size.y - world.y, view_pos.y)
	if _shake > 0.0:
		cam += Vector2(randf_range(-3, 3), randf_range(-3, 3)) * (_shake / 0.28)
	return cam


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var cam := _cam_offset()

	# 世界外的露边区域铺满深色
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.016, 0.04), true)

	# ---- 世界 ----
	draw_set_transform(cam)
	var world_size := Vector2(COLS * TILE, ROWS * TILE)
	draw_rect(Rect2(Vector2.ZERO, world_size), Color(0.03, 0.025, 0.06), true)

	# 网格
	for x in range(COLS + 1):
		draw_line(Vector2(x * TILE, 0), Vector2(x * TILE, ROWS * TILE), Color(NEON_CYAN, 0.06), 1.0)
	for y in range(ROWS + 1):
		draw_line(Vector2(0, y * TILE), Vector2(COLS * TILE, y * TILE), Color(NEON_CYAN, 0.06), 1.0)

	# 障碍：数据块
	for wk in _walls.keys():
		var parts: PackedStringArray = wk.split(",")
		var r := Rect2(Vector2(int(parts[0]) * TILE, int(parts[1]) * TILE), Vector2(TILE, TILE))
		draw_rect(r.grow(-2.0), Color(0.06, 0.09, 0.17), true)
		draw_rect(r.grow(-2.0), Color(NEON_CYAN, 0.35), false, 1.0)
		draw_line(Vector2(r.position.x + 10, r.position.y + TILE * 0.5),
			Vector2(r.position.x + TILE - 10, r.position.y + TILE * 0.5), Color(NEON_CYAN, 0.18), 1.0)

	# 传送门（旋转双环）
	var pc := (Vector2(_portal) + Vector2(0.5, 0.5)) * TILE
	var pulse := 0.5 + 0.5 * sin(_t * 3.0)
	draw_arc(pc, 13.0 + pulse * 3.0, _t * 1.5, _t * 1.5 + TAU * 0.85, 28, Color(NEON_CYAN, 0.9), 2.5, true)
	draw_arc(pc, 8.0, -_t * 2.0, -_t * 2.0 + TAU * 0.75, 24, Color(NEON_PINK, 0.8), 2.0, true)
	draw_string(font, pc + Vector2(-24, 30), "下一层 ↓", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, NEON_CYAN)

	# 矿藏：脉动琥珀 ◆
	for dk in _digs.keys():
		var parts: PackedStringArray = dk.split(",")
		var c := (Vector2(int(parts[0]) + 0.5, int(parts[1]) + 0.5)) * TILE
		var s := 6.0 + 2.0 * pulse
		var diamond := PackedVector2Array([
			c + Vector2(0, -s), c + Vector2(s, 0), c + Vector2(0, s), c + Vector2(-s, 0)
		])
		draw_colored_polygon(diamond, Color(NEON_AMBER, 0.25 + 0.2 * pulse))
		var outline := PackedVector2Array([diamond[0], diamond[1], diamond[2], diamond[3], diamond[0]])
		draw_polyline(outline, NEON_AMBER, 1.5, true)
		draw_circle(c, 11.0 + 3.0 * pulse, Color(NEON_AMBER, 0.08))

	# 怪物
	for m in _monsters:
		_draw_monster(m, pulse)

	# 战争迷雾：视野外压暗（好奇特质视野更大）
	var vision: float = 5.0 + (1.5 if PetBrain.has_trait("curious") else 0.0)
	for x in COLS:
		for y in ROWS:
			var center := Vector2(x + 0.5, y + 0.5)
			if center.distance_to(Vector2(_player_pos) + Vector2(0.5, 0.5)) > vision:
				draw_rect(Rect2(Vector2(x, y) * TILE, Vector2(TILE, TILE)), Color(0.01, 0.01, 0.03, 0.86), true)

	# 毛球（永远画在迷雾之上）
	_draw_player()
	_draw_ult_fx()

	draw_set_transform(Vector2.ZERO)

	# ---- HUD ----
	_draw_hud(font)


func _draw_monster(m: Dictionary, pulse: float) -> void:
	var c := (Vector2(m["pos"]) + Vector2(0.5, 0.55)) * TILE
	var kind := str(m.get("kind", "slime"))
	var elite: bool = m["elite"]
	# 每种皮肤各有「普通 / 精英」配色，精英更暗更烫
	var col: Color
	if kind == "virus":
		col = Color(0.10, 0.95, 0.95) if elite else Color(0.25, 0.95, 0.45)
	else:
		col = Color(0.85, 0.12, 0.55) if elite else Color(0.75, 0.18, 0.7)
	var r := 12.0
	# 脉动光晕（两种皮肤共用）
	draw_circle(c, r + pulse, Color(col, 0.35))
	if kind == "virus":
		_draw_monster_virus(c, pulse, col)
	else:
		_draw_monster_slime(c, pulse, col)
	if elite:
		draw_string(ThemeDB.fallback_font, c + Vector2(-6, -18), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DANGER)
	# HP 小条（两种皮肤共用）
	for i in int(m["max_hp"]):
		var filled: bool = i < int(m["hp"])
		var pip_col: Color = DANGER if filled else Color(0.3, 0.25, 0.25, 0.5)
		draw_rect(Rect2(c + Vector2(-9 + i * 7, -22), Vector2(5, 3)), pip_col, true)


# 皮肤一：数据史莱姆——半圆团 + 双眼
func _draw_monster_slime(c: Vector2, _pulse: float, col: Color) -> void:
	var r := 12.0
	draw_circle(c, r, col)
	draw_arc(c, r, PI, TAU, 16, Color(1, 1, 1, 0.35), 1.5, true)
	draw_circle(c + Vector2(-4, -2), 2.2, Color.WHITE)
	draw_circle(c + Vector2(4, -2), 2.2, Color.WHITE)
	draw_circle(c + Vector2(-4, -2), 1.0, Color.BLACK)
	draw_circle(c + Vector2(4, -2), 1.0, Color.BLACK)


# 皮肤二：病毒孢体——放射尖刺 + 亮核 + 单只竖瞳
func _draw_monster_virus(c: Vector2, pulse: float, col: Color) -> void:
	var r := 10.5
	# 尖刺（随时间缓慢旋转，像在游动）
	var spin: float = _t * 0.6
	for i in 8:
		var a: float = spin + TAU * float(i) / 8.0
		var dir := Vector2(cos(a), sin(a))
		var tip := c + dir * (r + 5.0 + pulse * 2.0)
		var side := Vector2(-dir.y, dir.x) * 2.6
		draw_colored_polygon(PackedVector2Array([
			c + dir * (r - 2.0) + side, tip, c + dir * (r - 2.0) - side]), col)
	# 球身（外圈亮、内芯浅，做出孢子质感）
	draw_circle(c, r, col)
	draw_circle(c, r, Color(1, 1, 1, 0.22))
	draw_arc(c, r, 0, TAU, 20, Color(1, 1, 1, 0.3), 1.2, true)
	draw_circle(c, 4.0 + pulse * 1.2, Color(0.92, 1.0, 1.0, 0.8))
	# 单只竖瞳眼（竖长菱形，和史莱姆的圆双眼明显不同）
	var eye := c + Vector2(0.0, -3.0)
	draw_circle(eye, 3.0, Color.WHITE)
	draw_colored_polygon(PackedVector2Array([
		eye + Vector2(0, -2.6), eye + Vector2(1.2, 0),
		eye + Vector2(0, 2.6), eye + Vector2(-1.2, 0)]), Color(0.05, 0.05, 0.1))


# 5×5 作用范围的四个角（世界像素坐标）
func _ult_area_quad() -> PackedVector2Array:
	var side_px: float = float(ULT_RADIUS * 2 + 1) * TILE
	var origin := Vector2(_player_pos - Vector2i(ULT_RADIUS, ULT_RADIUS)) * TILE
	return PackedVector2Array([
		origin,
		origin + Vector2(side_px, 0.0),
		origin + Vector2(side_px, side_px),
		origin + Vector2(0.0, side_px),
	])


# 大招冲击波：从毛球向外扩散的双层霓虹环 + 放射状故障短线
func _draw_ult_fx() -> void:
	if _ult_fx < 0.0:
		return
	var k: float = clampf(_ult_fx / ULT_FX_DUR, 0.0, 1.0)
	var fade: float = 1.0 - k
	var c := (Vector2(_player_pos) + Vector2(0.5, 0.5)) * TILE
	# 实际作用范围：随面朝方向旋转的 4×4 方框（让玩家看清打到了哪）
	var quad: PackedVector2Array = _ult_area_quad()
	if quad.size() == 4:
		draw_colored_polygon(quad, Color(NEON_AMBER, 0.14 * fade))
		draw_polyline(quad + PackedVector2Array([quad[0]]), Color(NEON_AMBER, 0.85 * fade), 2.0, true)
	# 双层扩散环（外圈琥珀、内圈青）
	var r_out: float = lerpf(6.0, TILE * 2.4, k)
	draw_arc(c, r_out, 0.0, TAU, 40, Color(NEON_AMBER, 0.85 * fade), 3.0, true)
	draw_arc(c, r_out * 0.68, 0.0, TAU, 34, Color(NEON_CYAN, 0.7 * fade), 2.0, true)
	# 放射故障短线：沿 8 个方向甩出
	for i in 8:
		var a: float = TAU * float(i) / 8.0
		var dir := Vector2(cos(a), sin(a))
		draw_line(c + dir * r_out * 0.75, c + dir * (r_out + 10.0), Color(NEON_AMBER, 0.5 * fade), 2.0, true)
	# 中心一闪
	if k < 0.35:
		draw_circle(c, 26.0 * (1.0 - k / 0.35), Color(1.0, 1.0, 1.0, 0.35 * (1.0 - k / 0.35)))


func _draw_player() -> void:
	var c := (Vector2(_player_pos) + Vector2(0.5, 0.55)) * TILE
	# 耳朵（俯视角露出两只长耳）
	var ear_col := Color(1.0, 0.55, 0.62)
	draw_circle(c + Vector2(-6, -13), 4.5, ear_col)
	draw_circle(c + Vector2(6, -13), 4.5, ear_col)
	# 身体
	draw_circle(c, 13.0, Color(NEON_PINK, 0.25))
	draw_circle(c, 11.5, Color(0.95, 0.62, 0.55))
	draw_arc(c, 11.5, 0, TAU, 24, NEON_PINK, 2.0, true)
	# 眼睛随朝向偏移
	var ec := c + Vector2(_facing) * 3.0
	draw_circle(ec + Vector2(-4, -1), 2.6, Color.WHITE)
	draw_circle(ec + Vector2(4, -1), 2.6, Color.WHITE)
	draw_circle(ec + Vector2(-4 + _facing.x, -1 + _facing.y), 1.3, Color(0.08, 0.08, 0.14))
	draw_circle(ec + Vector2(4 + _facing.x, -1 + _facing.y), 1.3, Color(0.08, 0.08, 0.14))


func _draw_hud(font: Font) -> void:
	# 顶部条
	draw_rect(Rect2(0, 0, size.x, 56), Color(0.035, 0.028, 0.075, 0.92), true)
	draw_rect(Rect2(0, 0, size.x, 56), Color(NEON_CYAN, 0.4), false, 1.0)
	draw_string(font, Vector2(14, 24), "数据废墟 // GRID-%02d（第 %d 层）" % [_depth, _depth],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17, NEON_PINK)
	# 生命（心数随 MAX_HP；颜色按血量是否过半）
	var hearts := ""
	for i in MAX_HP:
		hearts += "♥ " if i < _hp else "♡ "
	draw_string(font, Vector2(14, 46), hearts, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
		NEON_GREEN if _hp * 2 > MAX_HP else DANGER)
	# 本次战利品（紧跟在心的后面，避免血量格数变多时挤在一起）
	var hearts_w: float = font.get_string_size(hearts, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var loot_parts: Array = []
	for id in PetEventDeck.ITEM_NAMES.keys():
		if _items.has(id):
			loot_parts.append("%s×%d" % [PetEventDeck.ITEM_NAMES[id], int(_items[id])])
	var loot := "战利品：%s" % ("、".join(loot_parts) if not loot_parts.is_empty() else "（还没有收获）")
	draw_string(font, Vector2(14.0 + hearts_w + 12.0, 46), loot, HORIZONTAL_ALIGNMENT_LEFT, 620, 13, NEON_AMBER)
	# 击杀统计（放在标题右侧，标题约 340px 宽）
	draw_string(font, Vector2(470, 24), "击败 %d   挖宝 %d" % [_kills, _digs_count],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)
	# 大招状态
	if _ult_ready:
		draw_string(font, Vector2(640, 24), "大招 ◆ 可用（E）", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, NEON_AMBER)
	else:
		draw_string(font, Vector2(640, 24), "大招 ◇ 本层已用", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.4, 0.45, 0.52))

	# 居中飘字
	if _t < _banner_until and _banner_text != "":
		var w: float = font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		var bx := size.x * 0.5 - w * 0.5 - 16.0
		draw_rect(Rect2(bx, 70, w + 32, 32), Color(0.035, 0.028, 0.075, 0.9), true)
		draw_rect(Rect2(bx, 70, w + 32, 32), Color(NEON_PINK, 0.6), false, 1.0)
		draw_string(font, Vector2(bx + 16, 92), _banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

	# 底部操作提示
	var hint := "WASD/方向键 移动（撞向怪物=攻击） · 空格 挖面前的矿藏 · E 大招（周围 5×5 清场，每层一次） · 鼠标点击自动寻路 · 走到传送门下潜更深层"
	draw_rect(Rect2(0, size.y - 30, size.x, 30), Color(0.035, 0.028, 0.075, 0.92), true)
	draw_string(font, Vector2(14, size.y - 10), hint, HORIZONTAL_ALIGNMENT_LEFT, size.x - 28, 12, TEXT_DIM)
