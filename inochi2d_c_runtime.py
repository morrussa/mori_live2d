from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


class Inochi2DCRuntimeError(RuntimeError):
    pass


@dataclass(frozen=True)
class Inochi2DCRuntimeBuild:
    src_dir: Path
    out_lib: Path
    copied_to: Path
    compiler: str
    config: str


def _which(cmd: str) -> str | None:
    return shutil.which(cmd)


def _detect_dub() -> str:
    dub = _which("dub")
    if not dub:
        raise Inochi2DCRuntimeError(
            "Missing build tool: dub. Install dub + ldc (D compiler) and try again."
        )
    return dub


def _detect_ldc() -> str:
    for c in ("ldc2", "ldc"):
        if _which(c):
            return c
    raise Inochi2DCRuntimeError(
        "Missing D compiler: ldc2/ldc. Install LDC and try again."
    )


def build_inochi2d_c_runtime(
    *,
    src_dir: Path,
    out_dir: Path,
    config: str = "yesgl",
    compiler: str | None = None,
    env: dict[str, str] | None = None,
) -> Inochi2DCRuntimeBuild:
    """
    Build Inochi2D C ABI runtime (inochi2d-c) as a shared library.

    This uses the upstream build via `dub build --config=yesgl` which includes the OpenGL renderer.
    """

    src_dir = src_dir.expanduser().resolve()
    out_dir = out_dir.expanduser().resolve()
    if not src_dir.is_dir():
        raise FileNotFoundError(f"inochi2d-c source dir not found: {src_dir}")

    dub = _detect_dub()
    compiler = (compiler or "").strip() or _detect_ldc()
    config = str(config or "").strip() or "yesgl"

    cmd = [dub, "build", f"--compiler={compiler}", f"--config={config}"]
    build_env = os.environ.copy()
    if env:
        build_env.update({str(k): str(v) for k, v in env.items()})

    subprocess.run(cmd, cwd=str(src_dir), env=build_env, check=True, text=True)

    # dub.sdl sets: targetPath "out/"
    out_lib = (src_dir / "out" / "libinochi2d-c.so").resolve()
    if not out_lib.is_file():
        # Best-effort fallback: find any libinochi2d-c.*
        candidates = list((src_dir / "out").glob("libinochi2d-c.*")) if (src_dir / "out").is_dir() else []
        if candidates:
            out_lib = candidates[0].resolve()
        else:
            raise FileNotFoundError(f"Build succeeded but library not found under: {src_dir / 'out'}")

    out_dir.mkdir(parents=True, exist_ok=True)
    copied_to = (out_dir / out_lib.name).resolve()
    shutil.copy2(out_lib, copied_to)

    return Inochi2DCRuntimeBuild(
        src_dir=src_dir,
        out_lib=out_lib,
        copied_to=copied_to,
        compiler=compiler,
        config=config,
    )

