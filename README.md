# mori_live2d (inochi2d)

本模块用于把 **Inochi2D（开源 Live2D 替代）** 接进 Mori 的最基础 AI VTuber 流程。

当前策略：

- **渲染前端改为 Love2D（WIP 原型）**：先做一个“随机扭动”的占位皮套 + 字幕叠加，后续再把真实 Inochi2D runtime 绑定进来
- Mori 侧保持最小集成：写字幕文件、生成 TTS 音频，方便 OBS 直接捕获与叠加

## 1) 启动 Love2D 前端（当前默认）

前端目录：`mori_live2d/love2d_frontend/`（目前是占位实现：随机扭动 + 读取字幕文件）。

安装好 LÖVE（Love2D）后，在主仓库根目录运行：

```bash
love mori_live2d/love2d_frontend
```

默认会尝试读取 `../../live/subtitle.txt`。如果你的 `live/` 不在默认位置，用环境变量指定绝对路径：

```bash
MORI_SUBTITLE_PATH=/abs/path/to/live/subtitle.txt love mori_live2d/love2d_frontend
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

> TODO：把真实 Inochi2D runtime（.inx）接入 Love2D，并做口型/表情参数驱动。

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
