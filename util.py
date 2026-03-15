from __future__ import annotations

import json
import os
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


def http_get_json(url: str, *, timeout_s: int = 60) -> dict[str, Any]:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "mori-live2d",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        data = resp.read().decode("utf-8", errors="replace")
    obj = json.loads(data)
    return obj if isinstance(obj, dict) else {}


def download_file(url: str, dest: Path, *, overwrite: bool = False, timeout_s: int = 600) -> Path:
    dest = dest.expanduser().resolve()
    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.exists() and not overwrite:
        return dest

    with tempfile.NamedTemporaryFile(prefix=dest.name + ".", suffix=".tmp", dir=str(dest.parent), delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "mori-live2d"}, method="GET")
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            with tmp_path.open("wb") as f:
                shutil.copyfileobj(resp, f)
        os.replace(tmp_path, dest)
    finally:
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass

    return dest


def extract_zip(zip_path: Path, dest_dir: Path, *, overwrite: bool = False) -> None:
    zip_path = zip_path.expanduser().resolve()
    dest_dir = dest_dir.expanduser().resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path) as z:
        for member in z.infolist():
            out_path = dest_dir / member.filename
            if member.is_dir():
                out_path.mkdir(parents=True, exist_ok=True)
                continue
            out_path.parent.mkdir(parents=True, exist_ok=True)
            if out_path.exists() and not overwrite:
                continue
            z.extract(member, path=dest_dir)

