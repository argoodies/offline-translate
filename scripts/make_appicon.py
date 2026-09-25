#!/usr/bin/env python3
"""生成 App 图标和 app 内用的 logo。

标记是一个原创的 Q 字形：粗圆环加一道斜尾。

刻意没有照搬 Qwen 的标志 —— 那是阿里巴巴的注册商标，拿别人的商标做自己 app 的图标
会被 App Review 按 Guideline 5.2.5 拒，也有实打实的法律风险。Q 这个字母本身是通用字形，
自己画没问题。

iOS 会给 App 图标切圆角，所以那张画满整个方形、不留透明边 —— 带 alpha 的图标会被
App Store 拒。app 内那张反过来要透明底。
"""
import math

from PIL import Image, ImageDraw

ICON_SIZE = 1024
LOGO_SIZE = 512
ICON_OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
LOGO_OUTPUT = "Resources/Assets.xcassets/Logo.imageset/Logo.png"

# 底色。给一点几乎看不见的渐变，纯平的白在主屏上会显得发死。
TOP = (255, 255, 255)
BOTTOM = (244, 244, 246)
INK = (0, 0, 0)

# Q 的几何，全是画布比例。
RING_CENTER = (0.5, 0.465)
RING_RADIUS = 0.255      # 圆环中线的半径
RING_WIDTH = 0.105       # 环的粗细
# 尾巴的起止，单位是环中线半径 r 的倍数。环外缘在 (r + RING_WIDTH/2) / r ≈ 1.21 处，
# 所以 OUTER 必须明显大于它，否则尾巴整根埋在环里，Q 就成了 O。
TAIL_INNER = 0.72
TAIL_OUTER = 1.46
TAIL_ANGLE = 42          # 斜尾的方向，从正右往下量
TAIL_WIDTH = 0.105


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


def q_mask(size):
    """把 Q 画成一张遮罩，之后拿它往底上贴颜色。

    画成遮罩而不是直接画色块，是为了让图标和 app 内 logo 共用同一套几何 ——
    一个贴在渐变底上，一个贴在透明底上。
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)

    cx, cy = RING_CENTER[0] * size, RING_CENTER[1] * size
    r = RING_RADIUS * size
    half = RING_WIDTH * size / 2

    # 圆环：外圆填实，再把内圆挖掉。
    draw.ellipse([cx - r - half, cy - r - half, cx + r + half, cy + r + half], fill=255)
    draw.ellipse([cx - r + half, cy - r + half, cx + r - half, cy + r - half], fill=0)

    # 斜尾：沿角度堆一串圆点。不用 draw.line —— 它是平头的，端点要另外补圆，
    # 堆圆点顺手就把两头做成圆的了。
    angle = math.radians(TAIL_ANGLE)
    tail_r = TAIL_WIDTH * size / 2
    steps = 240
    for i in range(steps + 1):
        t = TAIL_INNER + (TAIL_OUTER - TAIL_INNER) * i / steps
        x = cx + r * t * math.cos(angle)
        y = cy + r * t * math.sin(angle)
        draw.ellipse([x - tail_r, y - tail_r, x + tail_r, y + tail_r], fill=255)

    return mask


def main():
    # 先在 4 倍尺寸上画再缩回去 —— 便宜的抗锯齿，边缘不会有台阶。
    supersample = 4

    canvas = ICON_SIZE * supersample
    icon = vertical_gradient(canvas, TOP, BOTTOM)
    icon = Image.composite(Image.new("RGB", (canvas, canvas), INK), icon, q_mask(canvas))
    icon.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS).save(ICON_OUTPUT)
    print(f"wrote {ICON_OUTPUT} ({ICON_SIZE}×{ICON_SIZE})")

    # app 内那张要透明底，才能贴在任何背景上。
    canvas = LOGO_SIZE * supersample
    logo = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    logo.paste(Image.new("RGBA", (canvas, canvas), INK + (255,)), mask=q_mask(canvas))
    logo.resize((LOGO_SIZE, LOGO_SIZE), Image.LANCZOS).save(LOGO_OUTPUT)
    print(f"wrote {LOGO_OUTPUT} ({LOGO_SIZE}×{LOGO_SIZE})")


if __name__ == "__main__":
    main()
