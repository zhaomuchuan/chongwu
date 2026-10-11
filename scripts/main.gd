extends Node2D
## 主场景：组装宠物 + UI，串联交互与 LLM 对话流程（程序化构建，无 .tscn UI）。

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine
@onready var LLM := get_node("/root/LLM") as LlmClient
@onready var Scheduler := get_node("/root/Scheduler") as EventScheduler

const PET_VISUAL := "res://scripts/pet_actor.gd"
const RADAR := "res://scripts/ui/radar_chart.gd"
const STATUS := "res://scripts/ui/status_panel.gd"
const DIALOGUE := "res://scripts/ui/dialogue_box.gd"
const SETTINGS := "res://scripts/ui/settings_dialog.gd"
const ADVENTURE_MENU := "res://scripts/ui/adventure_menu.gd"
const CYBER_BG := "res://scripts/ui/cyber_background.gd"
const CLOCK := "res://scripts/ui/clock_panel.gd"
const EXPLORE := "res://scripts/world/explore_world.gd"
const PLATFORMER := "res://scripts/world/platformer_world.gd"
const FISHING := "res://scripts/world/fishing_world.gd"

# 赛博朋克配色
const INK_BG := Color(0.043, 0.031, 0.086)          # 深紫黑
const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const TEXT_DIM := Color(0.55, 0.66, 0.78)

var _pet: Node2D
var _radar: Control
var _status: Control
var _dialogue: Control
var _settings: Window
var _adventure_menu: Window
var _hint: Label
var _log_label: Label
var _inventory_box: HFlowContainer
var _inventory_empty: Label
var _ui_layer: CanvasLayer
var _explore: Control
var _platformer: Control
var _fishing: Control
var _feed_btn: Button
var _busy := false
var _pending_user_text := ""   # 等待回复的用户原话（主动搭话时为空，不参与情感结算）


func _ready() -> void:
	_fit_window()
	_build_pet()
	_build_ui()
	_connect_signals()
	_greet()


func _build_pet() -> void:
	_pet = load(PET_VISUAL).new()
	_pet.position = Vector2(210, 430)
	add_child(_pet)


func _build_ui() -> void:
	# 背景层（在宠物后方）
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = INK_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_layer.add_child(bg)
	var cyber: Control = load(CYBER_BG).new()
	cyber.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_layer.add_child(cyber)

	# UI 层
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 1
	add_child(_ui_layer)
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 空白区域放行鼠标事件，否则这个全屏容器会把下层宠物的点击/拖拽全部吞掉
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(overlay)

	# 左上：日期 / 时间 / 天气
	var clock: Control = load(CLOCK).new()
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(clock, 20, 20, 520, 98)
	overlay.add_child(clock)

	_status = load(STATUS).new()
	_place(_status, 560, 20, 700, 132)
	overlay.add_child(_status)

	_radar = load(RADAR).new()
	_place(_radar, 560, 158, 340, 340)
	overlay.add_child(_radar)

	# 成长记录
	var log_title := _make_label("成长记录 // GROWTH LOG", 15, NEON_CYAN)
	_place(log_title, 940, 150, 320, 26)
	overlay.add_child(log_title)

	_log_label = Label.new()
	_log_label.add_theme_font_size_override("font_size", 13)
	_log_label.add_theme_color_override("font_color", Color(0.72, 0.82, 0.90))
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 每条日志常换成两行；裁剪兜底，防止长文案溢出盖住背包区
	_log_label.clip_contents = true
	_place(_log_label, 940, 184, 320, 196)
	overlay.add_child(_log_label)
	_refresh_log()

	# 背包（随机事件获得 / 丢失的道具，点击使用）
	var inv_title := _make_label("背包 // INVENTORY（点击使用）", 15, NEON_PINK)
	_place(inv_title, 940, 392, 320, 26)
	overlay.add_child(inv_title)
	_inventory_box = HFlowContainer.new()
	_inventory_box.add_theme_constant_override("h_separation", 6)
	_inventory_box.add_theme_constant_override("v_separation", 6)
	_place(_inventory_box, 940, 422, 320, 92)
	_inventory_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(_inventory_box)
	_inventory_empty = Label.new()
	_inventory_empty.add_theme_font_size_override("font_size", 13)
	_inventory_empty.add_theme_color_override("font_color", Color(0.45, 0.52, 0.62))
	_inventory_empty.text = "（空空如也，毛球正在到处寻宝……）"
	_place(_inventory_empty, 940, 426, 320, 20)
	overlay.add_child(_inventory_empty)
	_refresh_inventory()

	# 交互按钮（横向一排）
	var btn_box := HBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 10)
	_place(btn_box, 560, 520, 700, 44)
	overlay.add_child(btn_box)
	var pets := [["摸头", "_on_pet"], ["喂食", "_on_feed"], ["安抚", "_on_comfort"], ["聊天", "_on_chat"], ["玩耍", "_on_play"], ["冒险", "_on_adventure_menu"], ["设置", "_on_settings"]]
	for p in pets:
		var b := Button.new()
		b.text = p[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		_style_button(b, p[0] == "设置" or p[0] == "冒险")
		b.pressed.connect(Callable(self, p[1]))
		btn_box.add_child(b)
		if p[1] == "_on_feed":
			_feed_btn = b
	_refresh_feed_button()

	# 提示行
	_hint = Label.new()
	_hint.add_theme_color_override("font_color", NEON_PINK)
	_hint.add_theme_font_size_override("font_size", 13)
	_place(_hint, 20, 556, 520, 20)
	overlay.add_child(_hint)
	_set_hint("")

	# 对话区
	_dialogue = load(DIALOGUE).new()
	_place(_dialogue, 20, 584, 1240, 116)
	overlay.add_child(_dialogue)

	# 设置弹窗（挂在窗口层，默认隐藏，点「设置」才弹出）
	_settings = load(SETTINGS).new()
	_settings.hide()
	_ui_layer.add_child(_settings)

	# 冒险选择窗（探索 / 闯关 / 垂钓 三选一）
	_adventure_menu = load(ADVENTURE_MENU).new()
	_adventure_menu.hide()
	_adventure_menu.explore_chosen.connect(_on_explore)
	_adventure_menu.platformer_chosen.connect(_on_adventure)
	_adventure_menu.fishing_chosen.connect(_on_fishing)
	_ui_layer.add_child(_adventure_menu)


# 以 1280×720 为设计基准；按屏幕可用区域（换算系统 DPI 缩放）等比缩小，配合 aspect=keep 保证不裁切
func _fit_window() -> void:
	var win := get_window()
	var usable := DisplayServer.screen_get_usable_rect()
	var scalef: float = DisplayServer.screen_get_scale()
	var avail_w: float = usable.size.x / scalef
	var avail_h: float = usable.size.y / scalef
	var k := clampf(minf(avail_w / 1280.0, avail_h / 720.0), 0.75, 1.0)
	win.size = Vector2i(int(1280.0 * k), int(720.0 * k))
	win.min_size = Vector2i(960, 540)
	await get_tree().process_frame
	win.position = Vector2i(
		usable.position.x + int((usable.size.x - win.size.x) / 2.0),
		usable.position.y + int((usable.size.y - win.size.y) / 2.0)
	)


# 直角 + 霓虹描边的赛博按钮
func _style_button(b: Button, secondary: bool) -> void:
	var edge: Color = NEON_CYAN if not secondary else NEON_PINK
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", edge)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(0)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		match state:
			"normal":
				sb.bg_color = Color(0.05, 0.07, 0.14, 0.92)
				sb.border_color = Color(edge, 0.75)
			"hover":
				sb.bg_color = Color(edge, 0.16)
				sb.border_color = edge
				sb.shadow_color = Color(edge, 0.55)
				sb.shadow_size = 5
			"pressed":
				sb.bg_color = Color(edge, 0.32)
				sb.border_color = edge
		sb.set_border_width_all(1)
		b.add_theme_stylebox_override(state, sb)


func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l


func _place(c: Control, x: float, y: float, w: float, h: float) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 0.0
	c.anchor_bottom = 0.0
	c.offset_left = x
	c.offset_top = y
	c.offset_right = x + w
	c.offset_bottom = y + h


func _connect_signals() -> void:
	_dialogue.send_requested.connect(_on_send)
	LLM.reply_ready.connect(_on_reply)
	Scheduler.proactive_chat.connect(_on_proactive)
	Scheduler.local_event.connect(_on_local_event)
	Scheduler.needs_attention.connect(_on_needs_attention)
	Scheduler.special_event.connect(_on_special_event)
	PetState.log_added.connect(_on_log_added)
	PetState.state_changed.connect(_on_state_changed)
	_settings.hint.connect(_set_hint)


func _set_hint(text: String) -> void:
	_hint.text = "» " + text if text != "" else ""


func _greet() -> void:
	await get_tree().create_timer(0.6).timeout
	_start_chat("", "（请主动和主人打个招呼，一句话）")


func _start_chat(user_text: String, intent: String) -> void:
	if _busy:
		return
	_busy = true
	_pending_user_text = user_text
	_set_hint("思考中……")
	LLM.chat(user_text, intent)


func _on_send(text: String) -> void:
	if _busy:
		return
	_dialogue.append_player(text)
	_start_chat(text, "")


func _on_reply(speech: String, degraded: bool, reason: String, sentiment: Dictionary) -> void:
	_busy = false
	# 只对「主人发的消息」做情感结算；主动搭话（无原文）不影响性格
	var user_text := _pending_user_text
	_pending_user_text = ""
	if user_text.strip_edges() != "":
		_apply_chat_sentiment(user_text, sentiment, degraded)
	if degraded:
		_set_hint("离线兜底：%s" % reason)
	else:
		_set_hint("")
	_dialogue.append_pet(speech)
	_pet.show_bubble(speech)


func _apply_chat_sentiment(user_text: String, sentiment: Dictionary, degraded: bool) -> void:
	var kind := ""
	var intensity := 0.5
	# 优先用 LLM 给出的标签；离线/模型没按格式回时，本地关键词分析兜底
	if not degraded and sentiment.has("kind"):
		kind = str(sentiment["kind"])
		intensity = float(sentiment.get("intensity", 0.5))
	else:
		var local: Dictionary = PetBrain.analyze_sentiment_text(user_text)
		kind = str(local.get("kind", "neutral"))
		intensity = float(local.get("intensity", 0.5))
	PetBrain.apply_chat_sentiment(kind, intensity)


func _on_proactive() -> void:
	_dialogue.append_system("%s 主动来找你……" % PetState.pet_name)
	_start_chat("", "（你主动想找主人说点什么，一句话）")


func _on_local_event(text: String) -> void:
	_dialogue.append_system(text)


func _on_needs_attention(text: String) -> void:
	_dialogue.append_system("%s：%s" % [PetState.pet_name, text])


func _on_log_added(_entry: Dictionary) -> void:
	_refresh_log()


func _on_state_changed() -> void:
	_refresh_inventory()
	_refresh_feed_button()


# 喂食按钮显示剩余口粮份数；耗尽时变成「备货中」
func _refresh_feed_button() -> void:
	if _feed_btn == null:
		return
	var left: int = PetBrain.feed_charges_left()
	var txt := "喂食 ×%d" % left if left > 0 else "喂食 · 备货中"
	if _feed_btn.text != txt:
		_feed_btn.text = txt


func _refresh_inventory() -> void:
	if _inventory_box == null:
		return
	for c in _inventory_box.get_children():
		c.queue_free()
	var has_items := not PetState.inventory.is_empty()
	_inventory_empty.visible = not has_items
	if not has_items:
		return
	# 按图鉴固定顺序展示，图鉴外的道具排在后面
	var ids: Array = []
	for id in PetEventDeck.ITEM_NAMES.keys():
		if PetState.inventory.has(id):
			ids.append(id)
	for id in PetState.inventory.keys():
		if not ids.has(id):
			ids.append(id)
	for id in ids:
		var count: int = int(PetState.inventory[id])
		var b := Button.new()
		# 回精力的道具标一个 ⚡，方便一眼认出应急体力
		var spark: String = "⚡" if PetBrain.item_gives_energy(str(id)) else "◆"
		b.text = "%s %s ×%d" % [spark, PetEventDeck.ITEM_NAMES.get(str(id), str(id)), count]
		b.tooltip_text = PetBrain.item_effect_summary(str(id))
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 13)
		_style_item_button(b)
		b.pressed.connect(_on_use_item.bind(str(id)))
		_inventory_box.add_child(b)


# 琥珀色小按钮
func _style_item_button(b: Button) -> void:
	var amber := Color(1.0, 0.78, 0.25)
	b.add_theme_color_override("font_color", amber)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(0)
		sb.content_margin_left = 7
		sb.content_margin_right = 7
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
		match state:
			"normal":
				sb.bg_color = Color(0.12, 0.09, 0.03, 0.9)
				sb.border_color = Color(amber, 0.6)
			"hover":
				sb.bg_color = Color(amber, 0.18)
				sb.border_color = amber
				sb.shadow_color = Color(amber, 0.5)
				sb.shadow_size = 4
			"pressed":
				sb.bg_color = Color(amber, 0.3)
				sb.border_color = amber
		sb.set_border_width_all(1)
		b.add_theme_stylebox_override(state, sb)


func _on_use_item(item_id: String) -> void:
	var result: Dictionary = PetBrain.use_item(item_id)
	if not result.get("ok", false):
		return
	_pet.play_reaction(str(result.get("reaction", "positive")))
	_dialogue.append_system("你把【%s】拿给毛球玩。" % str(result.get("name", "")))
	_dialogue.append_pet(str(result.get("speech", "")))
	_pet.show_bubble(str(result.get("speech", "")))


# 特殊随机事件：头顶气泡 + 对话区横幅
func _on_special_event(event: Dictionary) -> void:
	var speech := str(event.get("speech", ""))
	if speech != "":
		_pet.show_bubble(speech)
	var banner := "✦ %s" % str(event.get("title", "事件"))
	var gains: Array = event.get("gains", [])
	if not gains.is_empty():
		var parts: Array = []
		for g in gains:
			parts.append(("%s %s" % ["＋" if g[1] > 0 else "－", g[0]]))
		banner += "：%s" % "，".join(parts)
	_dialogue.append_system(banner)


func _refresh_log() -> void:
	if _log_label == null:
		return
	var lines: Array = []
	var entries: Array = PetState.growth_log
	var start := maxi(0, entries.size() - 4)
	for i in range(start, entries.size()):
		var e: Dictionary = entries[i]
		lines.append("[%s] %s" % [str(e.get("time", "")).right(5), str(e.get("event", ""))])
	_log_label.text = "\n".join(lines)


func _on_pet() -> void:
	_interact("pet")


func _on_feed() -> void:
	_interact("feed")


func _on_comfort() -> void:
	_interact("comfort")


func _interact(kind: String) -> void:
	if _busy:
		return
	if not PetBrain.apply_interaction(kind):
		# 目前只有口粮耗尽的喂食会被拒
		var mins: int = maxi(1, ceili(PetBrain.feed_seconds_to_next() / 60.0))
		_dialogue.append_system("干粮吃完了，下一份还在路上，大约 %d 分钟后配送到货……" % mins)
		_pet.show_bubble("碗空了……干粮还要 %d 分钟才到，我先忍忍。" % mins)
		return
	var line := LLM.offline_reply("")
	_dialogue.append_pet(line)
	_pet.show_bubble(line)


func _on_chat() -> void:
	_dialogue.focus_input()


func _on_play() -> void:
	_interact("play")


# 点「冒险」：弹出探索 / 闯关二选一窗口
func _on_adventure_menu() -> void:
	if _busy or _explore != null or _platformer != null or _fishing != null:
		return
	_adventure_menu.open_menu()


# 进入俯视角探索世界（精力不足被 PetBrain 拒绝）
func _on_explore() -> void:
	if _busy or _explore != null or _platformer != null or _fishing != null:
		return
	if not PetBrain.begin_exploration():
		_dialogue.append_system("%s太累了，先喂点吃的或睡一觉，再出门探险吧……" % PetState.pet_name)
		_pet.show_bubble("我现在没力气出门探险……让我歇会儿嘛。")
		return
	_dialogue.append_system("%s一溜烟钻进了数据废墟深处。" % PetState.pet_name)
	_explore = load(EXPLORE).new()
	_ui_layer.add_child(_explore)
	_explore.finished.connect(_on_explore_done)


# 探险归来：PetBrain 确定性结算 → 对话区播报 + 宠物表演
func _on_explore_done(summary: Dictionary) -> void:
	var result: Dictionary = PetBrain.settle_expedition(summary)
	if _explore != null:
		_explore.queue_free()
		_explore = null
	_dialogue.append_system(str(result.get("line", "")))
	_dialogue.append_pet(str(result.get("speech", "")))
	_pet.show_bubble(str(result.get("speech", "")))
	_pet.play_reaction(str(result.get("reaction", "positive")))


# 进入横版霓虹天台跑酷（精力不足被 PetBrain 拒绝）
func _on_adventure() -> void:
	if _busy or _explore != null or _platformer != null or _fishing != null:
		return
	if not PetBrain.begin_adventure():
		_dialogue.append_system("%s太累了，先喂点吃的或睡一觉，再去天台跑酷吧……" % PetState.pet_name)
		_pet.show_bubble("我现在没力气蹦跶……让我歇会儿嘛。")
		return
	_dialogue.append_system("%s一溜烟跳上了霓虹天台。" % PetState.pet_name)
	_platformer = load(PLATFORMER).new()
	_ui_layer.add_child(_platformer)
	_platformer.finished.connect(_on_adventure_done)


# 跑酷归来：PetBrain 确定性结算 → 对话区播报 + 宠物表演
func _on_adventure_done(summary: Dictionary) -> void:
	var result: Dictionary = PetBrain.settle_platformer(summary)
	if _platformer != null:
		_platformer.queue_free()
		_platformer = null
	_dialogue.append_system(str(result.get("line", "")))
	_dialogue.append_pet(str(result.get("speech", "")))
	_pet.show_bubble(str(result.get("speech", "")))
	_pet.play_reaction(str(result.get("reaction", "positive")))


# 进入数据海垂钓（精力不足被 PetBrain 拒绝）
func _on_fishing() -> void:
	if _busy or _explore != null or _platformer != null or _fishing != null:
		return
	if not PetBrain.begin_fishing():
		_dialogue.append_system("%s太累了，先喂点吃的或睡一觉，再去海边钓鱼吧……" % PetState.pet_name)
		_pet.show_bubble("我现在扛不动鱼竿……让我歇会儿嘛。")
		return
	_dialogue.append_system("%s扛着小鱼竿，溜去了数据海边上。" % PetState.pet_name)
	_fishing = load(FISHING).new()
	_ui_layer.add_child(_fishing)
	_fishing.finished.connect(_on_fishing_done)


# 钓鱼归来：PetBrain 确定性结算 → 对话区播报 + 宠物表演
func _on_fishing_done(summary: Dictionary) -> void:
	var result: Dictionary = PetBrain.settle_fishing(summary)
	if _fishing != null:
		_fishing.queue_free()
		_fishing = null
	_dialogue.append_system(str(result.get("line", "")))
	_dialogue.append_pet(str(result.get("speech", "")))
	_pet.show_bubble(str(result.get("speech", "")))
	_pet.play_reaction(str(result.get("reaction", "positive")))


func _on_settings() -> void:
	if _busy:
		return
	_settings.open()
