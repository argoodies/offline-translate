#!/usr/bin/env python3
"""生成 App 图标（1024×1024）。

图形语言沿用翻译类 app 的惯例：左侧拉丁字母、右侧汉字，一眼能认出用途。
iOS 自己会切圆角，所以这里画满整个方形、不留透明边 —— 带 alpha 的图标会被 App Store 拒。
"""
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# 靛蓝 → 青，深色背景让白色字形在浅色和深色壁纸上都立得住。
TOP = (46, 58, 138)
BOTTOM = (14, 132, 150)

CJK_BOLD = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
LATIN_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def vertical_gradient(size, top, bottom):
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        ratio = y / (size - 1)
        draw.line(
            [(0, y), (size, y)],
            fill=tuple(round(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)),
        )
    return image


def draw_centered(draw, text, font, center, fill):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    draw.text(
        (center[0] - (right - left) / 2 - left, center[1] - (bottom - top) / 2 - top),
        text,
        font=font,
        fill=fill,
    )


def main():
    image = vertical_gradient(SIZE, TOP, BOTTOM)
    draw = ImageDraw.Draw(image, "RGBA")

    latin = ImageFont.truetype(LATIN_BOLD, 340)
    # index=0 选中 ttc 里的简体中文字形。
    cjk = ImageFont.truetype(CJK_BOLD, 320, index=0)

    # iOS 会按 ~22% 半径切圆角，字形必须离边至少 10% 才不会被啃掉。
    draw_centered(draw, "A", latin, (SIZE * 0.33, SIZE * 0.40), (255, 255, 255, 255))
    draw_centered(draw, "文", cjk, (SIZE * 0.68, SIZE * 0.59), (255, 255, 255, 190))

    # 一道细下划线，把两个字形收在同一个"词条"里，顺带压住构图重心。
    bar_width, bar_height = SIZE * 0.34, SIZE * 0.025
    x0 = (SIZE - bar_width) / 2
    y0 = SIZE * 0.79
    draw.rounded_rectangle(
        [x0, y0, x0 + bar_width, y0 + bar_height],
        radius=bar_height / 2,
        fill=(255, 255, 255, 140),
    )

    image.save(OUTPUT)
    print(f"wrote {OUTPUT} ({image.size[0]}×{image.size[1]})")


if __name__ == "__main__":
    main()
