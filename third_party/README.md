# third_party

这里放 Inochi2D 相关的上游代码（以 submodule 形式拉取）：

- `inox2d`：Inochi2D 的 Rust 实现（用于本项目的 Love2D 绑定）

初始化（在 **mori_live2d 子仓库** 内）：

```bash
git submodule update --init --recursive
```

> 备注：主仓库也可以用 `git submodule update --init --recursive` 一次性拉全（含嵌套 submodule）。
