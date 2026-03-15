from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MAGIC = b"TRNSRTS\0"


class PuppetInspectError(RuntimeError):
    pass


@dataclass(frozen=True)
class PuppetSummary:
    path: Path
    meta: dict[str, Any]
    node_type_counts: dict[str, int]
    unknown_node_types: list[str]
    param_count: int


def _walk_nodes(node: Any) -> Iterable[dict[str, Any]]:
    if not isinstance(node, dict):
        return
    yield node
    children = node.get("children")
    if isinstance(children, list):
        for c in children:
            yield from _walk_nodes(c)


def read_inp_payload_json(path: Path) -> dict[str, Any]:
    path = path.expanduser().resolve()
    with path.open("rb") as f:
        magic = f.read(8)
        if magic != MAGIC:
            raise PuppetInspectError(f"Not an Inochi2D .inp/.inx file (bad magic): {path}")
        length_bytes = f.read(4)
        if len(length_bytes) != 4:
            raise PuppetInspectError(f"Invalid .inp/.inx header (missing payload length): {path}")
        payload_len = int.from_bytes(length_bytes, "big", signed=False)
        payload = f.read(payload_len)
        if len(payload) != payload_len:
            raise PuppetInspectError(
                f"Invalid .inp/.inx header (payload truncated): {path} (need {payload_len} bytes, got {len(payload)})"
            )
    try:
        obj = json.loads(payload.decode("utf-8"))
    except Exception as e:
        raise PuppetInspectError(f"Failed to decode payload JSON from: {path}") from e
    if not isinstance(obj, dict):
        raise PuppetInspectError(f"Invalid payload JSON (expected object): {path}")
    return obj


def summarize_puppet_payload(payload: dict[str, Any], *, path: Path) -> PuppetSummary:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        meta = {}

    param = payload.get("param")
    param_count = len(param) if isinstance(param, list) else 0

    root = payload.get("nodes")
    node_types = Counter()
    for n in _walk_nodes(root):
        ty = n.get("type")
        if isinstance(ty, str) and ty:
            node_types[ty] += 1
        else:
            node_types["(missing)"] += 1

    supported = {"Node", "Part", "Composite", "SimplePhysics"}
    unknown = sorted([t for t in node_types.keys() if t not in supported and t != "(missing)"])

    return PuppetSummary(
        path=path,
        meta=meta,
        node_type_counts=dict(sorted(node_types.items(), key=lambda kv: (-kv[1], kv[0]))),
        unknown_node_types=unknown,
        param_count=param_count,
    )

