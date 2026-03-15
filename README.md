# mori_live2d (inochi2d)

本模块用于把 **Inochi2D（开源 Live2D 替代）** 接进 Mori 的最基础 AI VTuber 流程。

当前策略：

- **渲染前端使用 Love2D + `inochi2d-c`（LuaJIT FFI）**：加载 `.inx` 皮套、渲染，并做最小的“随机扭动 + 嘴形”驱动（参考 my-neuro 的思路）
- Mori 侧保持最小集成：写字幕文件、生成 TTS 音频，方便 OBS 直接捕获与叠加

## 1) 启动 Love2D 前端（当前默认）

前端目录：`mori_live2d/love2d_frontend/`。

### 1.1 构建 `inochi2d-c` 运行时（必需）

需要本机安装 D 工具链（`dub` + `ldc2/ldc`）以及 OpenGL 相关依赖。构建后会把 `libinochi2d-c.so` 复制到 `model/inochi2d/native/`：

```bash
python3 -m mori_live2d.cli build-inochi2d-c
```

### 1.2 运行 Love2D

安装好 LÖVE（Love2D，建议 11.x LuaJIT 版本）后，在主仓库根目录运行：

```bash
love mori_live2d/love2d_frontend
```

默认会读取：

- `live/subtitle.txt`
- `live/events.jsonl`（用于发现新的 wav 并播放，驱动嘴形）

如果你的 `live/` 不在默认位置，用环境变量指定目录/文件：

```bash
MORI_LIVE_DIR=/abs/path/to/live love mori_live2d/love2d_frontend
MORI_SUBTITLE_PATH=/abs/path/to/live/subtitle.txt love mori_live2d/love2d_frontend
MORI_EVENT_LOG=/abs/path/to/live/events.jsonl love mori_live2d/love2d_frontend
MORI_PUPPET_PATH=/abs/path/to/model/inochi2d/puppets/aka/Aka.inx love mori_live2d/love2d_frontend
```

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

## 4) OBS 最小配置建议

- 捕获 Love2D 窗口作为“角色层”
- 添加“文本（从文件读取）”来源，指向 `live/subtitle.txt` 作为“字幕层”

> 备注：参数映射目前是“模糊匹配”（按参数名关键词找 Head/Mouth 等），不同皮套可能需要单独做映射配置（TODO）。

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
