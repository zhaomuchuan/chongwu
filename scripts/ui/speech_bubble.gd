extends Control
## 宠物头顶的对话气泡：直角霓虹框 + 指向宠物的小尖角，按文字自适应高度。

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const TEXT_COLOR := Color(0.93, 0.97, 1.0)

const MAX_WIDTH := 360.0
const PAD_X := 14.0
const PAD_Y := 10.0
const FONT_SIZE := 15

var _message := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2.ZERO
	visible = false


# 设置台词并按宽度自适应换行；返回气泡尺寸
func set_message(text: String) -> Vector2:
	_message = text
	var text_h: float = _make_paragraph(text).get_size().y
	size = Vector2(MAX_WIDTH, text_h + PAD_Y * 2.0)
	position = Vector2(-MAX_WIDTH * 0.5, -size.y)
	visible = true
	modulate.a = 1.0
	queue_redraw()
	return size


func _make_paragraph(text: String) -> TextParagraph:
	var para := TextParagraph.new()
	para.add_string(text, ThemeDB.fallback_font, FONT_SIZE)
	para.width = MAX_WIDTH - PAD_X * 2.0
	return para


func _draw() -> void:
	if _message == "":
		return
	var rect := Rect2(Vector2.ZERO, size)

	# 尖角（朝下，指向宠物）
	var tri := PackedVector2Array([
		Vector2(size.x * 0.5 - 11.0, size.y - 1.0),
		Vector2(size.x * 0.5 + 11.0, size.y - 1.0),
		Vector2(size.x * 0.5, size.y + 10.0),
	])
	draw_colored_polygon(tri, Color(0.035, 0.028, 0.075, 0.94))
	draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color(NEON_CYAN, 0.7), 1.0, true)

	# 底板 + 青边 + 左上品红装饰角
	draw_rect(rect, Color(0.035, 0.028, 0.075, 0.94), true)
	draw_rect(rect, Color(NEON_CYAN, 0.75), false, 1.0)
	draw_line(Vector2(0, 0), Vector2(20, 0), NEON_PINK, 2.0, true)
	draw_line(Vector2(0, 0), Vector2(0, 20), NEON_PINK, 2.0, true)

	# 文字（TextParagraph 整体绘制，自动换行）
	var para := _make_paragraph(_message)
	para.draw(get_canvas_item(), Vector2(PAD_X, PAD_Y), TEXT_COLOR)
