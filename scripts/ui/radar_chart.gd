extends Control
## 性格五维雷达图。

@onready var PetState := get_node("/root/PetState") as PetStateStore

@export var grid_color := Color(0.02, 0.85, 0.91, 0.16)
@export var axis_color := Color(0.02, 0.85, 0.91, 0.30)
@export var fill_color := Color(1.0, 0.165, 0.43, 0.28)
@export var line_color := Color(1.0, 0.165, 0.43)
@export var text_color := Color(0.02, 0.85, 0.91)
@export var node_color := Color(0.05, 0.95, 1.0)


func _ready() -> void:
	PetState.state_changed.connect(queue_redraw)


func _draw() -> void:
	var center := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 34.0
	var dims := PetState.DIMENSIONS
	var labels := PetState.DIMENSION_LABELS
	var n := dims.size()

	# 底板
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.028, 0.075, 0.72), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.165, 0.43, 0.4), false, 1.0)

	# 网格环
	for ring in [0.25, 0.5, 0.75, 1.0]:
		var pts := PackedVector2Array()
		for i in n:
			pts.append(center + Vector2.from_angle(_angle(i, n)) * (r * ring))
		pts.append(pts[0])
		draw_polyline(pts, grid_color, 1.0, true)

	# 轴线
	for i in n:
		draw_line(center, center + Vector2.from_angle(_angle(i, n)) * r, axis_color, 1.0, true)

	# 数据多边形
	var data := PackedVector2Array()
	for i in n:
		var v: float = PetState.personality.get(dims[i], 50.0)
		data.append(center + Vector2.from_angle(_angle(i, n)) * (r * v / 100.0))
	data.append(data[0])
	draw_colored_polygon(data, fill_color)
	draw_polyline(data, Color(line_color, 0.35), 6.0, true)   # 辉光层
	draw_polyline(data, line_color, 2.0, true)
	for i in n:
		draw_circle(data[i], 3.0, node_color)

	# 标签
	var font := ThemeDB.fallback_font
	for i in n:
		var v: float = PetState.personality.get(dims[i], 50.0)
		var p := center + Vector2.from_angle(_angle(i, n)) * (r + 16.0)
		draw_string(font, p - Vector2(16, 4), "%s %d" % [labels[dims[i]], int(v)], HORIZONTAL_ALIGNMENT_CENTER, 32, 12, text_color)


func _angle(i: int, n: int) -> float:
	return -PI * 0.5 + TAU * float(i) / float(n)
