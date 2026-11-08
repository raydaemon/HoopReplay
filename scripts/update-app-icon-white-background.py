#!/usr/bin/env python3
"""Rebuild HoopReplay app icons with a white background."""

from pathlib import Path

from PIL import Image, ImageChops, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
MASTER_PATH = ROOT / "branding/icon-master.png"
FOREGROUND_PATH = (
    ROOT
    / "android/HoopReplay/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png"
)


def orange_bounds(image: Image.Image) -> tuple[int, int, int, int]:
    pixels = image.convert("RGB")
    mask = Image.new("L", pixels.size)
    mask.putdata(
        [
            255 if red > 180 and green > 45 and green < 190 and blue < 80 else 0
            for red, green, blue in pixels.getdata()
        ]
    )
    bounds = mask.getbbox()
    if bounds is None:
        raise RuntimeError("Could not locate the orange logo")
    return bounds


def clean_foreground(foreground: Image.Image) -> Image.Image:
    foreground = foreground.convert("RGBA")
    # Keep only the orange/yellow artwork and its highlights. This removes every
    # black pixel around and between the colored shapes, producing clean white
    # separation lines on the white icon background.
    orange = foreground.convert("RGB")
    silhouette = Image.new("L", foreground.size)
    silhouette.putdata(
        [
            255
            if (
                red > 120 and red > green * 1.22 and red > blue * 1.55
            ) or (
                red > 185 and green > 125 and blue > 55
            )
            else 0
            for red, green, blue in orange.getdata()
        ]
    )
    silhouette = silhouette.filter(ImageFilter.GaussianBlur(0.45))
    foreground.putalpha(ImageChops.darker(foreground.getchannel("A"), silhouette))
    return foreground


def rebuild_master(foreground: Image.Image) -> Image.Image:
    master = Image.open(MASTER_PATH).convert("RGB")
    source_bounds = orange_bounds(foreground)
    target_bounds = orange_bounds(master)

    source_width = source_bounds[2] - source_bounds[0]
    source_height = source_bounds[3] - source_bounds[1]
    target_width = target_bounds[2] - target_bounds[0]
    target_height = target_bounds[3] - target_bounds[1]
    scale_x = target_width / source_width
    scale_y = target_height / source_height

    scaled_foreground = foreground.resize(
        (round(foreground.width * scale_x), round(foreground.height * scale_y)),
        Image.Resampling.LANCZOS,
    )
    offset_x = round(target_bounds[0] - source_bounds[0] * scale_x)
    offset_y = round(target_bounds[1] - source_bounds[1] * scale_y)
    white = Image.new("RGBA", master.size, "white")
    white.alpha_composite(scaled_foreground, (offset_x, offset_y))
    return white.convert("RGB")


def save_resized(master: Image.Image, path: Path) -> None:
    with Image.open(path) as existing:
        size = existing.size
    master.resize(size, Image.Resampling.LANCZOS).save(path, optimize=True)


def main() -> None:
    foreground = clean_foreground(Image.open(FOREGROUND_PATH))
    master = rebuild_master(foreground)
    master.save(MASTER_PATH, optimize=True)

    destinations = [
        *sorted((ROOT / "ios/HoopReplay/Assets.xcassets/AppIcon.appiconset").glob("*.png")),
        ROOT / "web/app/icon.png",
        ROOT / "web/app/apple-icon.png",
        *sorted((ROOT / "android/HoopReplay/src/main/res").glob("mipmap-*/ic_launcher.png")),
        *sorted((ROOT / "android/HoopReplay/src/main/res").glob("mipmap-*/ic_launcher_round.png")),
    ]
    for destination in destinations:
        save_resized(master, destination)

    foreground_destinations = sorted(
        (ROOT / "android/HoopReplay/src/main/res").glob(
            "mipmap-*/ic_launcher_foreground.png"
        )
    )
    for destination in foreground_destinations:
        with Image.open(destination) as existing:
            size = existing.size
        foreground.resize(size, Image.Resampling.LANCZOS).save(
            destination, optimize=True
        )


if __name__ == "__main__":
    main()
