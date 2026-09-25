#!/usr/bin/env python3
"""生成 App 图标（1024×1024）：白底，正中一道黑色漩涡。

iOS 自己会切圆角，所以这里画满整个方形、不留透明边 —— 带 alpha 的图标会被 App Store 拒。
"""
import math

from PIL import Image, ImageDraw

SIZE = 1024
OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# 底色。给一点几乎看不见的渐变，纯平的白在主屏上会显得发死。
TOP = (255, 255, 255)
BOTTOM = (244, 244, 246)

INK = (0, 0, 0)

# 漩涡。数值都是画布比例。
# 圈距 =（RADIUS - INNER）/ TURNS，要明显大于 WIDTH，否则相邻两圈会粘在一起糊成色块。
RADIUS = 0.340
INNER = 0.060   # 起笔半径。从正中心绕的话头两圈会挤成一坨黑，留个小空心当漩涡眼。
TURNS = 2.5     # 起笔在 -90°，转完整圈数正好收在正下方。
WIDTH = 0.058


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


def spiral_points(center, inner, radius, turns, samples=4000):
    """阿基米德螺旋：半径随角度线性增长，圈距才会均匀。"""
    cx, cy = center
    total = turns * 2 * math.pi
    points = []
    for i in range(samples + 1):
        angle = total * i / samples
        r = inner + (radius - inner) * angle / total
        points.append((cx + r * math.cos(angle - math.pi / 2),
                       cy + r * math.sin(angle - math.pi / 2)))
    return points


def draw_spiral(draw, center, inner, radius, turns, width):
    """沿路径堆一串重叠的圆。

    不用 draw.line：它把粗线拆成一段段独立的矩形，拐弯处的接缝糊不平，
    在这种曲率上会留下一圈锯齿。采样够密时，圆点叠出来的边缘是光滑的。
    """
    r = width / 2
    for x, y in spiral_points(center, inner, radius, turns):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=INK)


def main():
    # 先在 4 倍尺寸上画再缩回去 —— 便宜的抗锯齿，边缘不会有台阶。
    supersample = 4
    canvas = SIZE * supersample

    image = vertical_gradient(canvas, TOP, BOTTOM)
    draw_spiral(
        ImageDraw.Draw(image),
        center=(canvas / 2, canvas / 2),
        inner=INNER * canvas,
        radius=RADIUS * canvas,
        turns=TURNS,
        width=WIDTH * canvas,
    )

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image.save(OUTPUT)
    print(f"wrote {OUTPUT} ({image.size[0]}×{image.size[1]})")


if __name__ == "__main__":
    main()
