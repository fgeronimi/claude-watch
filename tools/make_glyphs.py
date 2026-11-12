#!/usr/bin/env python3
"""Génère lib/glyphs.dat : les masques alpha des caractères dessinés dans l'icône
de la barre de menus. Outil de développement, à relancer seulement pour changer
de police ou de taille. Demande Pillow et la police Inter.

    python3 tools/make_glyphs.py [dossier des polices Inter]
"""
import base64
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/opentype/inter"
SCALE = 2          # rendu Retina
CELL_H = 16 * SCALE  # hauteur de l'icône, en pixels

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "glyphs.dat")


def font(name, size_pt):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), int(round(size_pt * SCALE)))


def render(text, fnt, full_height):
    """Masque alpha de `text`. full_height : garde la hauteur de la cellule (ligne de
    base commune) ; sinon recadre aussi verticalement."""
    img = Image.new("L", (CELL_H * 4, CELL_H), 0)
    draw = ImageDraw.Draw(img)
    # Ligne de base commune : hauteur de capitale centrée dans la cellule.
    cap_top, cap_bottom = fnt.getbbox("H")[1], fnt.getbbox("H")[3]
    y = (CELL_H - (cap_bottom - cap_top)) // 2 - cap_top
    draw.text((CELL_H, y), text, font=fnt, fill=255)
    left, top, right, bottom = img.getbbox()
    box = (left, 0, right, CELL_H) if full_height else (left, top, right, bottom)
    return img.crop(box)


def main():
    text_font = font("Inter-Medium.otf", 11)
    label_font = font("Inter-Bold.otf", 8.5)
    glyphs = [(c, render(c, text_font, True)) for c in "0123456789%"]
    glyphs.append(("-", render("–", text_font, True)))
    glyphs += [("L" + label, render(label, label_font, False)) for label in ("5H", "7J")]
    with open(OUT, "w") as f:
        f.write("# Généré par tools/make_glyphs.py (police Inter, licence OFL). Ne pas éditer.\n")
        f.write("# nom largeur hauteur alpha(base64)\n")
        for name, img in glyphs:
            f.write("%s %d %d %s\n" % (name, img.width, img.height, base64.b64encode(img.tobytes()).decode()))
    print("%d glyphes -> %s" % (len(glyphs), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
