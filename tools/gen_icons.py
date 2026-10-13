"""AnyShare logo generator (Stage 3, 2026-10-13).

Draws the new brand mark — two opposing arc-arrows forming an exchange ring,
deliberately distinct from LocalSend's dashed-ring-with-solid-center mark —
and regenerates every icon asset in the repo (assets/img, web icons, Android
mipmaps incl. adaptive foreground/monochrome/quicktile, TV banner, Windows
ico). Run from repo root:  python tools/gen_icons.py
"""
from PIL import Image, ImageDraw
import math, os

TEAL = (0, 128, 128, 255)
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)
S = 4  # supersample factor


def _arc_arrow(draw, cx, cy, r_in, r_out, a1, a2, color, tip_deg=20):
    """One arc band drawn as a sampled polygon. The end is cut diagonally:
    the outer edge runs `tip_deg` ahead of the inner edge, so the arrow tip
    lies ON the outer arc itself — band and tip share one circle."""
    steps = 48
    pts = []
    for i in range(steps + 1):  # outer edge, a1 -> a2
        ang = a1 + (a2 - a1) * i / steps
        rad = math.radians(ang)
        pts.append((cx + r_out * math.cos(rad), cy + r_out * math.sin(rad)))
    for i in range(steps + 1):  # inner edge, (a2 - tip_deg) -> a1
        ang = (a2 - tip_deg) - ((a2 - tip_deg) - a1) * i / steps
        rad = math.radians(ang)
        pts.append((cx + r_in * math.cos(rad), cy + r_in * math.sin(rad)))
    draw.polygon(pts, fill=color)


def draw_glyph(draw, color, size, thick=False):
    """Exchange-ring glyph centered in a `size` box (already supersampled).
    `thick` boosts band width and tip angle for small sizes (<=64px)."""
    c = size / 2
    r_out = size * (0.44 if thick else 0.39)
    band = size * (0.21 if thick else 0.155)
    tip = 26 if thick else 20
    r_in = r_out - band
    _arc_arrow(draw, c, c, r_in, r_out, 100, 192, color, tip_deg=tip)
    _arc_arrow(draw, c, c, r_in, r_out, 280, 372, color, tip_deg=tip)


def glyph(color, size_px):
    img = Image.new('RGBA', (size_px * S, size_px * S), (0, 0, 0, 0))
    draw_glyph(ImageDraw.Draw(img), color, size_px * S, thick=size_px <= 64)
    return img.resize((size_px, size_px), Image.LANCZOS)


def with_white_bg(g, scale=1.0, radius_frac=0.0):
    size = g.size[0]
    img = Image.new('RGBA', (size, size), (255, 255, 255, 255))
    if radius_frac > 0:
        mask = Image.new('L', (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=int(size * radius_frac), fill=255)
        img.putalpha(mask)
    g2 = g.resize((int(size * scale), int(size * scale)), Image.LANCZOS)
    off = (size - g2.size[0]) // 2
    img.alpha_composite(g2, (off, off))
    return img


def write(path, img):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print('wrote', path, img.size)


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'app')

teal512 = glyph(TEAL, 512)
white512 = glyph(WHITE, 512)

# --- app/assets/img -------------------------------------------------------
for size in (512, 256, 128, 32):
    write(f'{APP}/assets/img/logo-{size}.png', glyph(TEAL, size))
write(f'{APP}/assets/img/logo-512-white.png', white512)
write(f'{APP}/assets/img/logo-32-white.png', glyph(WHITE, 32))
write(f'{APP}/assets/img/logo-32-black.png', glyph(BLACK, 32))
ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
teal512.save(f'{APP}/assets/img/logo.ico', format='ICO', sizes=ico_sizes)
print('wrote', f'{APP}/assets/img/logo.ico')

# --- web ------------------------------------------------------------------
for size in (192, 512):
    write(f'{APP}/web/icons/Icon-{size}.png', with_white_bg(teal512.resize((size, size), Image.LANCZOS), scale=0.74))
    write(f'{APP}/web/icons/Icon-maskable-{size}.png', with_white_bg(teal512.resize((size, size), Image.LANCZOS), scale=0.55))

# --- windows --------------------------------------------------------------
teal512.save(f'{APP}/windows/runner/resources/app_icon.ico', format='ICO', sizes=ico_sizes)
print('wrote', f'{APP}/windows/runner/resources/app_icon.ico')

# --- android --------------------------------------------------------------
densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for dpi, k in densities.items():
    d = f'{APP}/android/app/src/main/res/mipmap-{dpi}'
    # legacy launcher: transparent bg, teal glyph nearly full-bleed
    write(f'{d}/ic_launcher.png', glyph(TEAL, int(48 * k)))
    # round: white circle + teal glyph
    size = int(48 * k)
    round_img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, size - 1, size - 1], fill=255)
    white = Image.new('RGBA', (size, size), (255, 255, 255, 255))
    round_img.paste(white, (0, 0), mask)
    g = glyph(TEAL, int(size * 0.78))
    off = (size - g.size[0]) // 2
    round_img.alpha_composite(g, (off, off))
    write(f'{d}/ic_launcher_round.png', round_img)
    # adaptive foreground/monochrome/quicktile: 108dp grid, glyph in safe zone
    grid = int(108 * k)
    write(f'{d}/ic_launcher_foreground.png', glyph(TEAL, int(grid * 0.58))
          .resize((grid, grid), Image.LANCZOS))
    mono = Image.new('LA', (grid, grid), (0, 0))
    g = glyph(WHITE, int(grid * 0.58)).resize((grid, grid), Image.LANCZOS)
    mono.paste((255, 255), mask=Image.open(f'{d}/ic_launcher_foreground.png').split()[-1]) if False else None
    # monochrome: white glyph alpha only
    white_glyph = glyph(WHITE, grid)
    mono = white_glyph.convert('LA')
    write(f'{d}/ic_launcher_monochrome.png', mono)
    write(f'{d}/ic_launcher_quicktile_foreground.png', glyph(WHITE, grid))

# --- TV banner ------------------------------------------------------------
banner = Image.new('RGBA', (320, 180), (255, 255, 255, 255))
g = glyph(TEAL, 120)
banner.alpha_composite(g, ((320 - 120) // 2, (180 - 120) // 2))
write(f'{APP}/android/app/src/main/res/drawable/banner.png', banner)

print('ALL DONE')
