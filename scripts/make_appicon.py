#!/usr/bin/env python3
"""生成 App 图标（1024×1024）—— 飞行模式。

白底黑飞机，跟 app 内部的配色一致。

注意这架飞机是这里手写的多边形，不是 SF Symbols 的字形。SF Symbols 的许可明确禁止
把 symbol（以及「实质上或容易混淆地相似」的字形）用作 app icon，所以不能直接搬 —— 飞机
剪影本身是通用符号，自己画没问题。

iOS 自己会切圆角，所以这里画满整个方形、不留透明边 —— 带 alpha 的图标会被 App Store 拒。
"""
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUTPUT = "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# 底色。给一点几乎看不见的渐变，纯平的白在主屏上会显得发死。
TOP = (255, 255, 255)
BOTTOM = (244, 244, 246)

PLANE = (0, 0, 0)

# 飞机轮廓的一半。坐标归一化到 -1…1，先按机头朝上定义（x 向右、y 向上，机头在 (0, 1)），
# 对称轴是纵轴，另一半镜像出来 —— 这样比直接写朝右的形状好读，也保证绝对对称。
# 最后在 airplane_polygon 里整体转 90° 变成机头朝右。
HALF_OUTLINE = [
    (0.00, 0.94),    # 机头。别太尖 —— 横过来之后细长的尖刺很扎眼
    (0.085, 0.58),
    (0.105, 0.26),   # 翼根前缘
    (0.70, -0.20),   # 翼尖前缘：明显后掠，翼尖压到机身之后
    (0.70, -0.33),   # 翼尖后缘
    (0.105, -0.26),  # 翼根后缘
    (0.085, -0.58),
    (0.25, -0.78),   # 平尾尖
    (0.25, -0.91),
    (0.00, -0.84),   # 尾端中点。留一点 V 形缺口，但别深到看着像两条腿。
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
    """把归一化轮廓镜像成完整机身，转成机头朝右，再映射到像素坐标。"""
    right = HALF_OUTLINE
    # 跳过首尾两个点（机头和尾端中点都在中轴上，镜像会重复）。
    left = [(-x, y) for x, y in reversed(right[1:-1])]
    cx, cy = center
    points = []
    for x, y in right + left:
        # 顺时针转 90°：机头从 (0, 1) 落到 (1, 0)。
        rx, ry = y, -x
        # 图像坐标 y 向下，所以取负。
        points.append((cx + rx * scale, cy - ry * scale))
    return points


def rounded_mask(size, polygon, radius):
    """画出多边形并把尖角磨圆。

    先模糊再按阈值切回硬边：模糊把角上的能量摊开，阈值再切一刀，等效于给每个顶点
    倒了个半径约 radius 的圆角。比手工在每个顶点插入贝塞尔控制点省事得多。
    """
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius))
    return mask.point(lambda v: 255 if v >= 128 else 0)


def main():
    # 先在 4 倍尺寸上画再缩回去 —— 便宜的抗锯齿，边缘不会有台阶。
    supersample = 4
    canvas = SIZE * supersample

    image = vertical_gradient(canvas, TOP, BOTTOM)

    # 机身转横之后比朝上时扁，放大到 0.40 才不会在画面里显得小。
    polygon = airplane_polygon(center=(canvas / 2, canvas / 2), scale=canvas * 0.40)
    mask = rounded_mask(canvas, polygon, radius=canvas * 0.012)

    plane = Image.new("RGB", (canvas, canvas), PLANE)
    image = Image.composite(plane, image, mask)

    image = image.resize((SIZE, SIZE), Image.LANCZOS)
    image.save(OUTPUT)
    print(f"wrote {OUTPUT} ({image.size[0]}×{image.size[1]})")


if __name__ == "__main__":
    main()
