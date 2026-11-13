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
SCALE = 2  # rendu Retina

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "glyphs.dat")

# Jeux de caractères : préfixe, police, taille (pt), hauteur de cellule (pt), caractères.
# Une cellule garde sa hauteur : tous les caractères d'un jeu partagent la même ligne de base.
TEXT_SETS = [
    ("t", "Inter-Medium.otf", 11, 16, "0123456789%–"),    # disposition large, et nombre d'agents
    ("s", "Inter-SemiBold.otf", 8, 9, "0123456789%–"),    # disposition compacte
]
# Étiquettes dessinées dans les batteries, recadrées au plus juste.
LABEL_SETS = [
    ("L", "Inter-Bold.otf", 8.5, ("5H", "7J")),           # large
    ("l", "Inter-Bold.otf", 6.5, ("5H", "7J")),           # compacte
]


def font(name, size_pt):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), int(round(size_pt * SCALE)))


def render(text, fnt, cell_h=None):
    """Masque alpha de `text`. Avec cell_h (pixels) : cellule de cette hauteur, hauteur de
    capitale centrée ; sans : recadré au plus juste."""
    h = cell_h or 64
    img = Image.new("L", (h * 6, h), 0)
    cap_top, cap_bottom = fnt.getbbox("H")[1], fnt.getbbox("H")[3]
    y = (h - (cap_bottom - cap_top)) // 2 - cap_top
    ImageDraw.Draw(img).text((h, y), text, font=fnt, fill=255)
    left, top, right, bottom = img.getbbox()
    return img.crop((left, 0, right, h) if cell_h else (left, top, right, bottom))


def main():
    glyphs = []
    for prefix, name, size, cell, chars in TEXT_SETS:
        fnt = font(name, size)
        for c in chars:
            glyphs.append((prefix + ("-" if c == "–" else c), render(c, fnt, cell * SCALE)))
    for prefix, name, size, labels in LABEL_SETS:
        fnt = font(name, size)
        for label in labels:
            glyphs.append((prefix + label, render(label, fnt)))
    with open(OUT, "w") as f:
        f.write("# Généré par tools/make_glyphs.py (police Inter, licence OFL). Ne pas éditer.\n")
        f.write("# nom largeur hauteur alpha(base64)\n")
        for name, img in glyphs:
            f.write("%s %d %d %s\n" % (name, img.width, img.height, base64.b64encode(img.tobytes()).decode()))
    print("%d glyphes -> %s" % (len(glyphs), os.path.normpath(OUT)))


if __name__ == "__main__":
    main()
