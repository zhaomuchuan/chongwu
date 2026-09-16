extends Window
## LLM 设置弹窗：API Key / Base URL / 模型 / 温度，保存到 user://，支持测试连接。

signal settings_saved
signal hint(text: String)

const LLM_NODE := "/root/LLM"

var _key_edit: LineEdit
var _url_edit: LineEdit
var _model_edit: LineEdit
var _temp_edit: SpinBox
var _status: Label
var _test_btn: Button
var _save_btn: Button


func _ready() -> void:
	title = "设置"
	wrap_controls = false
	borderless = true
	size = Vector2i(480, 368)
	min_size = Vector2i(440, 340)
	unresizable = false
	close_requested.connect(hide)
	_build()
	_load_into_ui()
	hide()


func open() -> void:
	_load_into_ui()
	_set_status("", Color(0.7, 0.75, 0.82))
	popup_centered()


const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const INK := Color(0.043, 0.031, 0.086)


func _build() -> void:
	# 深色底 + 霓虹描边
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_sb := StyleBoxFlat.new()
	bg_sb.bg_color = INK
	bg_sb.border_color = Color(NEON_CYAN, 0.7)
	bg_sb.set_border_width_all(1)
	bg_sb.shadow_color = Color(NEON_PINK, 0.4)
	bg_sb.shadow_size = 10
	bg.add_theme_stylebox_override("panel", bg_sb)
	add_child(bg)

	# 自绘标题条（extend_to_title 后系统标题栏消失）
	var bar := ColorRect.new()
	bar.color = Color(NEON_PINK, 0.13)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_top = 0
	bar.offset_bottom = 32
	add_child(bar)
	var bar_line := ColorRect.new()
	bar_line.color = NEON_PINK
	bar_line.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar_line.offset_top = 31
	bar_line.offset_bottom = 32
	add_child(bar_line)
	var title_l := Label.new()
	title_l.text = "// SYS.CONFIG — 设置"
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
	for state in ["normal", "hover", "pressed"]:
		var csb := StyleBoxEmpty.new()
		close.add_theme_stylebox_override(state, csb)
	close.add_theme_color_override("font_color", Color(0.7, 0.78, 0.85))
	close.add_theme_color_override("font_hover_color", NEON_PINK)
	close.pressed.connect(hide)
	add_child(close)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 18
	root.offset_top = 44
	root.offset_right = -18
	root.offset_bottom = -14
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	root.add_child(grid)

	_key_edit = _row(grid, "API Key", LineEdit.new())
	_key_edit.secret = true
	_key_edit.placeholder_text = "sk-...（留空则使用 DEEPSEEK_API_KEY 环境变量）"

	_url_edit = _row(grid, "Base URL", LineEdit.new())
	_url_edit.placeholder_text = "https://api.deepseek.com"

	_model_edit = _row(grid, "模型", LineEdit.new())
	_model_edit.placeholder_text = "deepseek-chat"

	_temp_edit = _row(grid, "温度", SpinBox.new())
	_temp_edit.min_value = 0.0
	_temp_edit.max_value = 2.0
	_temp_edit.step = 0.1
	_temp_edit.value = 0.8
	_temp_edit.custom_arrow_step = 0.1
	_temp_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# 让输入框占满第二列 + 霓虹样式
	for c in [_key_edit, _url_edit, _model_edit, _temp_edit]:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_field(c)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var note := Label.new()
	note.text = "// API Key 保存在本机用户目录（user://llm_config.json），不会写入项目。"
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", Color(0.55, 0.70, 0.78))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(note)

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 13)
	_status.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_status)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	btns.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(btns)

	_test_btn = Button.new()
	_test_btn.text = "测试连接"
	_style_btn(_test_btn, NEON_CYAN)
	_test_btn.pressed.connect(_on_test)
	btns.add_child(_test_btn)

	_save_btn = Button.new()
	_save_btn.text = "保存 ▸"
	_style_btn(_save_btn, NEON_PINK)
	_save_btn.add_theme_font_size_override("font_size", 14)
	_save_btn.pressed.connect(_on_save)
	btns.add_child(_save_btn)

	var cancel := Button.new()
	cancel.text = "取消"
	_style_btn(cancel, Color(0.55, 0.62, 0.72))
	cancel.pressed.connect(hide)
	btns.add_child(cancel)


func _style_field(c: Control) -> void:
	if c is LineEdit:
		var le := c as LineEdit
		le.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
		le.add_theme_color_override("font_placeholder_color", Color(0.42, 0.53, 0.63))
		le.add_theme_color_override("caret_color", NEON_CYAN)
	for state in ["normal", "focus", "read_only"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(0)
		sb.bg_color = Color(0.02, 0.02, 0.05, 0.95)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		sb.set_border_width_all(1)
		sb.border_color = Color(NEON_CYAN, 0.85) if state == "focus" else Color(NEON_CYAN, 0.35)
		if state == "focus":
			sb.shadow_color = Color(NEON_CYAN, 0.4)
			sb.shadow_size = 4
		c.add_theme_stylebox_override(state, sb)


func _style_btn(b: Button, edge: Color) -> void:
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", edge)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(0)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		sb.set_border_width_all(1)
		sb.border_color = Color(edge, 0.8)
		match state:
			"normal":
				sb.bg_color = Color(0.05, 0.07, 0.14, 0.92)
			"hover":
				sb.bg_color = Color(edge, 0.18)
				sb.shadow_color = Color(edge, 0.5)
				sb.shadow_size = 5
			"pressed":
				sb.bg_color = Color(edge, 0.34)
		b.add_theme_stylebox_override(state, sb)


func _row(grid: GridContainer, label_text: String, edit: Control) -> Control:
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(72, 0)
	l.add_theme_color_override("font_color", NEON_CYAN)
	grid.add_child(l)
	grid.add_child(edit)
	return edit


func _llm() -> Node:
	return get_node(LLM_NODE)


func _load_into_ui() -> void:
	var s: Dictionary = _llm().get_settings()
	_key_edit.text = str(s.get("api_key", ""))
	_url_edit.text = str(s.get("base_url", ""))
	_model_edit.text = str(s.get("model", ""))
	_temp_edit.value = float(s.get("temperature", 0.8))


func _collect() -> Dictionary:
	return {
		"api_key": _key_edit.text.strip_edges(),
		"base_url": _url_edit.text.strip_edges().trim_suffix("/"),
		"model": _model_edit.text.strip_edges(),
		"temperature": _temp_edit.value,
	}


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _on_save() -> void:
	var data := _collect()
	if data["base_url"] == "" or data["model"] == "":
		_set_status("Base URL 和模型不能为空。", Color(1.0, 0.6, 0.5))
		return
	_llm().save_settings(data)
	settings_saved.emit()
	if data["api_key"] == "" and OS.get_environment("DEEPSEEK_API_KEY") == "":
		_set_status("已保存，但未配置 API Key，将使用离线台词。", Color(1.0, 0.78, 0.45))
	else:
		_set_status("已保存 ✓", Color(0.55, 0.9, 0.6))
	hint.emit("设置已保存")
	await get_tree().create_timer(0.5).timeout
	if _status.text.begins_with("已保存"):
		hide()


func _on_test() -> void:
	# 测试的是当前界面里的值（即使还没点保存）
	_llm().save_settings(_collect())
	_test_btn.disabled = true
	_save_btn.disabled = true
	_set_status("正在请求模型……", Color(0.75, 0.8, 0.9))
	var res: Dictionary = await _llm().test_connection()
	_test_btn.disabled = false
	_save_btn.disabled = false
	if res.get("ok", false):
		_set_status("连接成功，模型回复：%s" % str(res.get("speech", "")), Color(0.55, 0.9, 0.6))
	else:
		_set_status("连接失败：%s" % str(res.get("reason", "未知错误")), Color(1.0, 0.6, 0.5))
