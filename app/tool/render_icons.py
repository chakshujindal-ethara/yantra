"""Renders web/favicon.png and web/icons/*.png from the geometry in web/icons/mark.svg.

Run from app/: uv run --with pillow==11.0.0 python tool/render_icons.py
No SVG renderer is needed: the mark is a rounded square and a three-stroke Y, drawn here with the same
numbers as the SVG, at 4x and downsampled for clean edges."""

from pathlib import Path

from PIL import Image, ImageDraw

MAGENTA = (184, 0, 184, 255)
WHITE = (255, 255, 255, 255)
SS = 4  # supersampling


def mark(size: int, *, maskable: bool) -> Image.Image:
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = s / 512
    if maskable:
        # full bleed; the Y shrinks into the 80% safe zone
        d.rectangle([0, 0, s, s], fill=MAGENTA)
        k_y, off = k * 0.72, s * 0.14
    else:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=112 * k, fill=MAGENTA)
        k_y, off = k, 0.0
    width = 60 * k_y

    def p(x: float, y: float) -> tuple[float, float]:
        return (off + x * k_y, off + y * k_y)

    for a, b in [((156, 136), (256, 262)), ((356, 136), (256, 262)), ((256, 262), (256, 380))]:
        d.line([p(*a), p(*b)], fill=WHITE, width=round(width))
    for x, y in [(156, 136), (356, 136), (256, 262), (256, 380)]:
        cx, cy = p(x, y)
        r = width / 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    web = Path(__file__).resolve().parent.parent / "web"
    mark(64, maskable=False).save(web / "favicon.png")
    for n in (192, 512):
        mark(n, maskable=False).save(web / "icons" / f"Icon-{n}.png")
        mark(n, maskable=True).save(web / "icons" / f"Icon-maskable-{n}.png")


if __name__ == "__main__":
    main()
