from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


class Inox2DRuntimeError(RuntimeError):
    pass


@dataclass(frozen=True)
class Inox2DBuild:
    src_dir: Path
    target_lib: Path
    copied_to: Path


def _which(cmd: str) -> str | None:
    return shutil.which(cmd)


def _cargo() -> str:
    cargo = _which("cargo")
    if not cargo:
        raise Inox2DRuntimeError("Missing build tool: cargo (Rust). Install Rust toolchain and try again.")
    return cargo


def build_inox2d_ffi(*, src_dir: Path, out_dir: Path) -> Inox2DBuild:
    """
    Build `native/inox2d_ffi` (cdylib) and copy the shared library to out_dir.
    """
    src_dir = src_dir.expanduser().resolve()
    out_dir = out_dir.expanduser().resolve()
    if not (src_dir / "Cargo.toml").is_file():
        raise FileNotFoundError(f"Rust crate not found (missing Cargo.toml): {src_dir}")

    cargo = _cargo()
    env = os.environ.copy()

    subprocess.run([cargo, "build", "--release"], cwd=str(src_dir), env=env, check=True, text=True)

    target_dir = (src_dir / "target" / "release").resolve()
    # Linux default.
    lib_name = "libmori_inox2d_ffi.so"
    target_lib = (target_dir / lib_name).resolve()
    if not target_lib.is_file():
        # fallback: find any lib*.so with the crate name
        candidates = list(target_dir.glob("libmori_inox2d_ffi.*"))
        if candidates:
            target_lib = candidates[0].resolve()
        else:
            raise FileNotFoundError(f"Build succeeded but shared library not found under: {target_dir}")

    out_dir.mkdir(parents=True, exist_ok=True)
    copied_to = (out_dir / "libmori_inox2d.so").resolve()
    shutil.copy2(target_lib, copied_to)

    return Inox2DBuild(src_dir=src_dir, target_lib=target_lib, copied_to=copied_to)

