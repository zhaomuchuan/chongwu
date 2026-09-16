class_name PetBrainEngine
extends Node
## 确定性规则引擎：交互 → 数值变化；表情推导；性格 → 自然语言描述。
## 这是「数值不交给 LLM」的核心 —— 所有变化都是本地、可解释、可测试的计算。

@onready var PetState := get_node("/root/PetState") as PetStateStore

# 数值结算完成后广播给表现层（3D 宠物动画）。数值与表现分离：表现只能听信号，不能改数值。
signal interaction_applied(kind: String)
signal chat_sentiment_applied(kind: String, intensity: float)

const LOW := 38.0
const HIGH := 62.0  # 维度高低阈值


var last_interaction_msec := 0   # 最近一次交互时间，供调度器判断是否被冷落

# 一次交互 → 一次确定性数值变化 + 记忆 + 日志
# 维度分工：摸头→亲昵/温顺，喂食→亲昵，安抚→温顺/勇敢，聊天→好奇，玩耍→活泼/勇敢，冷落→活泼/亲昵下降
func apply_interaction(kind: String) -> void:
	var memory := ""
	var log := ""
	match kind:
		"pet":
			PetState.add_trust(2.0)
			PetState.add_personality("affection", 1.0)
			PetState.add_personality("gentle", 0.4)
			PetState.add_mood(6.0)
			memory = "主人摸了摸我的头，好舒服。"
			log = "被摸头 · 亲昵+1 温顺+0.4 心情+6"
		"feed":
			PetState.set_hunger(100.0)
			PetState.add_energy(10.0)
			PetState.add_trust(3.0)
			PetState.add_personality("affection", 0.5)
			PetState.add_mood(4.0)
			memory = "主人给我喂了好吃的，肚子饱饱的。"
			log = "被喂食 · 信任+3 亲昵+0.5 心情+4 精力+10"
		"comfort":
			PetState.add_mood(8.0)
			PetState.add_trust(1.0)
			PetState.add_energy(4.0)
			PetState.add_personality("gentle", 0.6)
			PetState.add_personality("brave", 0.4)   # 被安抚、获得安全感 → 更勇敢
			memory = "主人温柔地安抚我，心情平复了。"
			log = "被安抚 · 温顺+0.6 勇敢+0.4 心情+8 精力+4"
		"play":
			# 精力不足时玩不动，只有少量心情收益
			if PetState.energy < 20.0:
				PetState.add_mood(2.0)
				memory = "我太累了，没力气和主人玩。"
				log = "想玩耍但精力不足 · 心情+2"
			else:
				PetState.add_mood(10.0)
				PetState.add_trust(1.0)
				PetState.add_personality("lively", 1.2)
				PetState.add_personality("brave", 0.5)
				PetState.add_energy(-12.0)
				PetState.add_hunger(-6.0)
				memory = "我和主人一起玩耍，跑跳得好开心！"
				log = "玩耍 · 活泼+1.2 勇敢+0.5 心情+10 精力-12"
		"ignore":
			PetState.add_mood(-4.0)
			PetState.add_personality("affection", -0.5)
			PetState.add_personality("lively", -0.5)
			memory = "主人好久没理我了……"
			log = "被冷落 · 亲昵-0.5 活泼-0.5 心情-4"
		_:
			return
	_sleeping = false   # 被主人互动 = 醒过来
	last_interaction_msec = Time.get_ticks_msec()
	PetState.add_memory(memory)
	PetState.add_log(log)
	PetState.commit()
	interaction_applied.emit(kind)


# ---- 聊天情感 → 性格 ----
# LLM 只负责把主人的话归类成情感标签，数值变化全部在这里本地计算（「数值不交给 LLM」边界不变）。
# kind: warm 亲昵夸奖 / playful 玩笑打闹 / curious 提问求知 / calm 温和日常 / negative 凶斥冷落 / neutral 中性
const CHAT_KIND_LABELS := {
	"warm": "亲昵",
	"playful": "活泼",
	"curious": "好奇",
	"calm": "温顺",
	"negative": "凶斥",
	"neutral": "中性",
}

func apply_chat_sentiment(kind: String, intensity: float = 0.5) -> void:
	intensity = clampf(intensity, 0.0, 1.0)
	if not CHAT_KIND_LABELS.has(kind):
		kind = "neutral"
	var memory := ""
	var log := ""
	match kind:
		"warm":
			PetState.add_personality("affection", 1.2 * intensity)
			PetState.add_personality("gentle", 0.3 * intensity)
			PetState.add_trust(1.0)
			PetState.add_mood(4.0 * intensity)
			memory = "主人对我说了很温柔的话，我更喜欢主人了。"
			log = "亲昵聊天 · 亲昵+%.1f 信任+1 心情+%.0f" % [1.2 * intensity, 4.0 * intensity]
		"playful":
			PetState.add_personality("lively", 1.0 * intensity)
			PetState.add_personality("brave", 0.2 * intensity)
			PetState.add_mood(5.0 * intensity)
			memory = "主人和我开玩笑，好有意思！"
			log = "玩笑打闹 · 活泼+%.1f 心情+%.0f" % [1.0 * intensity, 5.0 * intensity]
		"curious":
			PetState.add_personality("curious", 1.0 * intensity)
			PetState.add_personality("lively", 0.2 * intensity)
			PetState.add_mood(2.0 * intensity)
			memory = "主人跟我讲了我不知道的事情，好想多听听。"
			log = "求知话题 · 好奇+%.1f" % (1.0 * intensity)
		"calm":
			PetState.add_personality("gentle", 0.5 * intensity)
			PetState.add_mood(1.5 * intensity)
			memory = "主人平静地和我待了一会儿，很安心。"
			log = "温和日常 · 温顺+%.1f" % (0.5 * intensity)
		"negative":
			PetState.add_personality("affection", -1.0 * intensity)
			PetState.add_personality("lively", -0.6 * intensity)
			PetState.add_trust(-1.0)
			PetState.add_mood(-6.0 * intensity)
			memory = "主人生气了，说了让我难过的话……"
			log = "被凶斥 · 亲昵-%.1f 信任-1 心情-%.0f" % [1.0 * intensity, 6.0 * intensity]
		_:
			PetState.add_personality("curious", 0.15)
			memory = "主人和我聊了些平常的事。"
			log = "日常聊天 · 好奇+0.2"
	_sleeping = false
	PetState.add_memory(memory)
	PetState.add_log(log)
	PetState.commit()
	chat_sentiment_applied.emit(kind, intensity)


# ---- 道具使用：消耗一个背包道具 → 确定性数值变化 + 对应表演 ----
# reaction 交给宠物视觉层：positive / run / dance / look
const ITEM_USE := {
	"cap": {
		"speech": "叮叮当当！瓶盖滚起来的声音真好听，我能玩一整天！",
		"reaction": "positive",
		"effects": {"mood": 4.0, "persona": {"curious": 0.6}},
	},
	"feather": {
		"speech": "羽毛飘起来啦！看我抓住它——嘿嘿，是不是跑得飞快！",
		"reaction": "run",
		"effects": {"mood": 6.0, "persona": {"lively": 0.8}},
	},
	"stone": {
		"speech": "凉凉滑滑的石子握在爪子里，心里一下就安静下来了。",
		"reaction": "positive",
		"effects": {"mood": 3.0, "persona": {"gentle": 0.5}},
	},
	"dandelion": {
		"speech": "呼——小绒毛们要去哪里旅行呢？我也好想跟着去看看！",
		"reaction": "look",
		"effects": {"mood": 5.0, "persona": {"curious": 0.7, "gentle": 0.3}},
	},
	"leaf": {
		"speech": "红叶子转圈圈，我也转圈圈，我们在跳同一支舞！",
		"reaction": "run",
		"effects": {"mood": 4.0, "persona": {"lively": 0.5}},
	},
	"ribbon": {
		"speech": "把粉丝带戴在身上，主人是不是会更喜欢我一点点？",
		"reaction": "positive",
		"effects": {"mood": 5.0, "trust": 1.0, "persona": {"affection": 0.8}},
	},
	"bell": {
		"speech": "叮铃叮铃！主人你听，我走到哪里，声音就跟到哪里！",
		"reaction": "dance",
		"effects": {"mood": 7.0, "trust": 1.0, "persona": {"lively": 0.7}},
	},
	"key": {
		"speech": "这把钥匙……我好像听到远处有一扇小门，轻轻响了一下！",
		"reaction": "look",
		"effects": {"mood": 10.0, "persona": {"curious": 1.5, "brave": 0.5}},
	},
}


# 使用一件道具：扣除 1 个、结算效果；返回 {ok, name, speech, reaction}
func use_item(item_id: String) -> Dictionary:
	if PetState.item_count(item_id) <= 0:
		return {"ok": false}
	var def: Dictionary = ITEM_USE.get(item_id, {})
	if def.is_empty():
		return {"ok": false}
	_sleeping = false   # 和主人玩道具 = 醒过来
	last_interaction_msec = Time.get_ticks_msec()

	var fx: Dictionary = def.get("effects", {})
	if fx.has("mood"):
		PetState.add_mood(float(fx["mood"]))
	if fx.has("trust"):
		PetState.add_trust(float(fx["trust"]))
	var persona: Dictionary = fx.get("persona", {})
	for dim in persona.keys():
		PetState.add_personality(str(dim), float(persona[dim]))
	PetState.add_item(item_id, -1)

	var parts: Array = []
	if fx.has("mood"):
		parts.append("心情%+.0f" % float(fx["mood"]))
	if fx.has("trust"):
		parts.append("信任%+.0f" % float(fx["trust"]))
	for dim in persona.keys():
		parts.append("%s%+.1f" % [PetState.DIMENSION_LABELS.get(str(dim), str(dim)), float(persona[dim])])
	var item_name: String = PetEventDeck.ITEM_NAMES.get(item_id, item_id)
	PetState.add_memory("主人把【%s】拿给我玩，我开心地用了好久。" % item_name)
	PetState.add_log("使用道具【%s】 · %s" % [item_name, " ".join(parts)])
	PetState.commit()
	return {"ok": true, "name": item_name, "speech": str(def.get("speech", "")), "reaction": str(def.get("reaction", "positive"))}


# 离线兜底：本地关键词情感分析（LLM 不可用时保证聊天仍影响性格）
func analyze_sentiment_text(text: String) -> Dictionary:
	var t := text.to_lower()
	var negative_kw := ["讨厌", "不喜欢", "笨", "滚", "坏", "凶", "骂", "吓", "再不理", "不要你", "丑", "蠢", "傻瓜", "哼", "气死", "白痴"]
	var warm_kw := ["喜欢", "爱你", "乖", "可爱", "摸摸", "抱抱", "亲亲", "想你", "好看", "真棒", "好孩子", "么么", "贴贴", "宝贝"]
	var playful_kw := ["哈哈", "嘿嘿", "嘻嘻", "玩", "游戏", "逗你", "玩笑", "疯", "蹦", "来呀", "抓不到", "略略"]
	var curious_kw := ["为什么", "怎么", "什么是", "是什么", "吗？", "呢？", "？", "告诉", "知道吗", "听说", "哪里", "什么时候", "why", "what", "how"]
	var calm_kw := ["晚安", "早安", "在吗", "陪我", "安静", "慢慢", "休息", "吃饭了吗"]
	var hits := 0
	for kw in negative_kw:
		if t.contains(kw):
			return {"kind": "negative", "intensity": 0.7}
	for kw in warm_kw:
		if t.contains(kw):
			hits += 1
	if hits > 0:
		return {"kind": "warm", "intensity": clampf(0.5 + 0.2 * hits, 0.5, 0.9)}
	for kw in playful_kw:
		if t.contains(kw):
			return {"kind": "playful", "intensity": 0.6}
	for kw in curious_kw:
		if t.contains(kw):
			return {"kind": "curious", "intensity": 0.6}
	for kw in calm_kw:
		if t.contains(kw):
			return {"kind": "calm", "intensity": 0.5}
	return {"kind": "neutral", "intensity": 0.3}


# 睡眠阈值：精力低于此值且不饿时自动打盹，一觉睡到醒来阈值
const SLEEP_BELOW := 25.0
const SLEEP_WAKE := 75.0
const SLEEP_RECOVERY := 4.5   # 每个衰减周期（20s）恢复的精力

var _sleeping := false

func is_sleeping() -> bool:
	return _sleeping

# 周期衰减：心情/性格缓慢回归中性，饥饿随时间下降；精力低时改为睡觉回充。
# 返回 "sleeping" / "woke" / ""，供调度器发提示
func tick_decay() -> String:
	PetState.add_mood((50.0 - PetState.mood) * 0.02)
	PetState.add_hunger(-0.3)
	var status := ""
	if not _sleeping and PetState.energy < SLEEP_BELOW and PetState.hunger >= 30.0:
		_sleeping = true
	if _sleeping:
		if PetState.hunger < 20.0:
			# 饿醒了，继续掉精力
			_sleeping = false
			PetState.add_energy(-0.2)
		else:
			PetState.add_energy(SLEEP_RECOVERY)
			if PetState.energy >= SLEEP_WAKE:
				_sleeping = false
				status = "woke"
			else:
				status = "sleeping"
	else:
		PetState.add_energy(-0.2)
	# 性格不交互会慢慢回到中性（每周期拉近 0.5%），避免单一动作把维度永久顶满
	for dim in PetState.DIMENSIONS:
		var v: float = PetState.personality.get(dim, 50.0)
		PetState.add_personality(dim, (50.0 - v) * 0.005)
	PetState.commit()
	return status


# 表情推导（决定动画 + 兜底台词）
func derive_expression() -> String:
	if PetState.hunger < 25.0:
		return "hungry"
	if PetState.energy < 25.0:
		return "sleepy"
	var m := PetState.mood
	if m >= 72.0:
		return "excited"
	if m >= 58.0:
		return "happy"
	if m >= 42.0:
		return "neutral"
	if m >= 26.0:
		return "sad"
	return "distress"


# 性格 → 自然语言描述（注入 LLM 提示词；LLM 只能读，不能改）
func persona_text() -> String:
	var d := PetState.personality
	var parts: Array = []
	for dim in PetState.DIMENSIONS:
		var v: float = d.get(dim, 50.0)
		parts.append("%s%s" % [PetState.DIMENSION_LABELS[dim], _level_word(v)])
	return "你是一只叫「%s」的%s，性格：%s。当前%s，信任值%.0f/100，饱食度%.0f/100。" % [
		PetState.pet_name,
		PetState.species,
		"、".join(parts),
		_mood_word(PetState.mood),
		PetState.trust,
		PetState.hunger,
	]


func _level_word(v: float) -> String:
	if v >= HIGH:
		return "偏高"
	if v <= LOW:
		return "偏低"
	return "中等"


func _mood_word(m: float) -> String:
	if m >= 72.0:
		return "心情非常开心"
	if m >= 58.0:
		return "心情不错"
	if m >= 42.0:
		return "心情平静"
	if m >= 26.0:
		return "心情有点低落"
	return "心情很差"
