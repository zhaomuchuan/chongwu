class_name PetStateStore
extends Node
## 宠物的全部本地状态：性格五维、情绪、信任、记忆、成长日志。
## 只存数据 + 持久化，演化规则在 PetBrain —— 「数值不交给 LLM」的第一道边界。

signal state_changed
signal memory_added(entry: String)
signal log_added(entry: Dictionary)

const SAVE_PATH := "user://pet_state.json"

# 性格五维（0~100）
const DIMENSIONS := ["lively", "affection", "brave", "gentle", "curious"]
const DIMENSION_LABELS := {
	"lively": "活泼",
	"affection": "亲昵",
	"brave": "勇敢",
	"gentle": "温顺",
	"curious": "好奇",
}

var pet_name := "毛球"
var species := "兔子"

var personality: Dictionary = {}
var mood := 50.0        # 心情 0~100
var trust := 20.0       # 信任 0~100
var hunger := 80.0      # 饱食 0~100
var energy := 80.0      # 精力 0~100
var feed_charges := 10.0     # 剩余口粮份数（浮点用于随时间累积），上限/恢复节奏在 PetBrain
var feed_tick_unix := 0.0    # 上次结算口粮恢复的真实时间戳（秒），0 = 尚未初始化

var recent_memories: Array = []   # 最近交互记忆摘要
var memory_summary := ""          # 长期记忆摘要（后续可由 LLM 蒸馏）
var growth_log: Array = []        # 成长日志
var inventory: Dictionary = {}    # 背包：{item_id: 数量}，随机事件中获得 / 丢失
var unlocked_traits: Array = []   # 已觉醒的性格特质（维度 id），用于只播报一次觉醒
var fish_dex: Array = []          # 数据海已收录的鱼 id
var fishing_tick_unix := 0.0      # 上次钓鱼结算的真实时间戳（秒），用于离线鱼汛


func _ready() -> void:
	_init_defaults()
	load_state()


func _init_defaults() -> void:
	personality = {
		"lively": 50.0,
		"affection": 50.0,
		"brave": 50.0,
		"gentle": 50.0,
		"curious": 50.0,
	}


func reset() -> void:
	_init_defaults()
	mood = 50.0
	trust = 20.0
	hunger = 80.0
	energy = 80.0
	feed_charges = 10.0
	feed_tick_unix = 0.0
	recent_memories.clear()
	memory_summary = ""
	growth_log.clear()
	inventory.clear()
	unlocked_traits.clear()
	fish_dex.clear()
	fishing_tick_unix = 0.0
	commit()


# ---- 数值安全写入（全部 clamp 到 0~100）----
func set_personality(dim: String, value: float) -> void:
	personality[dim] = clampf(value, 0.0, 100.0)


func add_personality(dim: String, delta: float) -> void:
	set_personality(dim, float(personality.get(dim, 50.0)) + delta)


func add_mood(delta: float) -> void:
	mood = clampf(mood + delta, 0.0, 100.0)


func add_trust(delta: float) -> void:
	trust = clampf(trust + delta, 0.0, 100.0)


func set_hunger(value: float) -> void:
	hunger = clampf(value, 0.0, 100.0)


func add_hunger(delta: float) -> void:
	set_hunger(hunger + delta)


func add_energy(delta: float) -> void:
	energy = clampf(energy + delta, 0.0, 100.0)


# ---- 背包 ----
func add_item(item_id: String, count: int = 1) -> void:
	inventory[item_id] = int(inventory.get(item_id, 0)) + count
	if int(inventory[item_id]) <= 0:
		inventory.erase(item_id)


func item_count(item_id: String) -> int:
	return int(inventory.get(item_id, 0))


# ---- 记忆 ----
func add_memory(entry: String) -> void:
	recent_memories.append(entry)
	if recent_memories.size() > 20:
		recent_memories.pop_front()
	memory_added.emit(entry)


func add_log(event: String) -> void:
	var entry := {
		"time": Time.get_datetime_string_from_system(),
		"event": event,
	}
	growth_log.append(entry)
	if growth_log.size() > 200:
		growth_log.pop_front()
	log_added.emit(entry)


# ---- 持久化 ----
func commit() -> void:
	_save()
	state_changed.emit()


func _save() -> void:
	var data := {
		"pet_name": pet_name,
		"species": species,
		"personality": personality,
		"mood": mood,
		"trust": trust,
		"hunger": hunger,
		"energy": energy,
		"feed_charges": feed_charges,
		"feed_tick_unix": feed_tick_unix,
		"recent_memories": recent_memories,
		"memory_summary": memory_summary,
		"growth_log": growth_log,
		"inventory": inventory,
		"unlocked_traits": unlocked_traits,
		"fish_dex": fish_dex,
		"fishing_tick_unix": fishing_tick_unix,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()


func load_state() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if data is Dictionary:
		pet_name = data.get("pet_name", pet_name)
		species = data.get("species", species)
		var p = data.get("personality")
		if p is Dictionary:
			personality = p
		mood = float(data.get("mood", mood))
		trust = float(data.get("trust", trust))
		hunger = float(data.get("hunger", hunger))
		energy = float(data.get("energy", energy))
		# 旧存档没有口粮字段：缺省视为满份（10 份）
		feed_charges = clampf(float(data.get("feed_charges", 10.0)), 0.0, 100.0)
		feed_tick_unix = float(data.get("feed_tick_unix", 0.0))
		var mem = data.get("recent_memories", [])
		if mem is Array:
			recent_memories = _str_array(mem)
		memory_summary = str(data.get("memory_summary", ""))
		var gl = data.get("growth_log", [])
		if gl is Array:
			growth_log = gl
		var tr = data.get("unlocked_traits", [])
		if tr is Array:
			unlocked_traits = _str_array(tr)
		var fd = data.get("fish_dex", [])
		if fd is Array:
			fish_dex = _str_array(fd)
		fishing_tick_unix = float(data.get("fishing_tick_unix", 0.0))
		var inv = data.get("inventory", {})
		if inv is Dictionary:
			inventory = {}
			for k in inv.keys():
				var n := int(inv[k])
				if n > 0:
					inventory[str(k)] = n
		# 形象从狐狸/旧版猫换成兔子：迁移旧存档的物种字段
		if species in ["狐狸", "猫"]:
			species = "兔子"
			_save()
	state_changed.emit()


func _str_array(a: Array) -> Array:
	var out: Array = []
	for x in a:
		out.append(str(x))
	return out
