from __future__ import annotations

import argparse
from pathlib import Path

from .example_models import install_example_models
from .inochi2d_c_runtime import build_inochi2d_c_runtime
from .inochi_session import install_inochi_session, run_inochi_session


def _default_root() -> Path:
    # Expected layout (monorepo):
    #   <repo>/mori_live2d/...
    #   <repo>/model/...
    return (Path(__file__).resolve().parent.parent / "model" / "inochi2d").resolve()


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="mori-live2d", description="Inochi2D helpers for Mori.")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_build_c = sub.add_parser("build-inochi2d-c", help="Build inochi2d-c shared library (OpenGL enabled).")
    p_build_c.add_argument(
        "--src",
        default=str((Path(__file__).resolve().parent / "third_party" / "inochi2d-c").resolve()),
        help="Path to inochi2d-c source (default: mori_live2d/third_party/inochi2d-c).",
    )
    p_build_c.add_argument(
        "--out",
        default=str(_default_root() / "native"),
        help="Output dir to copy the built library (default: <repo>/model/inochi2d/native).",
    )
    p_build_c.add_argument("--compiler", default="", help="Override D compiler (ldc2/ldc).")
    p_build_c.add_argument("--config", default="yesgl", help="dub config (default: yesgl).")

    p_install_session = sub.add_parser("install-session", help="Download and extract Inochi Session (official frontend).")
    p_install_session.add_argument("--root", default=str(_default_root()), help="Install root (default: <repo>/model/inochi2d).")
    p_install_session.add_argument("--platform", default=None, help="Override platform (linux/win32/osx).")
    p_install_session.add_argument("--overwrite", action="store_true", help="Overwrite existing files.")

    p_install_models = sub.add_parser("install-models", help="Download open example puppets (Aka/Midori).")
    p_install_models.add_argument("--root", default=str(_default_root()), help="Model root (default: <repo>/model/inochi2d).")
    p_install_models.add_argument("--models", nargs="+", default=["aka"], help="Models to download: aka midori")
    p_install_models.add_argument("--overwrite", action="store_true", help="Overwrite existing files.")

    p_run = sub.add_parser("run-session", help="Run Inochi Session executable.")
    p_run.add_argument("--bin", required=True, help="Path to inochi-session executable.")
    p_run.add_argument("--x11", action="store_true", help="Force SDL_VIDEODRIVER=x11 (Wayland workaround).")

    return p.parse_args()


def main() -> int:
    args = _parse_args()

    if args.cmd == "build-inochi2d-c":
        build = build_inochi2d_c_runtime(
            src_dir=Path(args.src),
            out_dir=Path(args.out),
            config=str(args.config or "yesgl"),
            compiler=str(args.compiler or "").strip() or None,
        )
        print(f"src> {build.src_dir}")
        print(f"lib> {build.out_lib}")
        print(f"out> {build.copied_to}")
        return 0

    if args.cmd == "install-session":
        install = install_inochi_session(
            root=Path(args.root),
            platform=str(args.platform).strip() or None if args.platform is not None else None,
            overwrite=bool(args.overwrite),
        )
        print(f"tag> {install.tag}")
        print(f"dir> {install.install_dir}")
        print(f"bin> {install.bin_path}")
        return 0

    if args.cmd == "install-models":
        paths = install_example_models(
            root=Path(args.root),
            models=[str(x) for x in args.models],
            overwrite=bool(args.overwrite),
        )
        for p in paths:
            print(p)
        return 0

    if args.cmd == "run-session":
        extra_env = {"SDL_VIDEODRIVER": "x11"} if bool(getattr(args, "x11", False)) else None
        proc = run_inochi_session(bin_path=Path(args.bin), extra_env=extra_env)
        print(f"pid> {proc.pid}")
        proc.wait()
        return int(proc.returncode or 0)

    raise SystemExit(2)


if __name__ == "__main__":
    raise SystemExit(main())
