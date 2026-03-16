# Airi（Live2D/Cubism Web）vs Mori（Inochi2D/Inox2D + Love2D）皮套操控对比

本文记录我在 `/tmp/airi` 拉取的 Airi 仓库里，Live2D 皮套「参数驱动/眨眼/视线/节拍摇摆」的实现位置，并对应到本仓库（`mori_live2d/love2d_frontend`）的实现与差异，方便后续继续复刻/对齐手感。

## 1) Airi 侧：Live2D 参数驱动的关键文件

- Live2D 模型加载 + 参数写入：
  - `/tmp/airi/packages/stage-ui-live2d/src/components/scenes/live2d/Model.vue`
  - 主要行为：
    - `coreModel.setParameterValueById(...)` 写入标准参数（`ParamAngleX/Y/Z`、`ParamEyeLOpen/ROpen`、`ParamMouthOpenY` 等）
    - Hook `motionManager.update`：把「motion（动作）」与「手动参数/自动眨眼/节拍」合并
- Motion update hook + 插件（beat-sync / idle focus / auto blink）：
  - `/tmp/airi/packages/stage-ui-live2d/src/composables/live2d/motion-manager.ts`
- Beat-sync（节拍驱动头部 yaw/roll 的目标轨迹）：
  - `/tmp/airi/packages/stage-ui-live2d/src/composables/live2d/beat-sync.ts`
- Idle 视线（随机扫视 + 平滑）：
  - `/tmp/airi/packages/stage-ui-live2d/src/composables/live2d/animation.ts`

> 结论：Airi 的「皮套操控」核心是 **持续写 Live2D Param**，并在 `motionManager.update` hook 中把 motion/自动效果/外部参数合成。

## 2) Mori 侧：Inochi2D 参数驱动的关键文件

- 参数映射 + 每帧驱动（idle / mouse look / saccade / blink / mouth / breath）：
  - `mori_live2d/love2d_frontend/controller.lua`
- 渲染循环 + lipsync 输入（从 `live/events.jsonl` 的 wav 做 mouth envelope）：
  - `mori_live2d/love2d_frontend/main.lua`
  - `mori_live2d/love2d_frontend/lipsync.lua`

> 结论：Mori 的「皮套操控」核心是 **把语义 key（head/eye/mouth/breath）映射到 Inochi2D 参数名**，然后每帧 `inox_set_param(name, x, y)` 写入。

## 3) 已对齐/复刻点（对应 Airi 的行为）

`mori_live2d/love2d_frontend/controller.lua` 目前已具备与 Airi 类似的：

- 自动眨眼：idle/closing/opening 三段，使用 ease-out/ease-in，延迟随机（3–8s）
- Idle 视线扫视（saccade）：随机目标 + 平滑过渡；也支持 mouse look
- Mouth open：基于音频 RMS envelope（并做简单平滑/曲线）

## 4) 本次补齐：更贴近 Airi 的“参数合成”方式

本仓库在 `mori_live2d/love2d_frontend/controller.lua` 做了三点补齐：

1. **支持 vec2 的 head/body 参数**（之前只驱动了 `head_yaw/head_pitch/head_roll` 的标量参数；遇到只有 vec2 的皮套会“头不动”）
2. **增加 body 跟随 head**（对齐 Airi 的 `ParamBodyAngleX/Y/Z` 思路；用可调跟随系数 + 单独平滑）
3. **眨眼改为“乘以 base eye open”**（对齐 Airi 的 `blink * base` 合成方式；如果未来接入人脸跟踪/手动控制 eye-open，会更自然）

此外，`controller.update(..., input)` 现在也支持可选输入：

- `input.head = { roll, yaw, pitch }`：作为 head 的 base（-1..1），再叠加 idle/mouse
- `input.look = { x, y }` 或 `input.eye = { x, y }`：外部视线输入（-1..1），优先级高于 mouse/saccade
- `input.eye_open` / `input.eye_open_l` / `input.eye_open_r`：外部眼睛开合（0..1），与 blink 合成

这些输入目前 `main.lua` 没有接入（依旧只传 mouse 与 mouth），留作后续接摄像头/追踪时使用。

