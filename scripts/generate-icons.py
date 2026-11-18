"""生成 WorkManager 占位应用图标（自绘，不使用第三方素材）。

用法：
    python scripts/generate-icons.py

输出到 src-tauri/icons/：
    32x32.png / 128x128.png / 128x128@2x.png / icon.png / icon.ico

这些图标只用于 Tauri Windows 构建与窗口显示；后续视觉设计任务可替换。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "src-tauri" / "icons"

BACKGROUND_TOP = (30, 58, 138)  # #1e3a8a
BACKGROUND_BOTTOM = (59, 130, 246)  # #3b82f6
GLYPH = (248, 250, 252)  # #f8fafc


def draw_master(size: int = 1024) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # 垂直渐变背景裁剪为圆角矩形。
    gradient = Image.new("RGBA", (1, size))
    for y in range(size):
        ratio = y / max(size - 1, 1)
        color = tuple(
            round(BACKGROUND_TOP[channel] * (1 - ratio) + BACKGROUND_BOTTOM[channel] * ratio)
            for channel in range(3)
        )
        gradient.putpixel((0, y), (*color, 255))
    gradient = gradient.resize((size, size))

    radius = round(size * 0.22)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    image.paste(gradient, (0, 0), mask)

    # 内描边提升小尺寸下的辨识度。
    inset = round(size * 0.045)
    draw.rounded_rectangle(
        (inset, inset, size - 1 - inset, size - 1 - inset),
        radius=radius - inset,
        outline=(255, 255, 255, 70),
        width=max(2, round(size * 0.012)),
    )

    # 白色 “W” 折线。
    stroke = max(2, round(size * 0.105))
    points = [
        (size * 0.235, size * 0.315),
        (size * 0.385, size * 0.700),
        (size * 0.500, size * 0.475),
        (size * 0.615, size * 0.700),
        (size * 0.765, size * 0.315),
    ]
    draw.line(points, fill=GLYPH, width=stroke, joint="curve")
    # 折线端点补圆，避免斜接缺口。
    r = stroke / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=GLYPH)

    return image


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    master = draw_master(1024)

    sizes = {
        "icon.png": 512,
        "128x128@2x.png": 256,
        "128x128.png": 128,
        "32x32.png": 32,
    }
    for filename, size in sizes.items():
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(ICON_DIR / filename, format="PNG")
        print(f"wrote {ICON_DIR / filename} ({size}x{size})")

    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    master.save(ICON_DIR / "icon.ico", format="ICO", sizes=ico_sizes)
    print(f"wrote {ICON_DIR / 'icon.ico'} {ico_sizes}")


if __name__ == "__main__":
    main()
