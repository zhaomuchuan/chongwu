extends Control
## 状态面板：心情 / 信任 / 饱食 / 精力 条 + 名字与当前表情（赛博朋克风）。

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const NEON_GREEN := Color(0.224, 1.0, 0.314)
const NEON_AMBER := Color(1.0, 0.78, 0.25)


func _ready() -> void:
	PetState.state_changed.connect(queue_redraw)
	set_process(true)


# 精力过低时能量条闪烁需要持续重绘
func _process(_delta: float) -> void:
	if PetState.energy < 20.0 or PetBrain.is_sleeping():
		queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font

	# 面板底板 + 青色描边
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.028, 0.075, 0.82), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(NEON_CYAN, 0.45), false, 1.0)
	# 左上角品红装饰角
	draw_line(Vector2(0, 0), Vector2(22, 0), NEON_PINK, 2.0, true)
	draw_line(Vector2(0, 0), Vector2(0, 22), NEON_PINK, 2.0, true)

	var state := _expr_cn()
	if PetBrain.is_sleeping():
		state += " · 睡眠中 zZ"
	draw_string(font, Vector2(12, 26), "%s // %s" % [PetState.pet_name, state], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, NEON_PINK)

	var y := 38.0
	_draw_bar(font, y, "心情", PetState.mood, NEON_PINK)
	y += 23.0
	_draw_bar(font, y, "信任", PetState.trust, NEON_CYAN)
	y += 23.0
	_draw_bar(font, y, "饱食", PetState.hunger, NEON_GREEN)
	y += 23.0
	# 精力过低（玩不动 / 即将入睡）时整条变暗并呼吸闪烁提示
	_draw_bar(font, y, "精力", PetState.energy, NEON_AMBER, PetState.energy < 20.0)


func _draw_bar(font: Font, y: float, label: String, value: float, color: Color, low_dim: bool = false) -> void:
	draw_string(font, Vector2(12, y + 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.70, 0.80, 0.88))
	var bx := 46.0
	# 右端留出数值宽度
	var num_text := "%d" % roundi(value)
	var num_w: float = font.get_string_size(num_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var bw := size.x - bx - num_w - 18.0
	draw_rect(Rect2(bx, y + 2, bw, 12), Color(0, 0, 0, 0.55), true)
	var fill := (bw - 2.0) * clampf(value / 100.0, 0.0, 1.0)
	var bar_color: Color = color if not low_dim else Color(color, 0.55 + 0.45 * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)))
	if fill > 0.0:
		# 外发光 + 实心填充
		draw_rect(Rect2(bx + 1, y + 3, fill, 10), Color(bar_color, 0.35), true)
		draw_rect(Rect2(bx + 1, y + 5, fill, 6), bar_color, true)
	draw_rect(Rect2(bx, y + 2, bw, 12), Color(color, 0.5), false)
	# 右侧数值
	draw_string(font, Vector2(bx + bw + 6, y + 12), num_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)


func _expr_cn() -> String:
	match PetBrain.derive_expression():
		"excited":
			return "兴奋"
		"happy":
			return "开心"
		"sad":
			return "难过"
		"distress":
			return "低落"
		"hungry":
			return "饿了"
		"sleepy":
			return "困了"
		_:
			return "平静"
