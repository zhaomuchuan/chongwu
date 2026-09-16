class_name PetEventDeck
extends RefCounted
## 随机事件引擎：加权事件池，全部效果本地确定性结算（心情/信任/五维/道具）。
## LLM 不参与事件 —— 台词是罐头文案，不耗 token，数值可解释、可测试。
## 由 EventScheduler 定时调用 roll_and_apply()。

# 道具图鉴
const ITEM_NAMES := {
	"cap": "闪亮瓶盖",
	"feather": "彩色羽毛",
	"stone": "光滑石子",
	"dandelion": "蒲公英",
	"leaf": "红枫叶",
	"ribbon": "粉丝带",
	"bell": "小铃铛",
	"key": "铜旧钥匙",
}

# kind: discover 发现 / joy 开心事 / mishap 小倒霉
# effects: mood 心情, trust 信任, persona 五维, item {id, delta}
# weight 越大越常见；dynamic=lose_item 的事件在抽取时随机指定一件已拥有的道具
const EVENTS := [
	{
		"id": "find_cap", "kind": "discover", "weight": 10,
		"title": "新奇发现",
		"speech": "哇！这里有个亮闪闪的瓶盖，是我的宝藏啦！",
		"memory": "我在角落里发现了一个闪亮瓶盖，偷偷藏了起来。",
		"effects": {"mood": 6.0, "persona": {"curious": 0.8}, "item": {"id": "cap", "delta": 1}},
	},
	{
		"id": "find_feather", "kind": "discover", "weight": 9,
		"title": "新奇发现",
		"speech": "一根彩色羽毛飘下来了！好轻好软，是给我的礼物吗？",
		"memory": "我捡到一根彩色羽毛，追着它跑了好久。",
		"effects": {"mood": 6.0, "persona": {"curious": 1.0, "lively": 0.4}, "item": {"id": "feather", "delta": 1}},
	},
	{
		"id": "find_stone", "kind": "discover", "weight": 9,
		"title": "新奇发现",
		"speech": "这块小石头圆滚滚的，摸起来凉凉的，好舒服。",
		"memory": "我在花盆边找到一颗光滑的小石子，把它收好了。",
		"effects": {"mood": 4.0, "persona": {"gentle": 0.5, "curious": 0.3}, "item": {"id": "stone", "delta": 1}},
	},
	{
		"id": "find_dandelion", "kind": "discover", "weight": 8,
		"title": "新奇发现",
		"speech": "呼——蒲公英全飞起来啦，像小雪花一样！",
		"memory": "我发现一朵蒲公英，一口气把绒毛全吹飞了。",
		"effects": {"mood": 5.0, "persona": {"gentle": 0.6, "curious": 0.4}, "item": {"id": "dandelion", "delta": 1}},
	},
	{
		"id": "find_leaf", "kind": "discover", "weight": 8,
		"title": "新奇发现",
		"speech": "一片红叶子转着圈圈落下来，我和它跳了支舞！",
		"memory": "一片红枫叶在风里打转，我追着它蹦了好久。",
		"effects": {"mood": 5.0, "persona": {"lively": 0.7, "curious": 0.3}, "item": {"id": "leaf", "delta": 1}},
	},
	{
		"id": "find_ribbon", "kind": "discover", "weight": 6,
		"title": "新奇发现",
		"speech": "好漂亮的粉丝带！系在脖子上的话，主人会夸我吗？",
		"memory": "我捡到一条粉丝带，想象着主人帮我系上的样子。",
		"effects": {"mood": 6.0, "persona": {"affection": 0.8, "gentle": 0.3}, "item": {"id": "ribbon", "delta": 1}},
	},
	{
		"id": "find_bell", "kind": "discover", "weight": 5,
		"title": "新奇发现",
		"speech": "叮铃——这个小东西会响！以后我跑到哪主人都能听到啦。",
		"memory": "我找到一个会叮铃响的小铃铛，走到哪响到哪。",
		"effects": {"mood": 7.0, "trust": 1.0, "persona": {"lively": 0.6, "curious": 0.6}, "item": {"id": "bell", "delta": 1}},
	},
	{
		"id": "find_key", "kind": "discover", "weight": 2,
		"title": "稀有发现",
		"speech": "一把铜闪闪的旧钥匙！它能打开什么秘密呢？我要好好研究！",
		"memory": "我发现一把神秘的铜旧钥匙，总觉得它藏着什么大秘密。",
		"effects": {"mood": 10.0, "trust": 1.0, "persona": {"curious": 2.0, "brave": 0.5}, "item": {"id": "key", "delta": 1}},
	},
	{
		"id": "chase_butterfly", "kind": "joy", "weight": 10,
		"title": "小小冒险",
		"speech": "有只蝴蝶！等等我呀——嘿嘿，虽然没追上，但是好好玩！",
		"memory": "我追着一只蝴蝶满屋跑，开心得停不下来。",
		"effects": {"mood": 8.0, "persona": {"lively": 1.0, "brave": 0.3}},
	},
	{
		"id": "sunbeam_nap", "kind": "joy", "weight": 9,
		"title": "悠闲一刻",
		"speech": "阳光晒在身上暖洋洋的，我摊成一块小饼啦～",
		"memory": "我在一块阳光里蜷着打了个盹，觉得整个世界都很温柔。",
		"effects": {"mood": 5.0, "persona": {"gentle": 0.6}},
	},
	{
		"id": "watch_clouds", "kind": "joy", "weight": 7,
		"title": "发呆时刻",
		"speech": "那朵云好像一根大胡萝卜……又好像不像？",
		"memory": "我趴在窗边看了好久的云，想象它们都是好吃的。",
		"effects": {"mood": 3.0, "persona": {"curious": 0.6}},
	},
	{
		"id": "gift_for_owner", "kind": "joy", "weight": 7,
		"title": "心意",
		"speech": "主人！这是我最宝贝的收藏，送给你！要收好哦！",
		"memory": "我把最喜欢的小宝贝推到主人面前，想把好东西都分给ta。",
		"effects": {"mood": 6.0, "trust": 3.0, "persona": {"affection": 1.0}},
	},
	{
		"id": "find_crumb", "kind": "joy", "weight": 8,
		"title": "意外加餐",
		"speech": "咦？桌底下居然有一块小零食碎屑！赚到啦赚到啦！",
		"memory": "我在桌子底下捡到一块零食碎屑，觉得自己运气超好。",
		"effects": {"mood": 6.0, "persona": {"curious": 0.3}},
	},
	{
		"id": "lose_item", "kind": "mishap", "weight": 6, "dynamic": "lose_item",
		"title": "小倒霉",
		"speech": "呜……我的宝贝不见了，我明明藏在这里的……",
		"memory": "我弄丢了一件自己收藏的小东西，难过了好一会儿。",
		"effects": {"mood": -7.0, "persona": {"lively": -0.3}, "item": {"delta": -1}},
	},
	{
		"id": "scared_shadow", "kind": "mishap", "weight": 6,
		"title": "虚惊一场",
		"speech": "刚刚那个黑影是什么！？……呼，原来是我自己的影子。",
		"memory": "我被自己的影子吓了一跳，心怦怦跳。",
		"effects": {"mood": -5.0, "persona": {"brave": -0.6}},
	},
	{
		"id": "knock_over", "kind": "mishap", "weight": 6,
		"title": "闯祸了",
		"speech": "哎呀……我把桌上的杯子碰掉了。主人不要生我的气好不好？",
		"memory": "我不小心碰掉了桌上的杯子，缩在角落等主人发落。",
		"effects": {"mood": -4.0, "trust": -1.0, "persona": {"gentle": 0.3}},
	},
	{
		"id": "stuck_box", "kind": "mishap", "weight": 5,
		"title": "小意外",
		"speech": "我钻进纸箱子……出、出不去了！等等，这边好像能出去！",
		"memory": "我卡在纸箱子里好一会儿，最后自己钻出来了，觉得自己变勇敢了。",
		"effects": {"mood": -3.0, "persona": {"brave": -0.4, "curious": 0.5}},
	},
]


# 抽一个当前可触发的事件（加权）；丢道具事件需要背包里有东西
func pick(state) -> Dictionary:
	# 好奇特质：discover 类事件权重随好奇强度提高（50 点为基准，最高 ×1.8）
	var curious_s: float = clampf((float(state.personality.get("curious", 50.0)) - 50.0) / 35.0, 0.0, 1.0)
	var pool: Array = []
	var total := 0.0
	for e in EVENTS:
		if e.get("dynamic", "") == "lose_item" and state.inventory.is_empty():
			continue
		var w: float = e.get("weight", 1.0)
		if str(e.get("kind", "")) == "discover":
			w *= 1.0 + 0.8 * curious_s
		# 调整后的权重写回副本，抽样循环才能用上（不能只改 total）
		var copy: Dictionary = e.duplicate(true)
		copy["weight"] = w
		pool.append(copy)
		total += w
	if pool.is_empty():
		return {}
	var roll := randf() * total
	var acc := 0.0
	for e in pool:
		acc += e.get("weight", 1.0)
		if roll <= acc:
			return e.duplicate(true)
	return pool[-1]


# 结算事件：改数值/道具 + 记忆 + 日志；返回 UI 需要的展示信息
func roll_and_apply(state) -> Dictionary:
	var e := pick(state)
	if e.is_empty():
		return {}

	# 勇敢特质：黑影惊吓事件翻转为「勇敢面对」，不再掉心情/勇敢
	if str(e.get("id", "")) == "scared_shadow" and float(state.personality.get("brave", 50.0)) >= PetBrainEngine.TRAIT_THRESHOLD:
		e["title"] = "才不怕呢"
		e["speech"] = "那个黑影？哼，我凑过去瞪了它一眼——嘿嘿，不过是我自己的影子嘛！"
		e["memory"] = "我勇敢地凑近吓了我一跳的黑影，发现只是影子，觉得自己长大了一点。"
		e["effects"] = {"mood": 3.0, "persona": {"brave": 0.6}}

	var fx: Dictionary = e.get("effects", {})
	if fx.has("mood"):
		state.add_mood(float(fx["mood"]))
	if fx.has("trust"):
		state.add_trust(float(fx["trust"]))

	var persona: Dictionary = fx.get("persona", {})
	for dim in persona.keys():
		state.add_personality(str(dim), float(persona[dim]))

	var gains: Array = []
	var fx_item: Dictionary = fx.get("item", {})
	if not fx_item.is_empty():
		var item_id := str(fx_item.get("id", ""))
		var delta: int = int(fx_item.get("delta", 0))
		if e.get("dynamic", "") == "lose_item":
			item_id = _random_owned_item(state)
			if item_id == "":
				delta = 0
		if delta != 0:
			state.add_item(item_id, delta)
			gains.append([ITEM_NAMES.get(item_id, item_id), delta])

	var log_parts: Array = []
	var mood_v: float = float(fx.get("mood", 0.0))
	var trust_v: float = float(fx.get("trust", 0.0))
	if mood_v != 0.0:
		log_parts.append("心情%+.0f" % mood_v)
	if trust_v != 0.0:
		log_parts.append("信任%+.0f" % trust_v)
	for dim in persona.keys():
		log_parts.append("%s%+.1f" % [PetStateStore.DIMENSION_LABELS.get(str(dim), str(dim)), float(persona[dim])])
	for g in gains:
		log_parts.append(("%s【%s】×%d" % ["获得" if g[1] > 0 else "丢失", g[0], absi(g[1])]))

	state.add_memory(str(e.get("memory", "")))
	state.add_log("%s · %s" % [str(e.get("title", "事件")), " ".join(log_parts)])
	state.commit()

	return {
		"kind": str(e.get("kind", "")),
		"title": str(e.get("title", "发生了什么")),
		"speech": str(e.get("speech", "")),
		"gains": gains,
	}


func _random_owned_item(state) -> String:
	var keys: Array = state.inventory.keys()
	if keys.is_empty():
		return ""
	return str(keys[randi() % keys.size()])
