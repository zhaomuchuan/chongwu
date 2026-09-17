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

# ---- 口粮：喂食次数有限，按真实时间慢慢恢复（离线也恢复），用完只能等 ----
const MAX_FEED_CHARGES := 10.0   # 最多囤 10 份口粮
const FEED_REGEN_SEC := 1200.0   # 每 20 分钟恢复 1 份
const FEED_HUNGER_GAIN := 35.0   # 每份口粮回的饱食度（不再一口喂满）

# ---- 性格特质：维度达到阈值后觉醒，改变宠物的自主行为（纯本地规则，LLM 不参与）----
const TRAIT_THRESHOLD := 62.0
const TRAIT_FULL := 85.0         # 特质强度饱和点
const TRAITS := {
	"lively": {"name": "活泼好动", "desc": "撒欢更勤快，跑得也更远"},
	"affection": {"name": "黏人精", "desc": "更频繁地主动找你说话"},
	"brave": {"name": "胆大包天", "desc": "不再被黑影和小意外吓到"},
	"gentle": {"name": "软乎乎", "desc": "被摸头时会幸福地蹭你"},
	"curious": {"name": "好奇宝宝", "desc": "更容易发现新奇的东西"},
}


func has_trait(dim: String) -> bool:
	return float(PetState.personality.get(dim, 50.0)) >= TRAIT_THRESHOLD


# 特质强度 0~1：50 为 0、85 饱和。给频率/距离/概率类行为做连续调节
func trait_strength(dim: String) -> float:
	return clampf((float(PetState.personality.get(dim, 50.0)) - 50.0) / (TRAIT_FULL - 50.0), 0.0, 1.0)


func active_traits() -> Array:
	var out: Array = []
	for dim in PetState.DIMENSIONS:
		if has_trait(dim):
			out.append(dim)
	return out


# 首次跨过阈值的维度写入成长日志（每个特质只播报一次，状态持久化）
func check_trait_unlocks() -> void:
	for dim in PetState.DIMENSIONS:
		if has_trait(dim) and not PetState.unlocked_traits.has(dim):
			PetState.unlocked_traits.append(dim)
			var t: Dictionary = TRAITS[dim]
			PetState.add_log("✦ 性格觉醒【%s】 · %s" % [str(t["name"]), str(t["desc"])])


func _ready() -> void:
	# 旧存档可能早已越过阈值：启动时补一次觉醒判定
	check_trait_unlocks()
	regen_feed_charges(true)   # 离线期间也按真实时间补发口粮
	PetState.commit()


# 按真实经过时间恢复口粮份数。返回本次新整份的数量。
# 满份时把计时锚点拨到当前时刻（不囤溢出时间）；首启（tick=0）只设锚点。
func regen_feed_charges(initial: bool = false) -> int:
	var now: float = float(Time.get_unix_time_from_system())
	var tick: float = PetState.feed_tick_unix
	if tick <= 0.0:
		PetState.feed_tick_unix = now
		return 0
	var elapsed: float = maxf(0.0, now - tick)
	if initial:
		PetState.feed_charges = clampf(PetState.feed_charges, 0.0, MAX_FEED_CHARGES)
	if PetState.feed_charges >= MAX_FEED_CHARGES:
		PetState.feed_tick_unix = now
		return 0
	var before: int = int(PetState.feed_charges)
	# 小数份数本身带着恢复进度，所以锚点直接推进到当前时刻即可
	PetState.feed_charges = minf(MAX_FEED_CHARGES, PetState.feed_charges + elapsed / FEED_REGEN_SEC)
	PetState.feed_tick_unix = now
	return int(PetState.feed_charges) - before


func feed_charges_left() -> int:
	return int(PetState.feed_charges)


# 下一份口粮还要多少秒（已满返回 0）
func feed_seconds_to_next() -> int:
	if PetState.feed_charges >= MAX_FEED_CHARGES:
		return 0
	var frac: float = PetState.feed_charges - floor(PetState.feed_charges)
	return int(ceil((1.0 - frac) * FEED_REGEN_SEC))


var last_interaction_msec := 0   # 最近一次交互时间，供调度器判断是否被冷落

# 一次交互 → 一次确定性数值变化 + 记忆 + 日志
# 维度分工：摸头→亲昵/温顺，喂食→亲昵，安抚→温顺/勇敢，聊天→好奇，玩耍→活泼/勇敢，冷落→活泼/亲昵下降
# 返回 false 表示这次交互因资源不足没有生效（目前只有口粮耗尽的喂食）。
func apply_interaction(kind: String) -> bool:
	if kind == "feed":
		regen_feed_charges()
		if feed_charges_left() <= 0:
			return false
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
			# 进来前已 regen：满份时锚点刚被拨到当前时刻，消耗后恢复即开始计时
			PetState.feed_charges -= 1.0
			PetState.add_hunger(FEED_HUNGER_GAIN)
			PetState.add_energy(5.0)
			PetState.add_trust(3.0)
			PetState.add_personality("affection", 0.5)
			PetState.add_mood(4.0)
			memory = "主人给我喂了好吃的，肚子饱饱的。"
			log = "被喂食 · 饱食+%d 信任+3 亲昵+0.5 心情+4 精力+5（剩余口粮%d份）" % [int(FEED_HUNGER_GAIN), feed_charges_left()]
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
			return false
	_sleeping = false   # 被主人互动 = 醒过来
	last_interaction_msec = Time.get_ticks_msec()
	PetState.add_memory(memory)
	PetState.add_log(log)
	check_trait_unlocks()
	PetState.commit()
	interaction_applied.emit(kind)
	return true


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
	check_trait_unlocks()
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
	check_trait_unlocks()
	PetState.commit()
	return {"ok": true, "name": item_name, "speech": str(def.get("speech", "")), "reaction": str(def.get("reaction", "positive"))}


# ---- 探索世界：进入门槛 + 探险结算（全部本地确定性，LLM 不参与）----
const EXPLORE_COST := 16.0
const EXPLORE_MIN_ENERGY := 15.0


# 出门：精力不足被拒绝；否则扣精力、唤醒、刷新交互时间（探索中不算冷落）
func begin_exploration() -> bool:
	if PetState.energy < EXPLORE_MIN_ENERGY:
		return false
	PetState.add_energy(-EXPLORE_COST)
	_sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	PetState.add_log("外出探索 · 精力-%d" % int(EXPLORE_COST))
	PetState.commit()
	return true


# 探险归来结算。r: {depth, kills, digs, items:{id:n}, fainted, hp_left}
# 返回 {line, speech, reaction} 供主界面播报与表演
func settle_expedition(r: Dictionary) -> Dictionary:
	var items: Dictionary = r.get("items", {})
	var kills: int = int(r.get("kills", 0))
	var digs: int = int(r.get("digs", 0))
	var fainted: bool = bool(r.get("fainted", false))
	var depth: int = int(r.get("depth", 1))

	for id in items.keys():
		PetState.add_item(str(id), int(items[id]))

	# 心情：打怪/挖宝/深入层数，晕倒重罚；勇敢靠战斗、好奇靠挖掘成长
	var mood_delta: float = clampf(4.0 + kills * 2.0 + digs * 1.0 + depth * 2.0, 0.0, 20.0)
	if fainted:
		mood_delta = maxf(mood_delta - 8.0, -8.0)
	PetState.add_mood(mood_delta)
	PetState.add_personality("brave", kills * 0.35 - (0.3 if fainted else 0.0))
	PetState.add_personality("curious", digs * 0.25)

	# 日志：层数 / 击杀 / 挖掘 / 具体道具
	var item_parts: Array = []
	for id in items.keys():
		item_parts.append("【%s】×%d" % [PetEventDeck.ITEM_NAMES.get(str(id), str(id)), int(items[id])])
	var log := "探索归来 · 深入%d层 打败怪物%d 挖宝%d" % [depth, kills, digs]
	if not item_parts.is_empty():
		log += " 带回" + "、".join(item_parts)
	log += " 心情%+.0f 勇敢%+.1f 好奇%+.1f" % [mood_delta, kills * 0.35 - (0.3 if fainted else 0.0), digs * 0.25]
	if fainted:
		log += "（体力不支逃回）"
	PetState.add_log(log)

	var memory := "我去数据废墟探险，下到第%d层，打败了%d只怪物、挖出了%d件宝贝。" % [depth, kills, digs]
	if fainted:
		memory = "我去数据废墟探险时被怪物打疼了，吓得一路跑回了家，但下次还要去！"
	PetState.add_memory(memory)
	PetState.commit()

	# 罐头台词 + 表演（数值与台词分离的老规矩）
	var speech := ""
	var reaction := "positive"
	if fainted:
		speech = "呜……数据废墟深处有只好大的故障兽！我、我先溜回家了，宝藏都还在呢！"
		reaction = "negative"
	elif not item_parts.is_empty():
		speech = "主人你看！我从数据废墟带回来%s，快夸我快夸我！" % "、".join(item_parts)
		reaction = "dance"
	elif kills > 0:
		speech = "哈哈，那些数据史莱姆完全不是我的对手！下次要下到更深的地方！"
		reaction = "run"
	else:
		speech = "我在数据废墟转了一圈，安安全全地回来啦。"
	return {"line": log, "speech": speech, "reaction": reaction}


# ---------- 霓虹跑酷（横版平台跳跃） ----------

const ADVENTURE_COST := 16.0
const ADVENTURE_MIN_ENERGY := 15.0


# 出门闯关：精力不足被拒绝；否则扣精力、唤醒、刷新交互时间
func begin_adventure() -> bool:
	if PetState.energy < ADVENTURE_MIN_ENERGY:
		return false
	PetState.add_energy(-ADVENTURE_COST)
	_sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	PetState.add_log("出门闯关 · 精力-%d" % int(ADVENTURE_COST))
	PetState.commit()
	return true


# 跑酷归来结算。r: {coins, kills, items:{id:n}, deaths, level, cleared, fainted, hp_left}
# 返回 {line, speech, reaction} 供主界面播报与表演
func settle_platformer(r: Dictionary) -> Dictionary:
	var items: Dictionary = r.get("items", {})
	var coins: int = int(r.get("coins", 0))
	var kills: int = int(r.get("kills", 0))
	var deaths: int = int(r.get("deaths", 0))
	var level: int = int(r.get("level", 1))
	var cleared: bool = bool(r.get("cleared", false))
	var fainted: bool = bool(r.get("fainted", false))

	for id in items.keys():
		PetState.add_item(str(id), int(items[id]))

	# 心情：金币/踩怪/通关给正反馈，摔落掉血扣分；活泼靠通关成长、勇敢靠踩怪、好奇靠搜集
	var mood_delta: float = clampf(4.0 + coins * 0.8 + kills * 2.0 + (10.0 if cleared else level * 2.0) - deaths * 3.0, -8.0, 22.0)
	if fainted:
		mood_delta = minf(mood_delta, -2.0)
	PetState.add_mood(mood_delta)
	var lively_gain: float = ((0.8 if cleared else level * 0.2) - deaths * 0.15)
	var brave_gain: float = kills * 0.3 - (0.3 if fainted else 0.0)
	var curious_gain: float = coins * 0.06
	PetState.add_personality("lively", lively_gain)
	PetState.add_personality("brave", brave_gain)
	PetState.add_personality("curious", curious_gain)

	var item_parts: Array = []
	for id in items.keys():
		item_parts.append("【%s】×%d" % [PetEventDeck.ITEM_NAMES.get(str(id), str(id)), int(items[id])])
	var reached: String = "全部通关" if cleared else ("在第%d关倒下" % (level + 1) if fainted and level == 0 else "通过第%d关" % level)
	var log := "霓虹跑酷 · %s 金币%d 踩飞怪物%d 摔落%d次" % [reached, coins, kills, deaths]
	if not item_parts.is_empty():
		log += " 宝箱带回" + "、".join(item_parts)
	log += " 心情%+.0f 活泼%+.1f 勇敢%+.1f 好奇%+.1f" % [mood_delta, lively_gain, brave_gain, curious_gain]
	if fainted:
		log += "（生命耗尽被传送回家）"
	PetState.add_log(log)

	var memory := "我去霓虹天台跑酷，%s，捡了%d枚数据币、踩飞了%d只故障虫。" % [reached, coins, kills]
	if fainted:
		memory = "我在霓虹天台上跑酷时摔晕了，被传送回了家……但那些金币我可都攥着呢，下次一定通关！"
	PetState.add_memory(memory)
	PetState.commit()

	var speech := ""
	var reaction := "positive"
	if fainted:
		speech = "呜哇——天台之间的缝好宽！我、我被传送回家了，金币一个都没丢，下次一定跳过去！"
		reaction = "negative"
	elif cleared:
		speech = "主人主人！霓虹天台三关我全跑通啦，风从耳边呼呼过，我现在是飞毛腿毛球！"
		reaction = "dance"
	elif not item_parts.is_empty():
		speech = "嘿嘿，我在天台上找到宝箱，带回%s给你！" % "、".join(item_parts)
		reaction = "dance"
	elif kills > 0:
		speech = "嘭！我从天上跳下来一脚一个故障虫，帅不帅帅不帅！"
		reaction = "run"
	else:
		speech = "我在霓虹天台上跑了好一会儿，吹吹风真舒服～"
	return {"line": log, "speech": speech, "reaction": reaction}


# ---- 数据海垂钓（轻量收菜：低精力门槛、慢节奏、鱼图鉴）----
const FISHING_COST := 10.0
const FISHING_MIN_ENERGY := 10.0
const FISH_BONUS_SEC := 5400.0    # 每离线 90 分钟攒 1 层鱼汛
const FISH_BONUS_MAX := 2

var fishing_bonus_streak := 0     # 本局剩余的鱼汛竿数


# 出门钓鱼：精力门槛；按离线时间结算鱼汛层数（前 N 竿咬钩快、稀有率高）
func begin_fishing() -> bool:
	if PetState.energy < FISHING_MIN_ENERGY:
		return false
	var now: float = float(Time.get_unix_time_from_system())
	var tick: float = PetState.fishing_tick_unix
	if tick > 0.0:
		var layers: int = int(maxf(0.0, now - tick) / FISH_BONUS_SEC)
		fishing_bonus_streak = clampi(layers, 0, FISH_BONUS_MAX)
	else:
		fishing_bonus_streak = 0
	PetState.fishing_tick_unix = now
	PetState.add_energy(-FISHING_COST)
	_sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	var log := "出门钓鱼 · 精力-%d" % int(FISHING_COST)
	if fishing_bonus_streak > 0:
		log += "（鱼汛×%d）" % fishing_bonus_streak
	PetState.add_log(log)
	PetState.commit()
	return true


# 钓鱼归来结算。r: {catches, misses, perfects, garbage, rare, items:{id:n}, fish:[id], new_dex:[id], fainted, dex_total}
func settle_fishing(r: Dictionary) -> Dictionary:
	fishing_bonus_streak = 0
	var catches: int = int(r.get("catches", 0))
	var misses: int = int(r.get("misses", 0))
	var perfects: int = int(r.get("perfects", 0))
	var garbage: int = int(r.get("garbage", 0))
	var rare: int = int(r.get("rare", 0))
	var items: Dictionary = r.get("items", {})
	var fish: Array = r.get("fish", [])
	var fainted: bool = bool(r.get("fainted", false))

	for id in items.keys():
		PetState.add_item(str(id), int(items[id]))

	# 本次新收录去重后写入图鉴
	var real_new: Array = []
	for fid in r.get("new_dex", []):
		var s: String = str(fid)
		if not PetState.fish_dex.has(s):
			PetState.fish_dex.append(s)
			real_new.append(s)

	var mood_delta: float = clampf(3.0 + catches * 2.0 + real_new.size() * 6.0 + rare * 4.0 - misses * 1.5 - garbage * 1.0, -6.0, 24.0)
	if fainted:
		mood_delta = minf(mood_delta, -2.0)
	PetState.add_mood(mood_delta)
	var curious_gain: float = catches * 0.12 + real_new.size() * 0.3
	var gentle_gain: float = perfects * 0.08
	var lively_gain: float = perfects * 0.05
	PetState.add_personality("curious", curious_gain)
	PetState.add_personality("gentle", gentle_gain)
	PetState.add_personality("lively", lively_gain)

	var item_parts: Array = []
	for id in items.keys():
		item_parts.append("【%s】×%d" % [PetEventDeck.ITEM_NAMES.get(str(id), str(id)), int(items[id])])
	var fish_names: Array = []
	for fid in fish:
		fish_names.append(str(PetEventDeck.FISH_DEX[str(fid)]["name"]))
	var log := "数据海垂钓 · 收获%d竿 脱钩%d次" % [catches, misses]
	if not fish_names.is_empty():
		log += " 钓到" + "、".join(fish_names.slice(0, 5))
		if fish_names.size() > 5:
			log += "等%d种" % fish_names.size()
	if not real_new.is_empty():
		log += " 图鉴新收录%d种（%d/%d）" % [real_new.size(), PetState.fish_dex.size(), PetEventDeck.FISH_TOTAL]
	if not item_parts.is_empty():
		log += " 带回" + "、".join(item_parts)
	if garbage > 0:
		log += " 垃圾×%d" % garbage
	log += " 心情%+.0f 好奇%+.1f 温顺%+.1f 活泼%+.1f" % [mood_delta, curious_gain, gentle_gain, lively_gain]
	if fainted:
		log += "（耐心耗尽被传送回家）"
	PetState.add_log(log)

	var memory := ""
	if real_new.is_empty() and catches > 0:
		memory = "我在数据海边安安静静钓了 %d 竿鱼，海风和数据流一起晃，好舒服。" % catches
	else:
		var names: Array = []
		for fid in real_new:
			names.append(str(PetEventDeck.FISH_DEX[str(fid)]["name"]))
		memory = "我在数据海第一次钓到了%s，图鉴又多了新收藏！" % "、".join(names)
	if fainted:
		memory = "我在数据海钓鱼时接连脱钩，耐心用光被传送回了家……好在钓上来的都没丢，下次一定沉住气。"
	PetState.add_memory(memory)
	PetState.commit()

	var speech := ""
	var reaction := "positive"
	if fainted:
		speech = "呜……连着让鱼跑了，我蹲在码头上瘪着嘴被送回家了。不过钓上来的我都好好抱着呢！"
		reaction = "negative"
	elif rare > 0:
		var rare_names: Array = []
		for fid in fish:
			if int(PetEventDeck.FISH_DEX[str(fid)]["rarity"]) == 3:
				rare_names.append(str(PetEventDeck.FISH_DEX[str(fid)]["name"]))
		speech = "主人快看！！我钓到了传说中的%s，数据海都为它亮起来了！" % "、".join(rare_names)
		reaction = "dance"
	elif not real_new.is_empty():
		var new_names: Array = []
		for fid in real_new:
			new_names.append(str(PetEventDeck.FISH_DEX[str(fid)]["name"]))
		speech = "嘿嘿，图鉴上多了%s！我现在是数据海小博物学家～" % "、".join(new_names)
		reaction = "dance"
	elif catches == 0:
		speech = "今天的鱼都好狡猾……不过吹了吹海风，我心情反而平静下来啦。"
	else:
		speech = "钓了%d竿，坐在码头晃脚丫的下午真舒服～" % catches
	return {"line": log, "speech": speech, "reaction": reaction}


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
