# mori_live2d (inochi2d)

本模块用于把 **Inochi2D（开源 Live2D 替代）** 接进 Mori 的最基础 AI VTuber 流程。

当前策略：

- **渲染/动捕使用 Inochi2D 官方前端：Inochi Session**（因为它目前更像“完整应用”，后端不易单独抽出来用）
- Mori 侧只做最小集成：写字幕文件、生成 TTS 音频，方便 OBS 直接捕获与叠加

## 1) 安装 Inochi Session（官方前端）

把官方 zip 下载并解压到本仓库根目录的 `model/inochi2d/`（该目录默认不进 git）：

```bash
python3 -m mori_live2d.cli install-session
```

安装后会打印可执行文件路径（Linux 是 `inochi-session`，Windows 是 `inochi-session.exe`）。

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

- 捕获 Inochi Session 窗口作为“角色层”
- 添加“文本（从文件读取）”来源，指向 `live/subtitle.txt` 作为“字幕层”

> 备注：Inochi Session 的透明背景/抠像/动捕配置按官方 UI 设置即可；本仓库目前不强绑定其内部参数。
