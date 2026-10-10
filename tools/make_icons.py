#!/usr/bin/env python3
"""Generates the iCam app icons (iOS + macOS) and asset catalogs.

Run from the repository root:  python3 tools/make_icons.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def draw_icon(size, rounded):
    s = 4  # supersample
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Background gradient (deep blue → near black).
    bg = Image.new("RGBA", (W, W))
    top, bottom = (40, 92, 255, 255), (12, 18, 48, 255)
    px = bg.load()
    for y in range(W):
        c = lerp(top, bottom, y / (W - 1))
        for x in range(W):
            px[x, y] = c
    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    if rounded:
        inset = int(W * 0.098)  # macOS icon grid: 824/1024 body
        radius = int((W - 2 * inset) * 0.225)
        md.rounded_rectangle([inset, inset, W - inset, W - inset], radius=radius, fill=255)
        shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        sd.rounded_rectangle([inset, inset + int(W * 0.012), W - inset, W - inset + int(W * 0.012)],
                             radius=radius, fill=(0, 0, 0, 110))
        shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.012))
        img.alpha_composite(shadow)
    else:
        md.rectangle([0, 0, W, W], fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    cx, cy = W / 2, W / 2
    unit = W / 1024

    # Phone body (landscape) with camera bump, like an iPhone used as webcam.
    pw, ph = 600 * unit, 330 * unit
    d.rounded_rectangle([cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2],
                        radius=70 * unit, fill=(245, 247, 255, 255))
    # Camera module.
    mx, my, ms = cx + pw / 2 - 230 * unit, cy - ph / 2 + 40 * unit, 190 * unit
    d.rounded_rectangle([mx, my, mx + ms, my + ms], radius=40 * unit, fill=(30, 36, 60, 255))
    for (ox, oy) in [(0.29, 0.29), (0.29, 0.71), (0.71, 0.5)]:
        r = 31 * unit
        lx, ly = mx + ms * ox, my + ms * oy
        d.ellipse([lx - r, ly - r, lx + r, ly + r], fill=(10, 12, 20, 255))
        r2 = 13 * unit
        d.ellipse([lx - r2, ly - r2, lx + r2, ly + r2], fill=(70, 110, 255, 255))
    # Live dot.
    r = 26 * unit
    lx, ly = cx - pw / 2 + 80 * unit, cy - ph / 2 + 80 * unit
    d.ellipse([lx - r, ly - r, lx + r, ly + r], fill=(255, 59, 48, 255))

    # Signal arcs below.
    for i, rad in enumerate([120, 190]):
        rr = rad * unit
        acx, acy = cx, cy + ph / 2 + 10 * unit
        d.arc([acx - rr, acy - rr * 0.55, acx + rr, acy + rr * 0.55], start=30, end=150,
              fill=(255, 255, 255, 200 - i * 70), width=int(22 * unit))

    return img.resize((size, size), Image.LANCZOS)


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def ios_assets():
    base = os.path.join(ROOT, "iOS/Resources/Assets.xcassets")
    icon = os.path.join(base, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    draw_icon(1024, rounded=False).convert("RGB").save(os.path.join(icon, "AppIcon-1024.png"))
    write_json(os.path.join(base, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    write_json(os.path.join(icon, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}})
    color = os.path.join(base, "LaunchBackground.colorset")
    os.makedirs(color, exist_ok=True)
    write_json(os.path.join(color, "Contents.json"), {
        "colors": [{"color": {"color-space": "srgb", "components": {
            "alpha": "1.000", "red": "0.000", "green": "0.000", "blue": "0.000"}}, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1}})
    accent(base)


def accent(base):
    color = os.path.join(base, "AccentColor.colorset")
    os.makedirs(color, exist_ok=True)
    write_json(os.path.join(color, "Contents.json"), {
        "colors": [{"color": {"color-space": "srgb", "components": {
            "alpha": "1.000", "red": "0.200", "green": "0.420", "blue": "1.000"}}, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1}})


def mac_assets():
    base = os.path.join(ROOT, "macOS/App/Resources/Assets.xcassets")
    icon = os.path.join(base, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    write_json(os.path.join(base, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    images = []
    master = draw_icon(1024, rounded=True)
    for pt in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(icon, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(os.path.join(icon, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})
    accent(base)


if __name__ == "__main__":
    ios_assets()
    mac_assets()
    print("Icons written.")
