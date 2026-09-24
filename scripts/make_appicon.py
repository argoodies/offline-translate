#!/usr/bin/env python3
"""生成 App 图标（1024×1024）—— 飞行模式。

沿用 iOS 控制中心里飞行模式那颗按钮的视觉：系统橙渐变打底，正中一架朝上的白色飞机。
iOS 自己会切圆角，所以这里画满整个方形、不留透明边 —— 带 alpha 的图标会被 App Store 拒。
"""
from PIL import Image, ImageDraw

SIZE = 1024
OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# 系统橙的上下两端，深色在下，让图标在浅色壁纸上也压得住。
TOP = (255, 176, 64)
BOTTOM = (243, 112, 0)

# 朝上的飞机轮廓，右半边。坐标归一化到 -1…1，x 向右、y 向上，机头在 (0, 1)。
# 左半边由镜像生成，保证绝对对称。
HALF_OUTLINE = [
    (0.00, 1.00),    # 机头
    (0.075, 0.70),
    (0.095, 0.28),   # 翼根前缘
    (0.92, -0.12),   # 右翼尖前缘
    (0.92, -0.34),   # 右翼尖后缘
    (0.095, -0.28),  # 翼根后缘
    (0.075, -0.60),
    (0.30, -0.80),   # 右平尾尖
    (0.30, -0.95),
    (0.00, -0.87),   # 尾端中点。留一点 V 形缺口，但别深到看着像两条腿。
]


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


def airplane_polygon(center, scale):
    """把归一化轮廓镜像成完整机身，再映射到像素坐标。"""
    right = HALF_OUTLINE
    # 跳过首尾两个点（机头和尾端中点都在中轴上，镜像会重复）。
    left = [(-x, y) for x, y in reversed(right[1:-1])]
    cx, cy = center
    # 图像坐标 y 向下，所以取负。
    return [(cx + x * scale, cy - y * scale) for x, y in right + left]


def main():
    # 先在 4 倍尺寸上画再缩回去 —— 便宜的抗锯齿，边缘不会有台阶。
    supersample = 4
    canvas = SIZE * supersample

    image = vertical_gradient(canvas, TOP, BOTTOM)
    draw = ImageDraw.Draw(image)

    # 0.34 的缩放让机翼展到约 63% 宽度，四周留够 iOS 圆角要啃掉的余量。
    draw.polygon(
        airplane_polygon(center=(canvas / 2, canvas / 2), scale=canvas * 0.34),
        fill=(255, 255, 255),
    )

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image.save(OUTPUT)
    print(f"wrote {OUTPUT} ({image.size[0]}×{image.size[1]})")


if __name__ == "__main__":
    main()
