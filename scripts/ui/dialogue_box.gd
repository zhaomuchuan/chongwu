extends PanelContainer
## 对话区：宠物台词（打字机效果）+ 输入框 + 发送按钮。

@onready var PetState := get_node("/root/PetState") as PetStateStore

signal send_requested(text: String)

var _log: RichTextLabel
var _input: LineEdit
var _send: Button

var _lines: Array = []        # 已完成行（含 bbcode）
var _prefix := ""             # 当前宠物行的固定前缀（颜色+名字）
var _visible_full := ""       # 当前宠物行待打字的纯文本
var _shown := 0
var _typing := false
var _type_timer := 0.0


func _ready() -> void:
	_build()
	_send.pressed.connect(_on_send)
	_input.text_submitted.connect(_on_submit)


func _process(delta: float) -> void:
	if not _typing:
		return
	_type_timer += delta
	while _type_timer > 0.02 and _typing:
		_type_timer -= 0.02
		_shown += 1
		if _shown >= _visible_full.length():
			_shown = _visible_full.length()
			_lines.append(_prefix + "[color=#ffd9e6]" + _visible_full + "[/color]")
			_visible_full = ""
			_typing = false
		_refresh()


func _build() -> void:
	var NEON_CYAN := Color(0.02, 0.85, 0.91)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.028, 0.075, 0.95)
	sb.border_color = Color(NEON_CYAN, 0.65)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.shadow_color = Color(NEON_CYAN, 0.35)
	sb.shadow_size = 4
	sb.set_content_margin_all(10)
	add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_log)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vbox.add_child(row)

	_input = LineEdit.new()
	_input.placeholder_text = "和它说点什么……（回车发送）"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_line_edit(_input)
	row.add_child(_input)

	_send = Button.new()
	_send.text = "发送 ▸"
	_send.focus_mode = Control.FOCUS_NONE
	_send.add_theme_font_size_override("font_size", 14)
	_send.add_theme_color_override("font_color", NEON_CYAN)
	_send.add_theme_color_override("font_hover_color", Color.WHITE)
	for state in ["normal", "hover", "pressed"]:
		var bsb := StyleBoxFlat.new()
		bsb.set_corner_radius_all(0)
		bsb.content_margin_left = 14
		bsb.content_margin_right = 14
		bsb.set_border_width_all(1)
		bsb.border_color = Color(NEON_CYAN, 0.75)
		match state:
			"normal":
				bsb.bg_color = Color(0.05, 0.07, 0.14, 0.92)
			"hover":
				bsb.bg_color = Color(NEON_CYAN, 0.18)
				bsb.shadow_color = Color(NEON_CYAN, 0.5)
				bsb.shadow_size = 5
			"pressed":
				bsb.bg_color = Color(NEON_CYAN, 0.34)
		_send.add_theme_stylebox_override(state, bsb)
	row.add_child(_send)


func _style_line_edit(le: LineEdit) -> void:
	var NEON_CYAN := Color(0.02, 0.85, 0.91)
	le.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	le.add_theme_color_override("font_placeholder_color", Color(0.45, 0.56, 0.66))
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
		le.add_theme_stylebox_override(state, sb)


func focus_input() -> void:
	_input.grab_focus()


func _on_send() -> void:
	var t := _input.text.strip_edges()
	if t == "":
		return
	send_requested.emit(t)
	_input.clear()


func _on_submit(_t: String) -> void:
	_on_send()


func append_player(text: String) -> void:
	_lines.append("[color=#05d9e8]你 » [/color][color=#cfeef5]%s[/color]" % text)
	_refresh()


func append_pet(text: String) -> void:
	_prefix = "[color=#ff2a6d]%s » [/color]" % PetState.pet_name
	_visible_full = text
	_shown = 0
	_typing = true
	_type_timer = 0.0
	_refresh()


func append_system(text: String) -> void:
	_lines.append("[color=#9d7bff]· %s[/color]" % text)
	_refresh()


func _refresh() -> void:
	var text := "\n".join(_lines)
	if _typing:
		if _lines.size() > 0:
			text += "\n"
		text += _prefix + "[color=#ffd9e6]" + _visible_full.left(_shown) + "[/color]"
	_log.text = text
