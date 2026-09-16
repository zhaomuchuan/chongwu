extends Control
## 日期 / 时间 / 天气面板（赛博朋克风）。
## 时间取系统时钟每秒刷新；天气用免 Key 接口：ipapi.co 定位 → open-meteo 查询。
## 网络不可用时退化为按日期确定性推算的本地天气，不报错、不阻塞。

const NEON_CYAN := Color(0.02, 0.85, 0.91)
const NEON_PINK := Color(1.0, 0.165, 0.43)
const TEXT_DIM := Color(0.62, 0.72, 0.82)

const WEEKDAYS := ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

# open-meteo WMO 天气代码 → [中文名, 主题色]
const WMO := {
	0: ["晴", Color(1.0, 0.78, 0.25)],
	1: ["少云", Color(1.0, 0.85, 0.45)],
	2: ["多云", Color(0.62, 0.72, 0.82)],
	3: ["阴", Color(0.55, 0.60, 0.68)],
	45: ["雾", Color(0.70, 0.74, 0.80)],
	48: ["雾凇", Color(0.70, 0.74, 0.80)],
	51: ["小雨", Color(0.45, 0.75, 0.95)],
	53: ["中雨", Color(0.35, 0.65, 0.92)],
	55: ["大雨", Color(0.25, 0.55, 0.88)],
	61: ["小雨", Color(0.45, 0.75, 0.95)],
	63: ["中雨", Color(0.35, 0.65, 0.92)],
	65: ["大雨", Color(0.25, 0.55, 0.88)],
	66: ["冻雨", Color(0.60, 0.85, 0.95)],
	67: ["冻雨", Color(0.60, 0.85, 0.95)],
	71: ["小雪", Color(0.82, 0.90, 1.0)],
	73: ["中雪", Color(0.75, 0.85, 1.0)],
	75: ["大雪", Color(0.68, 0.80, 1.0)],
	77: ["雪粒", Color(0.75, 0.85, 1.0)],
	80: ["阵雨", Color(0.40, 0.70, 0.93)],
	81: ["阵雨", Color(0.30, 0.60, 0.90)],
	82: ["暴雨", Color(0.20, 0.48, 0.85)],
	85: ["阵雪", Color(0.75, 0.85, 1.0)],
	86: ["阵雪", Color(0.68, 0.80, 1.0)],
	95: ["雷阵雨", Color(0.75, 0.60, 0.95)],
	96: ["雷阵雨冰雹", Color(0.70, 0.55, 0.92)],
	99: ["雷阵雨冰雹", Color(0.70, 0.55, 0.92)],
}

# 常见城市英文名 → 中文（ipwho.is 返回英文名；不在表里的直接显示原名）
const CITY_CN := {
	"Beijing": "北京", "Shanghai": "上海", "Guangzhou": "广州", "Shenzhen": "深圳",
	"Hangzhou": "杭州", "Nanjing": "南京", "Chengdu": "成都", "Wuhan": "武汉",
	"Xi'an": "西安", "Chongqing": "重庆", "Tianjin": "天津", "Suzhou": "苏州",
	"Qingdao": "青岛", "Xiamen": "厦门", "Changsha": "长沙", "Zhengzhou": "郑州",
	"Shenyang": "沈阳", "Harbin": "哈尔滨", "Kunming": "昆明", "Dalian": "大连",
	"Jinan": "济南", "Ningbo": "宁波", "Fuzhou": "福州", "Hefei": "合肥",
}

# 离线兜底：按月份给一个合理气温区间，天气按日期哈希选（同一天内稳定）
const FALLBACK_WEATHERS := [["晴", Color(1.0, 0.78, 0.25)], ["多云", Color(0.62, 0.72, 0.82)], ["阴", Color(0.55, 0.60, 0.68)], ["小雨", Color(0.45, 0.75, 0.95)]]

var _weather_name := "····"
var _weather_color: Color = TEXT_DIM
var _temperature := 0
var _city := "定位中"
var _weather_online := false

var _loc_http: HTTPRequest
var _wx_http: HTTPRequest


func _ready() -> void:
	_loc_http = HTTPRequest.new()
	_loc_http.timeout = 8.0
	add_child(_loc_http)
	_loc_http.request_completed.connect(_on_location_done)

	_wx_http = HTTPRequest.new()
	_wx_http.timeout = 8.0
	add_child(_wx_http)
	_wx_http.request_completed.connect(_on_weather_done)

	_apply_fallback_weather()   # 先立刻有东西看；网络成功后覆盖
	_fetch_location()
	set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.028, 0.075, 0.82), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(NEON_CYAN, 0.45), false, 1.0)
	# 左上角品红装饰角（与状态面板同款）
	draw_line(Vector2(0, 0), Vector2(22, 0), NEON_PINK, 2.0, true)
	draw_line(Vector2(0, 0), Vector2(0, 22), NEON_PINK, 2.0, true)

	var now: Dictionary = Time.get_datetime_dict_from_system()
	draw_string(font, Vector2(12, 22), "系统时间 // DATE & WEATHER", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, NEON_PINK)

	var hh := "%02d" % now.get("hour", 0)
	var mm := "%02d" % now.get("minute", 0)
	var ss := "%02d" % now.get("second", 0)
	var clock := "%s:%s:%s" % [hh, mm, ss]
	draw_string(font, Vector2(10, 60), clock, HORIZONTAL_ALIGNMENT_LEFT, -1, 32, NEON_CYAN)

	var date := "%04d.%02d.%02d %s" % [now.get("year", 0), now.get("month", 0), now.get("day", 0), WEEKDAYS[int(now.get("weekday", 0))]]
	draw_string(font, Vector2(12, 84), date, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_DIM)
	var date_w: float = font.get_string_size(date, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x

	# 右侧天气：◆ 名  温度 · 城市
	var loc := _city
	var wx := "%s  %d° · %s" % [_weather_name, _temperature, loc]
	var wx_w: float = font.get_string_size(wx, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var wx_x := size.x - wx_w - 26.0
	draw_string(font, Vector2(wx_x, 84), wx, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _weather_color)
	draw_string(font, Vector2(wx_x - 18.0, 84), "◆", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, _weather_color)
	# 日期与天气之间的竖向分隔线
	draw_line(Vector2(maxf(date_w + 28.0, wx_x - 24.0), 70), Vector2(maxf(date_w + 28.0, wx_x - 24.0), 88), Color(NEON_CYAN, 0.35), 1.0)


# ---- 天气获取（全免 Key，失败静默走本地兜底）----

func _fetch_location() -> void:
	# ipwho.is：HTTPS、免 Key、国内可达（ipapi.co 被 Cloudflare 拦、ip-api 免费版仅 http）
	var err := _loc_http.request("https://ipwho.is/?fields=success,city,latitude,longitude")
	if err != OK:
		_apply_fallback_weather()


func _on_location_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("clock_panel: 定位请求失败 result=%d code=%d" % [result, code])
		_apply_fallback_weather()
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not bool(json.get("success", false)):
		_apply_fallback_weather()
		return
	var lat: float = float(json.get("latitude", 0.0))
	var lon: float = float(json.get("longitude", 0.0))
	var raw_city := str(json.get("city", "未知地区"))
	_city = CITY_CN.get(raw_city, raw_city)
	var url := "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code" % [lat, lon]
	if _wx_http.request(url) != OK:
		_apply_fallback_weather()


func _on_weather_done(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_apply_fallback_weather()
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("current"):
		_apply_fallback_weather()
		return
	var cur: Dictionary = json["current"]
	var code: Array = WMO.get(int(cur.get("weather_code", 2)), ["多云", TEXT_DIM])
	_weather_name = str(code[0])
	_weather_color = code[1]
	_temperature = roundi(float(cur.get("temperature_2m", 0.0)))
	_weather_online = true


# 同一天内结果稳定的本地兜底天气（按月份估温）
func _apply_fallback_weather() -> void:
	if _weather_online:
		return
	var now: Dictionary = Time.get_datetime_dict_from_system()
	var month: int = int(now.get("month", 6))
	var day_seed: int = int(now.get("year", 0)) * 372 + month * 31 + int(now.get("day", 0))
	var w: Array = FALLBACK_WEATHERS[day_seed % FALLBACK_WEATHERS.size()]
	_weather_name = str(w[0])
	_weather_color = w[1]
	# 北半球月度基准气温的粗糙正弦曲线，约 -3（1月）~ 29（7月）
	var base := 13.0 + 16.0 * sin((float(month) - 4.0) / 12.0 * TAU)
	_temperature = roundi(base + float((day_seed * 7) % 7) - 3.0)
	_city = "本地推演"
