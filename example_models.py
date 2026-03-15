from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .util import download_file


class ExampleModelError(RuntimeError):
    pass


@dataclass(frozen=True)
class ExampleModel:
    key: str
    file_name: str
    url: str
    license_note: str


EXAMPLE_MODELS: dict[str, ExampleModel] = {
    "aka": ExampleModel(
        key="aka",
        file_name="Aka.inx",
        url="https://media.githubusercontent.com/media/Inochi2D/example-models/main/Aka.inx",
        license_note="CC BY 4.0 (Design/Rigging: seagetch)",
    ),
    "midori": ExampleModel(
        key="midori",
        file_name="Midori.inx",
        url="https://media.githubusercontent.com/media/Inochi2D/example-models/main/Midori.inx",
        license_note="CC BY 4.0 (Design/Rigging: seagetch)",
    ),
}


def install_example_models(*, root: Path, models: list[str], overwrite: bool = False) -> list[Path]:
    root = root.expanduser().resolve()
    out: list[Path] = []

    if not models:
        raise ExampleModelError("No models specified. Use: aka, midori")

    for m in models:
        key = str(m).strip().lower()
        spec = EXAMPLE_MODELS.get(key)
        if spec is None:
            raise ExampleModelError(f"Unknown example model: {m}. Choices: {', '.join(sorted(EXAMPLE_MODELS))}")

        dest_dir = (root / "puppets" / spec.key).resolve()
        dest_path = (dest_dir / spec.file_name).resolve()
        download_file(spec.url, dest_path, overwrite=overwrite)
        out.append(dest_path)

    return out

