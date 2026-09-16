extends Control
## 赛博朋克背景：细网格 + CRT 扫描纹 + 移动扫描光带 + 闪烁数据点。

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.16, 0.43)
const GRID := 40.0

var _t := 0.0
var _stars: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 用确定性伪随机生成固定的「数据点」，避免闪烁乱动
	var rng := RandomNumberGenerator.new()
	rng.seed = 2077
	for i in 42:
		_stars.append({
			"p": Vector2(randf_from(rng), randf_from(rng)),
			"pink": rng.randf() < 0.35,
			"phase": rng.randf() * TAU,
			"speed": rng.randf_range(0.8, 2.4),
		})


func randf_from(rng: RandomNumberGenerator) -> float:
	return rng.randf()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var s := size

	# 细网格
	var grid_col := Color(NEON_CYAN, 0.055)
	var x := GRID
	while x < s.x:
		draw_line(Vector2(x, 0), Vector2(x, s.y), grid_col, 1.0, true)
		x += GRID
	var y := GRID
	while y < s.y:
		draw_line(Vector2(0, y), Vector2(s.x, y), grid_col, 1.0, true)
		y += GRID

	# CRT 横纹
	var scan_col := Color(0, 0, 0, 0.10)
	var sy := 3.0
	while sy < s.y:
		draw_line(Vector2(0, sy), Vector2(s.x, sy), scan_col, 1.0, true)
		sy += 3.0

	# 闪烁数据点
	for st in _stars:
		var a := 0.25 + 0.55 * (0.5 + 0.5 * sin(_t * st.speed + st.phase))
		var c := (NEON_PINK if st.pink else NEON_CYAN)
		draw_circle(Vector2(st.p.x * s.x, st.p.y * s.y), 1.4, Color(c, a))

	# 移动扫描光带
	var band_y := fmod(_t * 70.0, s.y + 240.0) - 120.0
	for i in 5:
		draw_rect(Rect2(0, band_y + i * 10.0, s.x, 1.0), Color(NEON_CYAN, 0.05 - i * 0.008), true)

	# 顶部 / 底部霓虹辉光线
	draw_rect(Rect2(0, 0, s.x, 1.5), Color(NEON_PINK, 0.35), true)
	draw_rect(Rect2(0, s.y - 1.5, s.x, 1.5), Color(NEON_CYAN, 0.30), true)
