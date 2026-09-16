extends Node2D
## 程序化绘制的萌系宠物占位。表情/动作由 PetBrain 推导自动切换。
## 后续可整体替换为 Sprite2D + AnimationPlayer（保留 _on_state_changed 接口即可）。

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

@export var body_color: Color = Color(0.95, 0.80, 0.47)
@export var ear_color: Color = Color(0.85, 0.66, 0.36)
@export var outline_color: Color = Color(0.20, 0.14, 0.26)
@export var accent_color: Color = Color(1.0, 0.165, 0.43)   # 霓虹品红（项圈/腮红）
@export var eye_color: Color = Color(0.02, 0.85, 0.91)      # 电子青眼

var _t := 0.0
var _expression := "neutral"
var _blink := 0.0


func _ready() -> void:
	PetState.state_changed.connect(_on_state_changed)
	_on_state_changed()


func _process(delta: float) -> void:
	_t += delta
	_blink -= delta
	if _blink <= 0.0:
		_blink = randf_range(2.0, 5.0)
	queue_redraw()


func _on_state_changed() -> void:
	_expression = PetBrain.derive_expression()


func _draw() -> void:
	var bob := sin(_t * 2.2) * 1.5
	var hop := 0.0
	if _expression == "excited":
		hop = absf(sin(_t * 5.0)) * 4.0
	var oy := -bob - hop

	# 阴影（不动）
	draw_set_transform(Vector2(0, 42))
	draw_circle(Vector2.ZERO, 24.0, Color(0, 0, 0, 0.10))
	draw_set_transform(Vector2(0, oy))

	_draw_tail()
	_draw_body()
	_draw_collar()
	_draw_ears()
	_draw_face()


func _draw_tail() -> void:
	var wiggle := sin(_t * 5.0) * 3.0
	var pts := PackedVector2Array([
		Vector2(22, -2),
		Vector2(30, -10 + wiggle),
		Vector2(36, -16 + wiggle * 2.0),
	])
	draw_polyline(pts, outline_color, 6.0, true)


func _draw_body() -> void:
	draw_circle(Vector2.ZERO, 26.0, body_color)
	draw_arc(Vector2.ZERO, 26.0, 0, TAU, 48, outline_color, 2.0, true)


# 霓虹项圈 + 青色吊牌
func _draw_collar() -> void:
	var center := Vector2(0, 4)
	var radius := 21.0
	draw_arc(center, radius, 0.35, PI - 0.35, 20, Color(accent_color, 0.35), 8.0, true)
	draw_arc(center, radius, 0.35, PI - 0.35, 20, accent_color, 3.0, true)
	var tag_y := center.y + radius - 5.0
	draw_rect(Rect2(-3.5, tag_y, 7.0, 7.0), eye_color, true)
	draw_rect(Rect2(-3.5, tag_y, 7.0, 7.0), outline_color, false, 1.0)


func _draw_ears() -> void:
	var droop := 0.0
	if _expression in ["sad", "distress"]:
		droop = 12.0
	_draw_ear(Vector2(-13, -18), -1, droop)
	_draw_ear(Vector2(13, -18), 1, droop)


func _draw_ear(base: Vector2, side: float, droop: float) -> void:
	var tip := base + Vector2(side * 7.0, -16.0 + droop)
	var p1 := base + Vector2(side * -9.0, 2.0)
	var p2 := base + Vector2(side * 10.0, 4.0)
	draw_colored_polygon(PackedVector2Array([p1, tip, p2]), ear_color)
	draw_polyline(PackedVector2Array([p1, tip, p2]), outline_color, 2.0, true)
	# 耳内霓虹色
	var it := base.lerp(tip, 0.72)
	var i1 := p1.lerp(tip, 0.5)
	var i2 := p2.lerp(tip, 0.5)
	draw_colored_polygon(PackedVector2Array([i1, it, i2]), Color(accent_color, 0.85))


func _draw_face() -> void:
	_draw_eyes()
	_draw_mouth()
	_draw_blush()


func _draw_eyes() -> void:
	var eye_y := -5.0
	var lx := -9.0
	var rx := 9.0
	if _blink < 0.12:
		draw_line(Vector2(lx - 3, eye_y), Vector2(lx + 3, eye_y), eye_color, 2.0, true)
		draw_line(Vector2(rx - 3, eye_y), Vector2(rx + 3, eye_y), eye_color, 2.0, true)
		return
	match _expression:
		"happy", "excited":
			draw_polyline(PackedVector2Array([Vector2(lx - 3.5, eye_y + 1.5), Vector2(lx, eye_y - 2.0), Vector2(lx + 3.5, eye_y + 1.5)]), eye_color, 2.0, true)
			draw_polyline(PackedVector2Array([Vector2(rx - 3.5, eye_y + 1.5), Vector2(rx, eye_y - 2.0), Vector2(rx + 3.5, eye_y + 1.5)]), eye_color, 2.0, true)
		_:
			var dim: float = 0.45 if _expression in ["sad", "distress"] else 1.0
			var col := Color(eye_color.r, eye_color.g, eye_color.b, eye_color.a * dim)
			draw_circle(Vector2(lx, eye_y), 4.6, Color(col, 0.3 * dim))
			draw_circle(Vector2(rx, eye_y), 4.6, Color(col, 0.3 * dim))
			draw_circle(Vector2(lx, eye_y), 3.0, col)
			draw_circle(Vector2(rx, eye_y), 3.0, col)
			draw_circle(Vector2(lx + 1.0, eye_y - 1.0), 1.1, Color.WHITE)
			draw_circle(Vector2(rx + 1.0, eye_y - 1.0), 1.1, Color.WHITE)


func _draw_mouth() -> void:
	var my := 7.0
	match _expression:
		"happy", "excited":
			draw_arc(Vector2(0, my - 3.0), 4.0, 0, PI, 12, outline_color, 2.0, true)
		"sad", "distress":
			draw_arc(Vector2(0, my + 5.0), 4.0, PI, TAU, 12, outline_color, 2.0, true)
		_:
			draw_line(Vector2(-3, my), Vector2(3, my), outline_color, 2.0, true)


func _draw_blush() -> void:
	if _expression in ["happy", "excited"]:
		draw_circle(Vector2(-15, 4), 3.6, Color(accent_color, 0.45))
		draw_circle(Vector2(15, 4), 3.6, Color(accent_color, 0.45))
