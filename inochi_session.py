from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from .util import download_file, extract_zip, http_get_json


class InochiSessionError(RuntimeError):
    pass


@dataclass(frozen=True)
class InochiSessionInstall:
    tag: str
    platform: str
    install_dir: Path
    bin_path: Path


def _detect_platform(explicit: str | None = None) -> str:
    if explicit:
        return str(explicit).strip().lower()

    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform in ("win32", "cygwin"):
        return "win32"
    if sys.platform == "darwin":
        return "osx"
    return sys.platform


def _asset_name_for_platform(platform: str) -> tuple[str, str]:
    plat = str(platform).strip().lower()
    if plat == "linux":
        return ("inochi-session-linux.zip", "inochi-session")
    if plat == "win32":
        return ("inochi-session-win32.zip", "inochi-session.exe")
    if plat == "osx":
        return ("inochi-session-osx.zip", "inochi-session.app")
    raise InochiSessionError(f"Unsupported platform for inochi-session auto-install: {platform}")


def install_inochi_session(*, root: Path, platform: str | None = None, overwrite: bool = False) -> InochiSessionInstall:
    root = root.expanduser().resolve()
    platform = _detect_platform(platform)
    asset_name, bin_name = _asset_name_for_platform(platform)

    release = http_get_json("https://api.github.com/repos/Inochi2D/inochi-session/releases/latest")
    tag = str(release.get("tag_name") or "").strip() or "latest"

    assets = release.get("assets") if isinstance(release, dict) else None
    if not isinstance(assets, list):
        raise InochiSessionError("Invalid GitHub release payload for Inochi2D/inochi-session.")

    asset = next((a for a in assets if isinstance(a, dict) and a.get("name") == asset_name), None)
    if not isinstance(asset, dict):
        raise InochiSessionError(f"Missing asset {asset_name} in latest Inochi Session release.")

    url = str(asset.get("browser_download_url") or "").strip()
    if not url:
        raise InochiSessionError(f"Missing browser_download_url for asset: {asset_name}")

    install_dir = (root / "apps" / "inochi-session" / tag / platform).resolve()
    zip_path = (root / "apps" / "inochi-session" / tag / asset_name).resolve()

    download_file(url, zip_path, overwrite=overwrite)
    extract_zip(zip_path, install_dir, overwrite=overwrite)

    bin_path = (install_dir / bin_name).resolve()
    if platform == "linux" and bin_path.is_file():
        try:
            bin_path.chmod(bin_path.stat().st_mode | 0o111)
        except Exception:
            pass

    return InochiSessionInstall(tag=tag, platform=platform, install_dir=install_dir, bin_path=bin_path)


def run_inochi_session(*, bin_path: Path, cwd: Path | None = None, extra_env: dict[str, str] | None = None) -> subprocess.Popen[str]:
    bin_path = bin_path.expanduser().resolve()
    if not bin_path.exists():
        raise FileNotFoundError(f"inochi-session not found: {bin_path}")

    if cwd is None:
        cwd = bin_path.parent

    env = os.environ.copy()
    if extra_env:
        env.update({str(k): str(v) for k, v in extra_env.items()})

    if sys.platform.startswith("linux"):
        lib_dir = str(bin_path.parent)
        old = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = f"{lib_dir}:{old}" if old else lib_dir

    return subprocess.Popen([str(bin_path)], cwd=str(cwd), env=env, text=True)

