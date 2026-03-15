# third_party

这里放 Inochi2D 相关的上游代码（以 submodule 形式拉取）：

- `inochi2d`：Inochi2D SDK（含 C FFI/Bindings）
- `inochi-session`：Inochi2D 官方 VTubing 前端

初始化（在 **mori_live2d 子仓库** 内）：

```bash
git submodule update --init --recursive
```

> 备注：主仓库也可以用 `git submodule update --init --recursive` 一次性拉全（含嵌套 submodule）。

