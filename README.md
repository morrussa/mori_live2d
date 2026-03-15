# mori_live2d (inochi2d)

本模块用于把 **Inochi2D（开源 Live2D 替代）** 接进 Mori 的最基础 AI VTuber 流程。

当前策略：

- **渲染前端使用 Love2D + Inox2D（LuaJIT FFI）**：加载 `.inx/.inp` 皮套、渲染，并做最小的“随机扭动 + 嘴形”驱动（参考 my-neuro 的思路）
- Mori 侧保持最小集成：写字幕文件、生成 TTS 音频，方便 OBS 直接捕获与叠加

已知限制（很重要）：

- 当前使用的 Inox2D（上游 `third_party/inox2d`）仍处于原型期，**部分新特性（例如 MeshGroup / 动画）未实现**，可能导致“模型部分不渲染”（常见现象：上半身/某些部件缺失）。
- 可用 `python3 -m mori_live2d.cli inspect-puppet /path/to/puppet.inx --dump-json /tmp/payload.json` 快速查看模型里有哪些 `node.type`；如果出现 `MeshGroup` 等未知类型，基本可以判定为上游未支持。
- 上游状态说明见：`mori_live2d/third_party/inox2d/README.md`（建议先用 Aka/Midori 验证渲染链路没问题）。

## 1) 启动 Love2D 前端（当前默认）

前端目录：`mori_live2d/love2d_frontend/`。

### 1.1 构建 Inox2D FFI 运行时（必需）

需要本机安装 Rust 工具链（`cargo`）以及 OpenGL 相关依赖。构建后会把 `libmori_inox2d.so` 复制到 `model/inochi2d/native/`：

```bash
python3 -m mori_live2d.cli build-inox2d
```

### 1.2 运行 Love2D

安装好 LÖVE（Love2D，建议 11.x LuaJIT 版本）后，在主仓库根目录运行：

```bash
love mori_live2d/love2d_frontend
```

运行后也可以直接把 `.inx/.inp` 文件拖进窗口来切换皮套（方便快速验证导入）。

默认会读取：

- `live/subtitle.txt`
- `live/events.jsonl`（用于发现新的 wav 并播放，驱动嘴形）

如果你的 `live/` 不在默认位置，用环境变量指定目录/文件：

```bash
MORI_LIVE_DIR=/abs/path/to/live love mori_live2d/love2d_frontend
MORI_SUBTITLE_PATH=/abs/path/to/live/subtitle.txt love mori_live2d/love2d_frontend
MORI_EVENT_LOG=/abs/path/to/live/events.jsonl love mori_live2d/love2d_frontend
MORI_PUPPET_PATH=/abs/path/to/model/inochi2d/puppets/aka/Aka.inx love mori_live2d/love2d_frontend
MORI_INOX2D_LIB=/abs/path/to/libmori_inox2d.so love mori_live2d/love2d_frontend
MORI_MAPPING_PATH=/abs/path/to/puppet.mori-map love mori_live2d/love2d_frontend
MORI_MOUSE_LOOK=1 love mori_live2d/love2d_frontend
MORI_FONT_PATH=/abs/path/to/NotoSansCJK-Regular.ttc love mori_live2d/love2d_frontend
MORI_UI_FONT_SIZE=14 MORI_SUBTITLE_FONT_SIZE=22 love mori_live2d/love2d_frontend
```

### 1.3 基本控制（热键）

- `H`：显示/隐藏映射与调试信息（默认显示）
- `I`：开关 Idle（头部随机扭动）
- `F`：开关 Mouse Look（眼睛/头部跟随鼠标）
- `B`：开关 Auto Blink（自动眨眼，需要找到眼睛开合参数）
- `R`：重新加载参数映射（修改映射文件后按一次即可生效）

> 分布式/远程部署：建议默认关闭 Mouse Look；也可以用 `MORI_MOUSE_LOOK=0` 或启动参数 `--mouse-look off` 强制关闭。

### 1.4 参数映射（可选，但强烈建议）

不同皮套的参数名可能不同；默认使用“关键词模糊匹配”去找 `head_* / mouth_open / eye_* / breath` 等参数。

你可以提供一个映射覆盖文件（`MORI_MAPPING_PATH` 或 `--mapping`）来显式指定参数名。

也支持“就近自动发现”：如果不传 `MORI_MAPPING_PATH`，会尝试在皮套同目录下寻找：

- `<puppet>.mori-map`（例如 `Aka.inx.mori-map`）
- `<puppet_basename>.mori-map`（例如 `Aka.mori-map`）
- `<puppet_basename>.mori.lua`（Lua 表配置）

#### 映射文件格式（`.mori-map`）

简单的 `key = value` 文本，每行一个映射；支持 `#`/`;` 注释；在参数名前加 `!` 可反向（常用于左右/轴向相反的皮套）。

示例：

```ini
head_yaw = Head::Yaw
head_pitch = !Head::Pitch
mouth_open = Mouth::Open
eye_open_l = EyeL::Open
eye_open_r = EyeR::Open
eye_ball = Eye::Look
breath = Breath
```

可用 key（不区分是否实际存在，找不到会自动跳过）：`head_roll`/`head_pitch`/`head_yaw`/`mouth_open`/`eye_ball`/`eye_ball_x`/`eye_ball_y`/`eye_open_l`/`eye_open_r`/`eye_open`/`breath`。

## 2) 下载开源公共皮套（Aka / Midori，CC BY 4.0）

下载官方示例模型到 `model/inochi2d/puppets/<name>/`（每个模型单独文件夹）：

```bash
python3 -m mori_live2d.cli install-models --models aka midori
```

模型来源与署名见 `ATTRIBUTION.md`。

## 3) 运行基础 VTuber（字幕 + 可选 TTS）

在主仓库根目录运行：

```bash
python3 vtuber.py --tts --live-dir live
```

它会持续写入：

- `live/subtitle.txt`：当前要显示的字幕
- `live/events.jsonl`：每轮对话事件（含 wav 路径）
- `live/audio/turn_XXXX.wav`：可选 TTS 音频

### 3.1 一键启动（挂到 B 站直播间 + Love2D 前端 + 自动回复）

在主仓库根目录运行（会默认开启 TTS，Love2D 前端会自动播放语音并驱动嘴形）：

```bash
python3 scripts/run_bili_vtuber_love2d.py --bilibili-room-id <room_id> --exit-when-offline
```

可选：

- `--bilibili-room-url https://live.bilibili.com/<room_id>`
- `--puppet /abs/path/to/xxx.inx`
- `--mapping /abs/path/to/puppet.mori-map`
- `--mouse-look off`（或环境变量 `MORI_MOUSE_LOOK=0`，分布式部署推荐）

## 4) OBS 最小配置建议

- 捕获 Love2D 窗口作为“角色层”
- 添加“文本（从文件读取）”来源，指向 `live/subtitle.txt` 作为“字幕层”

> 备注：参数映射默认是“模糊匹配”（按参数名关键词找 Head/Mouth/Eye 等）；不同皮套建议单独提供 `.mori-map` 覆盖映射（见上文）。

## （可选）安装/运行 Inochi Session（官方前端）

如需对比或临时使用官方应用，把官方 zip 下载并解压到本仓库根目录的 `model/inochi2d/`（该目录默认不进 git）：

```bash
python3 -m mori_live2d.cli install-session
python3 -m mori_live2d.cli run-session --bin /path/to/inochi-session
```

如果你在 Linux 的 Wayland 桌面下启动失败，可尝试：

```bash
python3 -m mori_live2d.cli run-session --bin /path/to/inochi-session --x11
```
