"""Draws the Play Store feature graphic (1024 x 500).

Same palette and mark as the launcher icon, so the listing reads as one thing.
Run: python tool/make_banner.py
"""

import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

import make_icon

W, H = 1024, 500
INDIGO = (79, 70, 229, 255)
INDIGO_DEEP = (58, 50, 190, 255)
WHITE = (255, 255, 255, 255)
LAVENDER = (199, 195, 255, 255)
AMBER = (251, 191, 36, 255)

FONTS = "C:/src/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto"
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "store")

# Illustrative categories rather than real brands: a feature graphic must not
# borrow someone else's trademark to sell the app.
ROWS = [
    ("Newsletters", "1 240 mails", "210 Mo"),
    ("Promotions", "860 mails", "74 Mo"),
    ("Réseaux sociaux", "415 mails", "33 Mo"),
]


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, f"Roboto-{weight}.ttf"), size)


def background(image):
    """Indigo ground, lit from behind the mark so the eye starts on the left.

    A real radial gradient rather than stacked ellipses: concentric shapes leave
    a hard arc where the outermost one ends, which reads as a mistake.
    """
    span = 1500
    falloff = ImageOps.invert(
        Image.radial_gradient("L").resize((span, span), Image.BICUBIC)
    )
    mask = Image.new("L", (W, H), 0)
    mask.paste(falloff, (210 - span // 2, 210 - span // 2))
    mask = mask.filter(ImageFilter.GaussianBlur(24))

    image.paste(
        Image.composite(
            Image.new("RGBA", (W, H), INDIGO),
            Image.new("RGBA", (W, H), INDIGO_DEEP),
            mask,
        ),
        (0, 0),
    )


def mark(image):
    """The launcher icon's own mark, on the tile it wears on a home screen."""
    tile = Image.new("RGBA", (240, 240), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle([0, 0, 239, 239], radius=54, fill=INDIGO_DEEP)
    tile.alpha_composite(make_icon.draw_mark(240, 0.74, (0, 0, 0, 0)))
    tile = tile.resize((116, 116), Image.LANCZOS)
    image.alpha_composite(tile, (64, 150))


def wordmark(draw):
    draw.text((202, 168), "MailNet", font=font("Bold", 80), fill=WHITE)
    draw.text(
        (66, 300),
        "Faites de la place dans",
        font=font("Regular", 34),
        fill=LAVENDER,
    )
    draw.text(
        (66, 346),
        "votre boîte mail.",
        font=font("Regular", 34),
        fill=LAVENDER,
    )


def sender_rows(image):
    """An abstraction of the app's flagship screen — enough to read the idea at
    a glance, without passing a screenshot off as artwork."""
    card = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(card)

    left, width, height, gap = 596, 372, 104, 26
    top = (H - (len(ROWS) * height + (len(ROWS) - 1) * gap)) // 2

    for index, (label, count, size) in enumerate(ROWS):
        y = top + index * (height + gap)
        draw.rounded_rectangle(
            [left, y, left + width, y + height],
            radius=22,
            fill=(255, 255, 255, 28),
        )
        draw.ellipse([left + 22, y + 26, left + 74, y + 78], fill=(255, 255, 255, 62))
        draw.text(
            (left + 94, y + 24),
            label,
            font=font("Medium", 27),
            fill=WHITE,
        )
        draw.text(
            (left + 94, y + 58),
            f"{count} · {size}",
            font=font("Regular", 23),
            fill=AMBER,
        )

    image.alpha_composite(card)


def main():
    image = Image.new("RGBA", (W, H), INDIGO)
    background(image)
    mark(image)
    sender_rows(image)
    wordmark(ImageDraw.Draw(image))

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "feature-graphic-1024x500.png")
    # Play refuses an alpha channel on the feature graphic.
    image.convert("RGB").save(path)
    print("écrit:", os.path.abspath(path))


if __name__ == "__main__":
    main()
