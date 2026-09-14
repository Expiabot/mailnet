"""Replaces personal data in the store screenshots with fictional equivalents.

Play Store listings are public. The captures show the user's own address and,
worse, the names and addresses of real third parties who never agreed to appear
there. Only those strings are replaced; every figure stays real.
"""

import os

from PIL import Image, ImageDraw, ImageFont

SHOTS = os.path.join(os.path.dirname(__file__), "shots")
OUT = os.path.join(os.path.dirname(__file__), "store")
FONTS = "C:/src/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto"


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, f"Roboto-{weight}.ttf"), size)


def replace(draw, image, box, text, fnt, fill, sample):
    """Paint over `box` with the colour sampled at `sample`, then write `text`
    left-aligned and vertically centred where the original sat."""
    bg = image.getpixel(sample)
    draw.rectangle(box, fill=bg)
    left, top, right, bottom = box
    ascent, descent = fnt.getmetrics()
    y = (top + bottom) / 2 - (ascent + descent) / 2
    draw.text((left, y), text, font=fnt, fill=fill)


def centred(draw, image, centre, radius, text, fnt, fill):
    """Redraws a single avatar letter without touching the circle."""
    cx, cy = centre
    bg = image.getpixel((cx, cy - radius + 6))
    draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=bg)
    w = draw.textlength(text, font=fnt)
    ascent, descent = fnt.getmetrics()
    draw.text((cx - w / 2, cy - (ascent + descent) / 2), text, font=fnt, fill=fill)


WHITE = (255, 255, 255, 255)
GREY = (168, 176, 192, 255)


def main():
    os.makedirs(OUT, exist_ok=True)

    # --- 1. login: the user's own address ---------------------------------
    im = Image.open(os.path.join(SHOTS, "01-connexion.png")).convert("RGBA")
    d = ImageDraw.Draw(im)
    replace(d, im, (110, 1100, 1340, 1200), "vous@exemple.fr",
            font("Regular", 57), WHITE, (1300, 1150))
    im.save(os.path.join(OUT, "01-connexion.png"))

    # --- 2. filters: the same address in the account chip -----------------
    im = Image.open(os.path.join(SHOTS, "02-filtres.png")).convert("RGBA")
    d = ImageDraw.Draw(im)
    replace(d, im, (200, 370, 1340, 450), "vous@exemple.fr",
            font("Regular", 45), (226, 224, 255, 255), (1300, 410))
    im.save(os.path.join(OUT, "02-filtres.png"))

    # --- 3. senders: two real individuals ---------------------------------
    im = Image.open(os.path.join(SHOTS, "03-scan.png")).convert("RGBA")
    d = ImageDraw.Draw(im)
    replace(d, im, (270, 1570, 1340, 1645), "Boutique Zéphyr",
            font("Medium", 60), WHITE, (1300, 1600))
    replace(d, im, (270, 1655, 1340, 1725), "contact@zephyr-shop.fr",
            font("Regular", 47), GREY, (1300, 1690))
    centred(d, im, (167, 1632), 56, "B", font("Bold", 56), WHITE)

    replace(d, im, (270, 2105, 1340, 2180), "Studio Lumen",
            font("Medium", 60), WHITE, (1300, 2140))
    replace(d, im, (270, 2190, 1340, 2260), "webinar@studiolumen.fr",
            font("Regular", 47), GREY, (1300, 2225))
    centred(d, im, (167, 2167), 56, "S", font("Bold", 56), WHITE)
    im.save(os.path.join(OUT, "03-expediteurs.png"))

    # --- 4. results: already free of personal data ------------------------
    Image.open(os.path.join(SHOTS, "04-resultats.png")).convert("RGBA").save(
        os.path.join(OUT, "04-resultats.png"))

    print("écrit dans", OUT)


if __name__ == "__main__":
    main()
