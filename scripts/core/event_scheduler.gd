class_name EventScheduler
extends Node
## 事件调度器：定时衰减、宠物主动搭话（带频率上限）、随机本地小事件（不耗 token）。

@onready var PetState := get_node("/root/PetState") as PetStateStore
@onready var PetBrain := get_node("/root/PetBrain") as PetBrainEngine

signal proactive_chat
signal local_event(text: String)
signal needs_attention(text: String)
signal special_event(event: Dictionary)

const DECAY_INTERVAL := 20.0
const PROACTIVE_MIN := 150.0
const PROACTIVE_MAX := 300.0
const RANDOM_EVENT_MIN := 40.0
const RANDOM_EVENT_MAX := 100.0
const SPECIAL_EVENT_MIN := 80.0   # 特殊事件（发现/小倒霉，含道具）间隔
const SPECIAL_EVENT_MAX := 160.0
const SPECIAL_FIRST_DELAY := 45.0
const MAX_PROACTIVE := 3   # 单次运行主动搭话上限，防烧 token
const NEGLECT_MS := 180000 # 超过 3 分钟没有交互 → 判定一次冷落

var _deck := PetEventDeck.new()

var _proactive_count := 0
var _was_sleeping := false


func _ready() -> void:
	_decay_loop()
	_proactive_loop()
	_random_loop()
	_special_event_loop()
	# 任何交互都算把它叫醒
	PetBrain.interaction_applied.connect(_on_woken)
	PetBrain.chat_sentiment_applied.connect(_on_woken_chat)


func _on_woken(_kind: String) -> void:
	_was_sleeping = false


func _on_woken_chat(_kind: String, _intensity: float) -> void:
	_was_sleeping = false


func _decay_loop() -> void:
	while true:
		await get_tree().create_timer(DECAY_INTERVAL).timeout
		var sleep_status: String = PetBrain.tick_decay()
		if sleep_status == "sleeping" and not _was_sleeping:
			_was_sleeping = true
			local_event.emit("%s困得撑不住，蜷成一团打盹了，体力正在慢慢恢复……" % PetState.pet_name)
		elif sleep_status == "woke":
			_was_sleeping = false
			local_event.emit("%s睡醒了，又变得精力充沛！" % PetState.pet_name)
		elif sleep_status != "sleeping" and PetState.energy >= PetBrain.SLEEP_WAKE:
			_was_sleeping = false
		_check_needs()
		_check_neglect()


# 长时间无交互：活泼/亲昵下降，并提醒主人（不调用 LLM，不耗 token）
func _check_neglect() -> void:
	if PetBrain.last_interaction_msec == 0:
		return
	if Time.get_ticks_msec() - PetBrain.last_interaction_msec >= NEGLECT_MS:
		PetBrain.apply_interaction("ignore")
		local_event.emit("%s有点蔫蔫的，好像被冷落了……" % PetState.pet_name)


func _proactive_loop() -> void:
	while true:
		await get_tree().create_timer(randf_range(PROACTIVE_MIN, PROACTIVE_MAX)).timeout
		if _proactive_count < MAX_PROACTIVE:
			_proactive_count += 1
			proactive_chat.emit()


func _random_loop() -> void:
	while true:
		await get_tree().create_timer(randf_range(RANDOM_EVENT_MIN, RANDOM_EVENT_MAX)).timeout
		local_event.emit(_random_text())


# 特殊随机事件：本地结算心情/信任/五维/道具，毛球会用气泡播报发现
func _special_event_loop() -> void:
	await get_tree().create_timer(SPECIAL_FIRST_DELAY).timeout
	while true:
		var event: Dictionary = _deck.roll_and_apply(PetState)
		if not event.is_empty():
			special_event.emit(event)
		await get_tree().create_timer(randf_range(SPECIAL_EVENT_MIN, SPECIAL_EVENT_MAX)).timeout


func _check_needs() -> void:
	if PetState.hunger < 25.0:
		needs_attention.emit("我饿了……")
	elif PetState.mood < 25.0:
		needs_attention.emit("我有点难过……")


func _random_text() -> String:
	var pool := [
		"%s在窗边安静地发呆。" % PetState.pet_name,
		"%s打了个滚，露出肚皮。" % PetState.pet_name,
		"%s追着自己的尾巴转圈。" % PetState.pet_name,
		"%s竖起耳朵，好奇地东张西望。" % PetState.pet_name,
	]
	return pool[randi() % pool.size()]
