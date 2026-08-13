#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image


def default_helper_path() -> Path:
    return Path.home() / ".codex" / "skills" / ".system" / "imagegen" / "scripts" / "remove_chroma_key.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split a front/back chroma-key unit sheet and export transparent PNGs."
    )
    parser.add_argument("--sheet", required=True, help="Source sheet with front view on the left and back view on the right.")
    parser.add_argument("--unit-id", required=True, help="Stable unit art id, for example shield_pair.")
    parser.add_argument("--out-dir", required=True, help="Directory for <unit-id>_front.png and <unit-id>_back.png.")
    parser.add_argument(
        "--helper",
        default=str(default_helper_path()),
        help="Path to imagegen remove_chroma_key.py helper.",
    )
    parser.add_argument("--transparent-threshold", type=int, default=12)
    parser.add_argument("--opaque-threshold", type=int, default=220)
    parser.add_argument("--edge-contract", type=float, default=0.0)
    return parser.parse_args()


def run_chroma_key(helper: Path, source: Path, out_path: Path, args: argparse.Namespace) -> None:
    command = [
        sys.executable,
        str(helper),
        "--input",
        str(source),
        "--out",
        str(out_path),
        "--auto-key",
        "border",
        "--soft-matte",
        "--transparent-threshold",
        str(args.transparent_threshold),
        "--opaque-threshold",
        str(args.opaque_threshold),
        "--despill",
        "--force",
    ]
    if args.edge_contract > 0:
        command.extend(["--edge-contract", str(args.edge_contract)])
    subprocess.run(command, check=True)


def validate_alpha(path: Path) -> None:
    image = Image.open(path).convert("RGBA")
    width, height = image.size
    corners = [
        image.getpixel((0, 0))[3],
        image.getpixel((width - 1, 0))[3],
        image.getpixel((0, height - 1))[3],
        image.getpixel((width - 1, height - 1))[3],
    ]
    if any(alpha > 8 for alpha in corners):
        raise RuntimeError(f"{path} does not have transparent corners")

    alpha = image.getchannel("A")
    alpha_data = alpha.get_flattened_data() if hasattr(alpha, "get_flattened_data") else alpha.getdata()
    visible_pixels = sum(1 for value in alpha_data if value > 8)
    total_pixels = width * height
    visible_ratio = visible_pixels / total_pixels
    if visible_ratio < 0.03 or visible_ratio > 0.85:
        raise RuntimeError(f"{path} has suspicious alpha coverage: {visible_ratio:.2%}")


def main() -> int:
    args = parse_args()
    sheet_path = Path(args.sheet)
    out_dir = Path(args.out_dir)
    helper = Path(args.helper)

    if not sheet_path.exists():
        raise FileNotFoundError(sheet_path)
    if not helper.exists():
        raise FileNotFoundError(helper)

    out_dir.mkdir(parents=True, exist_ok=True)
    image = Image.open(sheet_path).convert("RGBA")
    width, height = image.size
    if width < 2 or height < 2:
        raise RuntimeError(f"{sheet_path} is too small to split")

    midpoint = width // 2
    crops = {
        "front": image.crop((0, 0, midpoint, height)),
        "back": image.crop((midpoint, 0, width, height)),
    }

    with tempfile.TemporaryDirectory(prefix="unit_art_") as temp_name:
        temp_dir = Path(temp_name)
        for view, crop in crops.items():
            half_path = temp_dir / f"{args.unit_id}_{view}_half.png"
            crop.save(half_path)
            out_path = out_dir / f"{args.unit_id}_{view}.png"
            run_chroma_key(helper, half_path, out_path, args)
            validate_alpha(out_path)
            print(out_path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
