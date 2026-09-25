#!/usr/bin/env python3
"""生成 App 图标和 app 内用的 logo：白底黑字 QW。

iOS 会给 App 图标切圆角，所以那张画满整个方形、不留透明边 —— 带 alpha 的图标会被
App Store 拒。app 内那张反过来要透明底。
"""
from PIL import Image, ImageDraw, ImageFont

ICON_SIZE = 1024
LOGO_SIZE = 512
ICON_OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
LOGO_OUTPUT = "Resources/Assets.xcassets/Logo.imageset/Logo.png"

# 底色。给一点几乎看不见的渐变，纯平的白在主屏上会显得发死。
TOP = (255, 255, 255)
BOTTOM = (244, 244, 246)
INK = (0, 0, 0)

TEXT = "QW"
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
# 字宽占画布的比例。字母标横向铺开才够醒目，0.72 之外仍留得下 iOS 圆角要啃掉的边。
TEXT_WIDTH_RATIO = 0.72
# 视觉居中：Q 的尾巴挂在基线以下，纯按外框居中会显得整体偏上。
BASELINE_NUDGE = -0.015


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


def fitted_font(size):
    """二分出能让字宽正好占到目标比例的字号。

    直接按经验值给字号，换个字体或改文案就得重调；按宽度反推省这一步。
    """
    target = size * TEXT_WIDTH_RATIO
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    low, high = 1, size
    while low < high:
        mid = (low + high + 1) // 2
        font = ImageFont.truetype(FONT_PATH, mid)
        left, _, right, _ = probe.textbbox((0, 0), TEXT, font=font)
        if right - left <= target:
            low = mid
        else:
            high = mid - 1
    return ImageFont.truetype(FONT_PATH, low)


def text_mask(size):
    """把 QW 画成一张遮罩，之后拿它往底上贴颜色。

    画成遮罩而不是直接画字，是为了让图标和 app 内 logo 共用同一套几何 ——
    一个贴在渐变底上，一个贴在透明底上。
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    font = fitted_font(size)
    # 按字形的实际外框居中，不用 anchor —— 字体自带的行高会把重心带偏。
    left, top, right, bottom = draw.textbbox((0, 0), TEXT, font=font)
    x = (size - (right - left)) / 2 - left
    y = (size - (bottom - top)) / 2 - top + BASELINE_NUDGE * size
    draw.text((x, y), TEXT, font=font, fill=255)
    return mask


def main():
    # 先在 4 倍尺寸上画再缩回去 —— 便宜的抗锯齿，边缘不会有台阶。
    supersample = 4

    canvas = ICON_SIZE * supersample
    icon = vertical_gradient(canvas, TOP, BOTTOM)
    icon = Image.composite(Image.new("RGB", (canvas, canvas), INK), icon, text_mask(canvas))
    icon.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS).save(ICON_OUTPUT)
    print(f"wrote {ICON_OUTPUT} ({ICON_SIZE}×{ICON_SIZE})")

    # app 内那张要透明底，才能贴在任何背景上。
    canvas = LOGO_SIZE * supersample
    logo = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    logo.paste(Image.new("RGBA", (canvas, canvas), INK + (255,)), mask=text_mask(canvas))
    logo.resize((LOGO_SIZE, LOGO_SIZE), Image.LANCZOS).save(LOGO_OUTPUT)
    print(f"wrote {LOGO_OUTPUT} ({LOGO_SIZE}×{LOGO_SIZE})")


if __name__ == "__main__":
    main()
