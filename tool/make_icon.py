"""Draws the MailNet launcher icon.

Kept in the repo so the icon can be regenerated at any size instead of being an
opaque binary nobody can edit. Run: python tool/make_icon.py
"""

import math
import os

from PIL import Image, ImageDraw

SIZE = 1024
INDIGO = (79, 70, 229, 255)      # --primary from the web app
WHITE = (255, 255, 255, 255)
AMBER = (251, 191, 36, 255)      # the one warm accent, so the icon reads as
                                 # "cleaned up" and stands out in a drawer of
                                 # blue mail icons

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "icon")


def sparkle(draw, cx, cy, outer, colour):
    """A four-point star: alternating far and near vertices."""
    inner = outer * 0.24
    points = []
    for i in range(8):
        angle = math.radians(i * 45 - 90)
        radius = outer if i % 2 == 0 else inner
        points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    draw.polygon(points, fill=colour)


def envelope(draw, left, top, right, bottom, crease_colour):
    """A closed envelope; the flap is a crease, not a separate shape."""
    radius = int((right - left) * 0.07)
    draw.rounded_rectangle([left, top, right, bottom], radius=radius, fill=WHITE)

    # The flap folds from both top corners down to the middle.
    inset = radius * 0.9
    width = int((right - left) * 0.062)
    draw.line(
        [(left + inset, top + inset), ((left + right) / 2, (top + bottom) * 0.52),
         (right - inset, top + inset)],
        fill=crease_colour,
        width=width,
        joint="curve",
    )


def draw_mark(canvas_size, scale, background):
    """The mark on its own canvas. `scale` shrinks it into the adaptive safe zone."""
    image = Image.new("RGBA", (canvas_size, canvas_size), background)
    draw = ImageDraw.Draw(image)

    span = canvas_size * scale
    offset = (canvas_size - span) / 2

    # The envelope carries the shape; the sparkles tuck into the corner it
    # leaves free, close enough to read as one mark rather than two objects.
    left = offset + span * 0.04
    right = offset + span * 0.87
    top = offset + span * 0.30
    bottom = offset + span * 0.92
    envelope(draw, left, top, right, bottom, INDIGO)

    sparkle(draw, offset + span * 0.855, offset + span * 0.185, span * 0.150, AMBER)
    sparkle(draw, offset + span * 0.655, offset + span * 0.075, span * 0.062, AMBER)

    return image


def main():
    os.makedirs(OUT, exist_ok=True)

    # Full bleed: both stores apply their own mask.
    draw_mark(SIZE, 0.84, INDIGO).save(os.path.join(OUT, "icon.png"))

    # Adaptive foreground: transparent, and small enough that Android's circular
    # or squircle mask never clips the mark.
    draw_mark(SIZE, 0.58, (0, 0, 0, 0)).save(os.path.join(OUT, "icon_foreground.png"))

    print("écrit:", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
