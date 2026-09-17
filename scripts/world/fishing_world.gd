extends Control
## 数据海 · 垂钓：慢节奏收菜玩法。抛竿 → 抓咬钩时机 → 张力条收线 → 鱼获。
## 场景只产出结果 Dictionary，数值结算在 PetBrain.settle_fishing；全罐头文案，LLM 不参与。

signal finished(summary: Dictionary)

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_AMBER := Color(1.0, 0.78, 0.25)
const NEON_GREEN := Color(0.224, 1.0, 0.314)
const DANGER := Color(1.0, 0.28, 0.28)
const TEXT_DIM := Color(0.55, 0.66, 0.78)
const FUR := Color(1.0, 0.55, 0.68)
const FUR_EAR := Color(1.0, 0.45, 0.62)

# 耐心 / 时机
const MAX_PATIENCE := 3
const PERFECT_WINDOW := 0.28
const GOOD_WINDOW := 0.55
const WAIT_MIN := 2.5
const WAIT_MAX := 6.0
const BONUS_WAIT_MIN := 0.8
const BONUS_WAIT_MAX := 1.5

# 收线
const REEL_RATE := 42.0          # 按住收线进度 /s（活泼 +15%）
const TENSION_UP_CALM := 34.0    # 平静时按住的张力 /s
const TENSION_UP_FIGHT := 95.0   # 挣扎时按住的张力 /s（温顺 -20%）
const TENSION_DOWN_CALM := 40.0
const TENSION_DOWN_FIGHT := 55.0
const PROGRESS_FIGHT := 12.0     # 挣扎时仍能缓慢收线
const CALM_MIN := 0.8
const CALM_MAX := 1.4
const FIGHT_MIN := 0.6
const FIGHT_MAX := 1.0

# 鱼获大类权重（普通竿 / 鱼汛竿）
const CATCH_W := {"item": 55, "fish": 38, "junk": 7}
const CATCH_W_BONUS := {"item": 37, "fish": 60, "junk": 3}
# 鱼档权重 [常见, 少见, 稀有]：刺鱼品质 × 是否好奇
const FISH_W_GOOD := [68, 26, 6]
const FISH_W_PERFECT := [45, 40, 15]

# 道具掉落（与探索/闯关同表）
const LOOT_TABLE := [
	["cap", 10], ["stone", 10], ["feather", 8], ["leaf", 8],
	["dandelion", 7], ["ribbon", 5], ["bell", 4], ["key", 2],
]
const JUNK := [
	["can", "乱码易拉罐"],
	["capacitor", "旧电容"],
]
const RARITY_COLOR := {1: NEON_CYAN, 2: NEON_AMBER, 3: NEON_PINK}

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

# 状态机
var _phase := "idle"        # idle / waiting / bite / reel / result
var _done := false
var _t := 0.0
var _patience := MAX_PATIENCE
var _holding := false       # 收线键按住

# 抛竿/咬钩
var _wait_t := 0.0
var _wait_dur := 4.0
var _bite_t := 0.0
var _bite_quality := ""    # perfect / good / miss
var _this_bonus := false    # 当前这一竿是否鱼汛竿
var _fish_shadow := 0.0    # 鱼影靠近动画 0→1

# 收线
var _reel_progress := 0.0
var _tension := 0.0
var _struggle := false
var _phase_t := 0.0
var _phase_dur := 1.0

# 累计
var _catches := 0
var _misses := 0
var _perfects := 0
var _garbage := 0
var _rare_count := 0
var _items: Dictionary = {}
var _fish: Array = []           # 本次鱼获 id
var _new_dex: Array = []        # 本次新收录 id
var _result_card: Dictionary = {}
var _result_t := 0.0
var _banner_text := ""
var _banner_until := 0.0

# 场景几何（按 size 现算，适应缩放后的视区）
var _sea_y := 380.0
var _bob_pos := Vector2(520, 380)
var _rod_tip := Vector2(286, 300)
var _ripples: Array = []
var _ambient: Array = []        # 背景游来游去的环境鱼（纯装饰）
var _home_btn: Button

const AMBIENT_COUNT := 10


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	get_viewport().gui_release_focus()
	set_process(true)
	_layout()
	_spawn_ambient()
	_home_btn = Button.new()
	_home_btn.text = "撤离 · 回家"
	_home_btn.focus_mode = Control.FOCUS_NONE
	_home_btn.add_theme_font_size_override("font_size", 15)
	_home_btn.size = Vector2(132, 34)
	_home_btn.position = Vector2(1130, 14)
	_home_btn.pressed.connect(_on_home_pressed)
	add_child(_home_btn)
	# 入场鱼汛层数由 PetBrain.begin_fishing 算好
	if PetBrain.fishing_bonus_streak > 0:
		_show_banner("鱼汛来了！前%d竿咬钩飞快" % PetBrain.fishing_bonus_streak)
	get_tree().get_root().size_changed.connect(_layout)


func _layout() -> void:
	_sea_y = size.y * 0.56
	_bob_pos = Vector2(size.x * 0.42, _sea_y)
	_rod_tip = Vector2(size.x * 0.225, _sea_y - 80)


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if _done or event is not InputEventKey:
		return
	var ke: InputEventKey = event
	if ke.keycode != KEY_SPACE and ke.keycode != KEY_W and ke.keycode != KEY_UP \
			and ke.physical_keycode != KEY_SPACE and ke.physical_keycode != KEY_W and ke.physical_keycode != KEY_UP:
		return
	if ke.pressed and not ke.echo:
		_on_reel_button_down()
	elif not ke.pressed:
		_on_reel_button_up()


func _on_reel_button_down() -> void:
	_holding = true
	match _phase:
		"idle":
			_cast()
		"bite":
			_hook()
		_:
			pass


func _on_reel_button_up() -> void:
	_holding = false


# ---------- 状态机 ----------

func _cast() -> void:
	_phase = "waiting"
	_this_bonus = PetBrain.fishing_bonus_streak > 0
	if _this_bonus:
		PetBrain.fishing_bonus_streak -= 1
		_wait_dur = randf_range(BONUS_WAIT_MIN, BONUS_WAIT_MAX)
	else:
		_wait_dur = randf_range(WAIT_MIN, WAIT_MAX)
	if PetBrain.has_trait("curious"):
		_wait_dur *= 0.75
	_wait_t = 0.0
	_fish_shadow = 0.0


func _enter_bite() -> void:
	_phase = "bite"
	_bite_t = 0.0
	_bite_quality = "miss"


func _hook() -> void:
	if _bite_t <= PERFECT_WINDOW:
		_bite_quality = "perfect"
		_perfects += 1
	else:
		_bite_quality = "good"
	_start_reel()


func _start_reel() -> void:
	_phase = "reel"
	_reel_progress = 0.0
	_tension = 18.0
	_struggle = false
	_phase_t = 0.0
	_phase_dur = randf_range(CALM_MIN, CALM_MAX)


func _miss(reason: String) -> void:
	_misses += 1
	_patience -= 1
	_phase = "idle"
	_holding = false
	_show_banner(reason)
	if _patience <= 0:
		_finish(true)


func _catch_fish() -> void:
	var catch: Dictionary = _roll_catch()
	_catches += 1
	_result_card = catch
	_phase = "result"
	_result_t = 0.0
	_holding = false
	match str(catch["kind"]):
		"item":
			var id: String = str(catch["id"])
			_items[id] = int(_items.get(id, 0)) + 1
			_show_banner("钓起：%s" % str(catch["name"]))
		"fish":
			var id: String = str(catch["id"])
			_fish.append(id)
			if int(catch["rarity"]) == 3:
				_rare_count += 1
			if not PetState.fish_dex.has(id):
				_new_dex.append(id)
		"junk":
			_garbage += 1


func _process(delta: float) -> void:
	_t += delta
	match _phase:
		"waiting":
			_wait_t += delta
			# 咬钩前约 0.7s 鱼影开始靠近
			var approach: float = _wait_dur - 0.7
			if _wait_t > approach:
				_fish_shadow = clampf((_wait_t - approach) / 0.7, 0.0, 1.0)
			if _wait_t >= _wait_dur:
				_enter_bite()
		"bite":
			_bite_t += delta
			if _bite_t > GOOD_WINDOW:
				_miss("鱼吐钩跑了……")
		"reel":
			_step_reel(delta)
		"result":
			_result_t += delta
			if _result_t >= 1.3:
				_phase = "idle"
	# 水面漂浮粒子
	_tick_ripples(delta)
	queue_redraw()


func _step_reel(delta: float) -> void:
	_phase_t += delta
	if _phase_t >= _phase_dur:
		_struggle = not _struggle
		_phase_t = 0.0
		_phase_dur = randf_range(FIGHT_MIN, FIGHT_MAX) if _struggle else randf_range(CALM_MIN, CALM_MAX)
	var speed_mul: float = 1.15 if PetBrain.has_trait("lively") else 1.0
	var tension_mul: float = 0.8 if PetBrain.has_trait("gentle") else 1.0
	if _holding:
		if _struggle:
			_tension += TENSION_UP_FIGHT * tension_mul * delta
			_reel_progress += PROGRESS_FIGHT * speed_mul * delta
		else:
			_tension += TENSION_UP_CALM * tension_mul * delta
			_reel_progress += REEL_RATE * speed_mul * delta
	else:
		_tension -= (TENSION_DOWN_FIGHT if _struggle else TENSION_DOWN_CALM) * delta
	_tension = clampf(_tension, 0.0, 100.0)
	_reel_progress = clampf(_reel_progress, 0.0, 100.0)
	if _tension >= 100.0:
		_miss("线绷断了！鱼挣脱了……")
	elif _reel_progress >= 100.0:
		_catch_fish()


func _finish(fainted: bool) -> void:
	if _done:
		return
	_done = true
	finished.emit({
		"catches": _catches,
		"misses": _misses,
		"perfects": _perfects,
		"garbage": _garbage,
		"rare": _rare_count,
		"items": _items,
		"fish": _fish,
		"new_dex": _new_dex,
		"fainted": fainted,
		"dex_total": PetEventDeck.FISH_TOTAL,
	})


func _on_home_pressed() -> void:
	_finish(false)


func _show_banner(text: String) -> void:
	_banner_text = text
	_banner_until = _t + 1.8


# ---------- 鱼获权重 ----------

func _weighted_pick(table: Array) -> String:
	var total := 0
	for row in table:
		total += int(row[1])
	var roll := randi() % total
	for row in table:
		roll -= int(row[1])
		if roll < 0:
			return str(row[0])
	return str(table[0][0])


func _roll_catch() -> Dictionary:
	var group_w: Dictionary = CATCH_W_BONUS if _this_bonus else CATCH_W
	var group: String = _weighted_pick([
		["item", int(group_w["item"])],
		["fish", int(group_w["fish"])],
		["junk", int(group_w["junk"])],
	])
	match group:
		"item":
			var table: Array = LOOT_TABLE.duplicate(true)
			if PetBrain.has_trait("curious"):
				for row in table:
					var id: String = str(row[0])
					if id == "bell" or id == "ribbon":
						row[1] = int(row[1]) + 4
					elif id == "key":
						row[1] = int(row[1]) + 3
			var id: String = _weighted_pick(table)
			return {"kind": "item", "id": id, "name": PetEventDeck.ITEM_NAMES.get(id, id)}
		"junk":
			var j: Array = JUNK[randi() % JUNK.size()]
			return {"kind": "junk", "id": str(j[0]), "name": str(j[1])}
		_:
			# 鱼档：完美提一档；好奇再向高档倾斜；鱼汛稀有率翻倍
			var w: Array = (FISH_W_PERFECT if _bite_quality == "perfect" else FISH_W_GOOD).duplicate()
			if PetBrain.has_trait("curious"):
				w[0] -= 10
				w[1] += 5
				w[2] += 5
			if _this_bonus:
				w[0] -= 18
				w[1] += 8
				w[2] += 10
			var tiers: Array = [[], [], []]
			for fid in PetEventDeck.FISH_DEX.keys():
				var info: Dictionary = PetEventDeck.FISH_DEX[fid]
				tiers[int(info["rarity"]) - 1].append(str(fid))
			var total := int(w[0]) + int(w[1]) + int(w[2])
			var roll := randi() % total
			var tier := 0
			for i in 3:
				roll -= int(w[i])
				if roll < 0:
					tier = i
					break
			var fid: String = tiers[tier][randi() % tiers[tier].size()]
			var info: Dictionary = PetEventDeck.FISH_DEX[fid]
			return {
				"kind": "fish", "id": fid, "name": str(info["name"]),
				"rarity": int(info["rarity"]),
				"new": not PetState.fish_dex.has(fid),
			}


# ---------- 背景环境鱼（纯装饰，不影响玩法）----------

func _spawn_ambient() -> void:
	_ambient.clear()
	# 三档稀有度配色 + 绿色，保证一进场就能看到好几种不同的鱼
	var palette := [
		NEON_CYAN, NEON_CYAN, NEON_CYAN, NEON_AMBER, NEON_AMBER,
		NEON_PINK, NEON_PINK, NEON_GREEN, NEON_CYAN, NEON_AMBER,
	]
	palette.shuffle()
	for i in AMBIENT_COUNT:
		var dirv: float = 1.0 if randf() < 0.5 else -1.0
		var base_col: Color = palette[i]
		_ambient.append({
			"off": randf_range(0.0, 1400.0),             # 相位偏移，让鱼分散在屏上
			"speed": randf_range(14.0, 46.0),            # 横向游速（大小鱼不同速）
			"dir": dirv,
			"depth": randf_range(0.1, 0.92),             # 水下深度比例
			"s": randf_range(0.5, 1.15),
			"wob": randf_range(0.6, 1.6),
			"phase": randf_range(0.0, TAU),
			"col": base_col,
			"alpha": randf_range(0.16, 0.3),
		})


# ---------- 水面粒子 ----------

func _tick_ripples(delta: float) -> void:
	if _phase == "idle" and randf() < delta * 1.2:
		_ripples.append({"x": randf_range(0.0, size.x), "y": _sea_y + randf_range(20.0, size.y - _sea_y - 40.0), "r": 2.0, "life": 1.0})
	for rp in _ripples:
		rp["r"] += delta * 14.0
		rp["life"] -= delta * 0.5
	_ripples = _ripples.filter(func(r): return float(r["life"]) > 0.0)


# ---------- 绘制 ----------

func _draw() -> void:
	var font := ThemeDB.fallback_font
	# 夜空 → 海面渐变底
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.016, 0.04), true)
	draw_rect(Rect2(0.0, _sea_y, size.x, size.y - _sea_y), Color(0.012, 0.05, 0.09, 0.55), true)
	_draw_water(font)
	_draw_dock_and_pet()
	_draw_line_and_bob()
	if _phase == "reel":
		_draw_reel_bars(font)
	_draw_hud(font)
	if _phase == "result":
		_draw_result_card(font)


func _draw_water(font: Font) -> void:
	# 三层正弦霓虹波纹
	var layers := [
		{"amp": 5.0, "wl": 130.0, "spd": 0.9, "a": 0.28},
		{"amp": 8.0, "wl": 200.0, "spd": 0.55, "a": 0.18},
		{"amp": 12.0, "wl": 300.0, "spd": 0.32, "a": 0.1},
	]
	for li in layers.size():
		var L: Dictionary = layers[li]
		var base: float = _sea_y + 14.0 + li * 26.0
		var pts := PackedVector2Array()
		var step := 16.0
		var x := 0.0
		while x <= size.x + step:
			var y: float = base + sin(x / float(L["wl"]) * TAU + _t * float(L["spd"]) * 2.0) * float(L["amp"])
			pts.append(Vector2(x, y))
			x += step
		draw_polyline(pts, Color(NEON_CYAN, float(L["a"])), 1.5, true)
	# 上升的数据泡
	for rp in _ripples:
		draw_arc(Vector2(float(rp["x"]), float(rp["y"])), float(rp["r"]), 0.0, TAU, 12, Color(NEON_CYAN, 0.25 * float(rp["life"])), 1.0, true)
	# 水下数据流竖线
	for i in 9:
		var gx: float = size.x * (0.08 + i * 0.105)
		var off: float = fmod(_t * 26.0 + i * 53.0, 120.0)
		draw_line(Vector2(gx, _sea_y + 10.0 + off), Vector2(gx, _sea_y + 26.0 + off), Color(NEON_CYAN, 0.07), 1.0)
	# 背景游鱼：从屏幕一侧游到另一侧再环绕回来
	var span: float = size.x + 160.0
	var water_h: float = size.y - _sea_y - 24.0
	for af in _ambient:
		var fx: float = fmod(float(af["off"]) + float(af["speed"]) * _t, span) - 80.0
		var fy: float = _sea_y + 20.0 + float(af["depth"]) * water_h \
			+ sin(_t * float(af["wob"]) + float(af["phase"])) * 7.0
		var ac: Color = af["col"]
		draw_set_transform(
			Vector2(fx, fy), 0.0,
			Vector2(float(af["dir"]) * float(af["s"]), float(af["s"])))
		_draw_fish_shape(Vector2.ZERO, 1.0, Color(ac.r, ac.g, ac.b, float(af["alpha"])))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_dock_and_pet() -> void:
	# 码头：左侧发光栈桥伸到海面
	var dock_y := _sea_y - 6.0
	draw_rect(Rect2(0.0, dock_y, _rod_tip.x + 30.0, 14.0), Color(0.08, 0.1, 0.18), true)
	draw_line(Vector2(0, dock_y), Vector2(_rod_tip.x + 30.0, dock_y), Color(NEON_AMBER, 0.5), 2.0, true)
	for px in range(0, int(_rod_tip.x) + 30, 34):
		draw_line(Vector2(px, dock_y + 2.0), Vector2(px + 16.0, dock_y + 12.0), Color(NEON_AMBER, 0.18), 1.0)
	# 坐姿毛球（耳 + 圆身 + 闭眼等待的惬意表情）
	var c := Vector2(_rod_tip.x - 46.0, dock_y - 24.0)
	for sgn in [-1.0, 1.0]:
		var ear := PackedVector2Array([
			c + Vector2(sgn * 3, -12),
			c + Vector2(sgn * 8, -26),
			c + Vector2(sgn * 11, -12),
		])
		draw_colored_polygon(ear, FUR_EAR)
	draw_circle(c, 15.0, FUR)
	draw_arc(c, 15.0, 0.0, TAU, 28, NEON_PINK, 2.0, true)
	# 眼朝浮标方向（右侧），等待时眯成弯线
	var ex: float = c.x + 5.0
	if _phase == "waiting" or _phase == "reel":
		draw_line(Vector2(ex, c.y - 3.0), Vector2(ex + 5.0, c.y - 2.0), Color(0.1, 0, 0.12), 1.5, true)
		draw_line(Vector2(ex + 9.0, c.y - 3.0), Vector2(ex + 14.0, c.y - 2.0), Color(0.1, 0, 0.12), 1.5, true)
	else:
		draw_circle(Vector2(ex + 2.0, c.y - 3.0), 2.6, Color.WHITE)
		draw_circle(Vector2(ex + 11.0, c.y - 3.0), 2.6, Color.WHITE)
	# 鱼竿（从毛球身侧到竿梢）
	var grip := c + Vector2(10.0, -2.0)
	draw_line(grip, _rod_tip, Color(NEON_AMBER, 0.9), 2.5, true)
	draw_circle(_rod_tip, 2.5, NEON_AMBER)


func _draw_line_and_bob() -> void:
	if _phase == "idle":
		return
	# 鱼线
	var bob_depth := 0.0
	if _phase == "bite":
		bob_depth = 8.0 + 6.0 * sin(_bite_t * 30.0)
	elif _phase == "reel":
		# 收线时浮标被拉向竿梢
		var k: float = _reel_progress / 100.0
		var target: Vector2 = _rod_tip + Vector2(20.0, 30.0)
		var bp: Vector2 = _bob_pos.lerp(target, k)
		draw_line(_rod_tip, bp, Color(NEON_CYAN, 0.5), 1.0, true)
		_draw_bob(bp, true)
		# 水下挣扎鱼影
		var wob: float = sin(_t * 22.0) * 10.0 * (1.0 if _struggle else 0.3)
		_draw_fish_shape(bp + Vector2(0.0, 34.0 + wob), 1.0, Color(NEON_PINK, 0.65))
		return
	var bp := _bob_pos + Vector2(sin(_t * 3.0) * 2.0, bob_depth)
	draw_line(_rod_tip, bp, Color(NEON_CYAN, 0.5), 1.0, true)
	# 咬钩前靠近的鱼影
	if _phase == "waiting" and _fish_shadow > 0.0:
		var sp: Vector2 = bp + Vector2(70.0 * (1.0 - _fish_shadow), 26.0)
		_draw_fish_shape(sp, 0.9 * _fish_shadow, Color(NEON_CYAN, 0.35 + 0.3 * _fish_shadow))
	# 涟漪
	if _phase == "bite":
		draw_arc(bp + Vector2(0, 2), 10.0 + 6.0 * _bite_t, 0.0, TAU, 20, Color(NEON_PINK, 0.6 * (1.0 - _bite_t / GOOD_WINDOW)), 2.0, true)
	_draw_bob(bp, _phase == "bite")


func _draw_bob(bp: Vector2, sunk: bool) -> void:
	var col: Color = DANGER if sunk else NEON_PINK
	# 浮标：上白下红的小圆漂
	draw_circle(bp, 5.0, col)
	draw_rect(Rect2(bp + Vector2(-4.5, -5.0), Vector2(9.0, 4.5)), Color.WHITE, true)
	draw_arc(bp, 5.0, 0.0, TAU, 14, Color(NEON_PINK, 0.8), 1.0, true)


func _draw_fish_shape(p: Vector2, s: float, col: Color) -> void:
	if s <= 0.05:
		return
	var body := PackedVector2Array([
		p + Vector2(-12, 0) * s, p + Vector2(0, -7) * s,
		p + Vector2(12, 0) * s, p + Vector2(0, 7) * s,
	])
	draw_colored_polygon(body, Color(col.r, col.g, col.b, clampf(col.a, 0.0, 0.5)))
	var wag: float = sin(_t * 18.0) * 4.0 * s
	var tail := PackedVector2Array([
		p + Vector2(-12, 0) * s,
		p + Vector2(-20, -6 + wag * 0.3) * s,
		p + Vector2(-20, 6 + wag * 0.3) * s,
	])
	draw_colored_polygon(tail, Color(col.r, col.g, col.b, clampf(col.a, 0.0, 0.4)))
	draw_polyline(body + PackedVector2Array([body[0]]), col, 1.5, true)


func _draw_reel_bars(font: Font) -> void:
	var bx := size.x * 0.62
	var bw := 300.0
	var y := 110.0
	# 收线进度
	draw_string(font, Vector2(bx, y), "收线", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_DIM)
	draw_rect(Rect2(bx + 48.0, y - 12.0, bw, 12.0), Color(0, 0, 0, 0.55), true)
	draw_rect(Rect2(bx + 49.0, y - 11.0, (bw - 2.0) * _reel_progress / 100.0, 10.0), NEON_GREEN, true)
	draw_rect(Rect2(bx + 48.0, y - 12.0, bw, 12.0), Color(NEON_GREEN, 0.5), false)
	# 张力
	y += 30.0
	var tcol: Color = DANGER if _struggle else NEON_AMBER
	draw_string(font, Vector2(bx, y), "张力", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_DIM)
	draw_rect(Rect2(bx + 48.0, y - 12.0, bw, 12.0), Color(0, 0, 0, 0.55), true)
	draw_rect(Rect2(bx + 49.0, y - 11.0, (bw - 2.0) * _tension / 100.0, 10.0), tcol, true)
	draw_rect(Rect2(bx + 48.0, y - 12.0, bw, 12.0), Color(tcol, 0.6), false)
	# 挣扎警示
	if _struggle:
		var flash: float = 0.6 + 0.4 * sin(_t * 20.0)
		draw_string(font, Vector2(bx + bw + 60.0, y - 2.0), "✦ 挣扎！松手", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(DANGER, flash))
	else:
		draw_string(font, Vector2(bx + bw + 60.0, y - 2.0), "按住收线", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, NEON_GREEN)


func _draw_hud(font: Font) -> void:
	draw_string(font, Vector2(14, 26), "数据海 // SECTOR-07", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, NEON_CYAN)
	# 耐心 ♥
	for i in MAX_PATIENCE:
		var hx: float = 14.0 + i * 24.0
		var col: Color = DANGER if i < _patience else Color(DANGER, 0.22)
		_draw_heart(Vector2(hx, 44.0), 8.0, col)
	# 统计
	draw_string(font, Vector2(96, 50), "钓获 %d   脱钩 %d   图鉴 %d/%d" % [_catches, _misses, PetState.fish_dex.size(), PetEventDeck.FISH_TOTAL], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.75, 0.82, 0.9))
	if PetBrain.fishing_bonus_streak > 0 or _this_bonus:
		draw_string(font, Vector2(420, 50), "⚡鱼汛×%d" % maxi(PetBrain.fishing_bonus_streak, 1 if _this_bonus else 0), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, NEON_GREEN)
	# 本次收获 chips
	var cx := 14.0
	var cy := 76.0
	for id in _items.keys():
		var txt: String = "%s×%d" % [PetEventDeck.ITEM_NAMES.get(str(id), str(id)), int(_items[id])]
		cx = _draw_chip(font, Vector2(cx, cy), txt, NEON_AMBER)
	for fid in _fish:
		var nm: String = PetEventDeck.FISH_DEX[str(fid)]["name"]
		var rare: int = PetEventDeck.FISH_DEX[str(fid)]["rarity"]
		cx = _draw_chip(font, Vector2(cx, cy), "鱼·%s" % nm, RARITY_COLOR[rare])
	# 阶段提示（底部居中）
	var hint := ""
	match _phase:
		"idle":
			hint = "空格 / W / ↑ 抛竿"
		"waiting":
			hint = "盯着浮标……"
		"bite":
			hint = "咬钩了！空格刺鱼！"
		"reel":
			hint = ""   # 右侧条上有提示
		"result":
			hint = ""
	if hint != "":
		var w: float = font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		var col: Color = DANGER if _phase == "bite" else TEXT_DIM
		draw_string(font, Vector2(size.x * 0.5 - w * 0.5, size.y - 12.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)
	# 飘字
	if _t < _banner_until and _banner_text != "":
		var bw2: float = font.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		draw_string(font, Vector2(size.x * 0.5 - bw2 * 0.5, 120.0), _banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, NEON_PINK)


func _draw_heart(p: Vector2, r: float, col: Color) -> void:
	draw_circle(p + Vector2(-r * 0.4, -r * 0.2), r * 0.55, col)
	draw_circle(p + Vector2(r * 0.4, -r * 0.2), r * 0.55, col)
	var tri := PackedVector2Array([
		p + Vector2(-r * 0.9, -r * 0.05),
		p + Vector2(r * 0.9, -r * 0.05),
		p + Vector2(0, r),
	])
	draw_colored_polygon(tri, col)


func _draw_chip(font: Font, p: Vector2, txt: String, col: Color) -> float:
	var pad := 8.0
	var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var rect := Rect2(p, Vector2(tw + pad * 2.0, 22.0))
	draw_rect(rect, Color(col, 0.12), true)
	draw_rect(rect, Color(col, 0.6), false)
	draw_string(font, p + Vector2(pad, 15.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
	return p.x + rect.size.x + 8.0


func _draw_result_card(font: Font) -> void:
	var kind: String = str(_result_card.get("kind", ""))
	var w2 := 360.0
	var h2 := 220.0
	var card := Rect2(size.x * 0.5 - w2 * 0.5, size.y * 0.34, w2, h2)
	var a: float = clampf(_result_t * 4.0, 0.0, 1.0)
	draw_rect(card, Color(0.03, 0.025, 0.07, 0.95 * a), true)
	var accent: Color = NEON_AMBER
	if kind == "fish":
		accent = RARITY_COLOR[int(_result_card["rarity"])]
	elif kind == "junk":
		accent = TEXT_DIM
	draw_rect(card, Color(accent, 0.8 * a), false, 2.0)
	# 图
	var center: Vector2 = card.get_center() + Vector2(0, -34)
	if kind == "fish":
		var pulse: float = 1.0 + 0.06 * sin(_t * 6.0)
		_draw_fish_large(center, pulse, accent, a)
	elif kind == "junk":
		draw_rect(Rect2(center + Vector2(-12, -8), Vector2(24, 16)), Color(TEXT_DIM, a), true)
		draw_rect(Rect2(center + Vector2(-12, -8), Vector2(24, 16)), Color(TEXT_DIM, 0.8 * a), false, 1.5)
	else:
		# 道具：发光小箱
		draw_rect(Rect2(center + Vector2(-14, -10), Vector2(28, 20)), Color(accent, 0.25 * a), true)
		draw_rect(Rect2(center + Vector2(-14, -10), Vector2(28, 20)), Color(accent, 0.9 * a), false, 2.0)
	# 名 + 标签
	var title: String = str(_result_card.get("name", ""))
	var tw2: float = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	draw_string(font, Vector2(center.x - tw2 * 0.5, card.position.y + h2 - 58.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(accent.lightened(0.25), a))
	var sub := ""
	if kind == "fish":
		sub = "%s · %s" % [PetEventDeck.FISH_RARITY_LABELS[int(_result_card["rarity"])], "完美刺鱼" if _bite_quality == "perfect" else "及时刺鱼"]
		if bool(_result_card.get("new", false)):
			sub = "✦ 新收录！" + sub
	elif kind == "junk":
		sub = "……是垃圾，毛球有点失望"
	else:
		sub = "海里捞到的小道具"
	var sw: float = font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	draw_string(font, Vector2(center.x - sw * 0.5, card.position.y + h2 - 30.0), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.72, 0.8, 0.88, a))


func _draw_fish_large(p: Vector2, s: float, col: Color, a: float) -> void:
	var body := PackedVector2Array([
		p + Vector2(-34, 0) * s, p + Vector2(0, -20) * s,
		p + Vector2(34, 0) * s, p + Vector2(0, 20) * s,
	])
	draw_colored_polygon(body, Color(col.r, col.g, col.b, 0.3 * a))
	var wag: float = sin(_t * 10.0) * 8.0
	var tail := PackedVector2Array([
		p + Vector2(-34, 0) * s,
		p + Vector2(-54, -16 + wag) * s,
		p + Vector2(-54, 16 + wag) * s,
	])
	draw_colored_polygon(tail, Color(col.r, col.g, col.b, 0.25 * a))
	draw_polyline(body + PackedVector2Array([body[0]]), Color(col, a), 2.5, true)
	draw_circle(p + Vector2(18, -6) * s, 3.0, Color(0.05, 0, 0.1, a))
