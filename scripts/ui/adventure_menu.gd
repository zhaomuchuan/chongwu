extends Window
## 「冒险」入口选择窗：在俯视角探索与横版闯关之间二选一。
## 只负责选择，精力门槛与结算仍在 main / PetBrain，弹窗不碰数值。

signal explore_chosen
signal platformer_chosen
signal fishing_chosen

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_AMBER := Color(1.0, 0.78, 0.25)
const NEON_GREEN := Color(0.224, 1.0, 0.314)
const INK := Color(0.043, 0.031, 0.086)


func _ready() -> void:
	title = "冒险"
	wrap_controls = false
	borderless = true
	size = Vector2i(820, 300)
	min_size = Vector2i(760, 280)
	unresizable = false
	close_requested.connect(hide)
	_build()
	hide()


func open_menu() -> void:
	popup_centered()


func _build() -> void:
	# 深色底 + 霓虹描边
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = INK
	bg_sb.border_color = Color(NEON_PINK, 0.7)
	bg_sb.set_border_width_all(1)
	bg_sb.shadow_color = Color(NEON_CYAN, 0.35)
	bg_sb.shadow_size = 10
	bg.add_theme_stylebox_override("panel", bg_sb)
	add_child(bg)

	# 标题条
	var bar := ColorRect.new()
	bar.color = Color(NEON_PINK, 0.13)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_bottom = 32
	add_child(bar)
	var bar_line := ColorRect.new()
	bar_line.color = NEON_PINK
	bar_line.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar_line.offset_top = 31
	bar_line.offset_bottom = 32
	add_child(bar_line)
	var title_l := Label.new()
	title_l.text = "// FIELD.SELECT — 今天去哪儿冒险？"
	title_l.add_theme_color_override("font_color", NEON_CYAN)
	title_l.add_theme_font_size_override("font_size", 15)
	title_l.position = Vector2(14, 7)
	add_child(title_l)
	var close := Button.new()
	close.text = "✕"
	close.focus_mode = Control.FOCUS_NONE
	close.add_theme_font_size_override("font_size", 14)
	close.custom_minimum_size = Vector2(34, 30)
	close.position = Vector2(size.x - 42, 1)
	close.pressed.connect(hide)
	add_child(close)

	# 三张大卡片
	var row := HBoxContainer.new()
	row.position = Vector2(20, 48)
	row.custom_minimum_size = Vector2(size.x - 40, size.y - 68)
	row.add_theme_constant_override("separation", 14)
	add_child(row)
	row.add_child(_make_card(
		"数据废墟 · 探索",
		"俯视角 Roguelike\n迷雾中挖宝、踩点打怪\n一层层往下潜，背包塞满再回家",
		NEON_CYAN,
		explore_chosen))
	row.add_child(_make_card(
		"霓虹天台 · 闯关",
		"横版超级玛丽式跑酷\n跳过裂沟与红尖刺、踩扁故障虫\n三关冲到终点旗杆",
		NEON_AMBER,
		platformer_chosen))
	row.add_child(_make_card(
		"数据海 · 垂钓",
		"坐着就能玩的慢节奏\n抓浮标下沉的时机提竿\n和鱼较劲张力，收集 8 种数据鱼\n离线久了还有鱼汛",
		NEON_GREEN,
		fishing_chosen))


func _make_card(title: String, desc: String, accent: Color, picked: Signal) -> Control:
	var card := Button.new()
	card.focus_mode = Control.FOCUS_NONE
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(240, 220)
	card.pressed.connect(func() -> void:
		hide()
		picked.emit())

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.06, 0.075, 0.14)
	normal.border_color = Color(accent, 0.55)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(4)
	normal.content_margin_left = 18
	normal.content_margin_top = 16
	normal.content_margin_right = 18
	normal.content_margin_bottom = 16
	var hover := normal.duplicate()
	hover.bg_color = Color(accent, 0.12)
	hover.border_color = accent
	var pressed := normal.duplicate()
	pressed.bg_color = Color(accent, 0.2)
	card.add_theme_stylebox_override("normal", normal)
	card.add_theme_stylebox_override("hover", hover)
	card.add_theme_stylebox_override("pressed", pressed)
	card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	card.text = ""

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 18
	vb.offset_top = 16
	vb.offset_right = -18
	vb.offset_bottom = -16
	vb.add_theme_constant_override("separation", 12)
	card.add_child(vb)
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", accent)
	t.add_theme_font_size_override("font_size", 20)
	vb.add_child(t)
	var d := Label.new()
	d.text = desc
	d.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	d.add_theme_font_size_override("font_size", 14)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size = Vector2(200, 0)
	vb.add_child(d)
	var go := Label.new()
	go.text = "点击出发 ▸"
	go.add_theme_color_override("font_color", Color(NEON_PINK, 0.9))
	go.add_theme_font_size_override("font_size", 13)
	vb.add_child(go)
	return card
