# 毛球 // CHONGWU

赛博朋克风的桌面电子宠物：一只住在电脑里的方块兔子「毛球」。Godot 4.7 + GDScript。

## 特性

- **3D 兔子 + 赛博 UI**：GLB 模型渲染到 SubViewport，五维性格雷达图、状态条、成长日志
- **互动**：摸头 / 喂食 / 安抚 / 聊天 / 玩耍，点击宠物有反应，按住拖动可 360° 环绕查看
- **空闲撒欢**：长时间不互动时会自己沿镜头方向跑近跑远（近大远小）
- **LLM 对话**：DeepSeek（OpenAI 兼容接口）驱动口吻；离线时本地关键词情感分析兜底
- **本地确定性数值**：所有心情/信任/五维变化由 `PetBrain` 规则计算，**LLM 只输出台词与情感标签，绝不改数值**
- **随机事件**：毛球主动发现新奇东西、闯小祸，影响心情/信任/性格，还会获得或丢失道具
- **背包道具**：8 种道具可点击使用，消耗道具 → 数值变化 → 对应动画（奔跑/跳舞/张望）
- **精力循环**：精力耗尽会自动睡觉恢复，喂食和安抚也能补充精力
- **时间天气面板**：系统时钟 + 免 Key 接口（ipwho.is 定位 / open-meteo 天气），离线时本地兜底
- 存档：`user://pet_state.json`

## 运行

用 Godot 4.7+ 打开本项目，导入后直接运行主场景即可。

## 配置 LLM（可选）

不配置也能玩（聊天走本地兜底回复）。要启用 DeepSeek 对话：

1. 复制 `config/llm_config.example.json` 为 `config/llm_config.json`，或直接在游戏内「设置」弹窗填写
2. API Key 只保存在用户目录 `user://llm_config.json`（Windows: `%APPDATA%/Godot/app_userdata/chongwu/`），也可用环境变量 `DEEPSEEK_API_KEY`
3. **Key 不会写入项目目录，不会进 git**（`config/llm_config.json` 已被 .gitignore 忽略）

## 结构

```
scripts/
  core/            # 纯逻辑：PetState 存档 / PetBrain 规则引擎 / 随机事件牌库 / 调度器 / LLM
  ui/              # 状态面板、雷达图、对话区、聊天气泡、时间天气面板等
  pet_actor.gd     # 3D 兔子表现层（只监听信号，不改数值）
  main.gd          # 主场景组装
assets/models/     # Kenney cube-pets 兔子 GLB
addons/godot_ai/   # Godot AI MCP 编辑器插件（开发辅助）
```
