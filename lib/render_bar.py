#!/usr/bin/env python3
"""Dessine l'icône de la barre de menus : nombre d'agents actifs, puis deux
jauges façon batterie, étiquetées 5H et 7J, suivies du pourcentage de quota restant.

    render_bar.py <agents> <reste 5 h|-> <reste 7 j|-> <template|light|dark> [seuil rouge]

Écrit sur stdout : "<largeur pt> <hauteur pt> <PNG en base64>".
Bibliothèque standard uniquement (le python3 livré avec macOS suffit).
"""
import base64
import os
import struct
import sys
import zlib

SCALE = 2            # pixels par point (Retina)
H = 16 * SCALE       # hauteur de l'icône
LOW = 20             # % restant sous lequel la batterie passe au rouge (par défaut)

BODY_W, BODY_H = 27 * SCALE, 13 * SCALE
STROKE = SCALE                    # épaisseur du contour
INSET = STROKE + SCALE            # contour + jour avant le remplissage
OUTLINE_ALPHA = 0.5
IDLE_ALPHA = 0.45                 # "0" agent : chiffre atténué

GAP_COUNT = 4 * SCALE             # nombre d'agents → première batterie
GAP_TEXT = 3 * SCALE              # batterie → pourcentage
GAP_GROUP = 6 * SCALE             # pourcentage → batterie suivante
TRACKING = 1                      # espace entre deux caractères

COLORS = {
    "template": {"fg": (0, 0, 0), "red": (0, 0, 0)},
    "light": {"fg": (0, 0, 0), "red": (255, 59, 48)},
    "dark": {"fg": (255, 255, 255), "red": (255, 69, 58)},
}


def load_glyphs():
    glyphs = {}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "glyphs.dat")
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            name, w, h, data = line.split()
            w, h = int(w), int(h)
            raw = base64.b64decode(data)
            glyphs[name] = (w, h, [[raw[y * w + x] / 255.0 for x in range(w)] for y in range(h)])
    return glyphs


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[(0.0, 0.0, 0.0, 0.0)] * w for _ in range(h)]

    def blend(self, x, y, color, a):
        """Compose `color` d'opacité `a` par-dessus le pixel."""
        if a <= 0 or not (0 <= x < self.w and 0 <= y < self.h):
            return
        r0, g0, b0, a0 = self.px[y][x]
        out = a + a0 * (1 - a)
        self.px[y][x] = tuple((c * a + c0 * a0 * (1 - a)) / out for c, c0 in zip(color, (r0, g0, b0))) + (out,)

    def png(self):
        raw = bytearray()
        for row in self.px:
            raw.append(0)
            for r, g, b, a in row:
                raw += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5), int(a * 255 + 0.5)))

        def chunk(kind, data):
            body = kind + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        ppm = int(round(72 * SCALE / 0.0254))  # résolution : macOS en déduit la taille en points
        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
                + chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                + chunk(b"IEND", b""))


def rounded_rect(x0, y0, x1, y1, r):
    """Couverture (0..1) d'un rectangle arrondi, par pixel, suréchantillonnée 4x4."""
    r = max(0.0, min(r, (x1 - x0) / 2.0, (y1 - y0) / 2.0))
    cover = {}
    n = 4
    for py in range(int(y0), int(y1) + 1):
        for px in range(int(x0), int(x1) + 1):
            hits = 0
            for sy in range(n):
                for sx in range(n):
                    x, y = px + (sx + 0.5) / n, py + (sy + 0.5) / n
                    if not (x0 <= x <= x1 and y0 <= y <= y1):
                        continue
                    dx = max(x0 + r - x, 0, x - (x1 - r))
                    dy = max(y0 + r - y, 0, y - (y1 - r))
                    if dx * dx + dy * dy <= r * r:
                        hits += 1
            if hits:
                cover[(px, py)] = hits / float(n * n)
    return cover


def text_width(glyphs, text):
    return sum(glyphs[c][0] for c in text) + TRACKING * (len(text) - 1)


def draw_text(canvas, glyphs, text, x, color, alpha=1.0):
    for c in text:
        w, h, rows = glyphs[c]
        for gy in range(h):
            for gx in range(w):
                canvas.blend(x + gx, gy, color, rows[gy][gx] * alpha)
        x += w + TRACKING
    return x - TRACKING


def draw_battery(canvas, glyphs, x, label, left, colors, low):
    """Batterie à l'abscisse x, remplie à `left` % (None : inconnu). Renvoie son bord droit."""
    fg = colors["fg"]
    fill_color = colors["red"] if left is not None and left <= low else fg
    y = (H - BODY_H) // 2

    outer = rounded_rect(x, y, x + BODY_W, y + BODY_H, 3.5 * SCALE)
    inner = rounded_rect(x + STROKE, y + STROKE, x + BODY_W - STROKE, y + BODY_H - STROKE, 2.5 * SCALE)
    for p, a in outer.items():
        canvas.blend(p[0], p[1], fg, max(0.0, a - inner.get(p, 0.0)) * OUTLINE_ALPHA)

    # Remplissage : coins arrondis côté gauche, bord droit net (lisible quand il coupe l'étiquette).
    fill = {}
    if left:
        full = BODY_W - 2 * INSET
        edge = x + INSET + max(1.5 * SCALE, full * min(left, 100) / 100.0)
        whole = rounded_rect(x + INSET, y + INSET, x + INSET + full, y + BODY_H - INSET, 1.5 * SCALE)
        for p, a in whole.items():
            a *= max(0.0, min(1.0, edge - p[0]))
            if a > 0:
                fill[p] = a

    # Étiquette à la place de l'éclair : découpée dans le remplissage, pleine en dehors.
    lw, lh, rows = glyphs["L" + label]
    lx, ly = x + (BODY_W - lw) // 2, y + (BODY_H - lh) // 2
    mark = {(lx + gx, ly + gy): rows[gy][gx] for gy in range(lh) for gx in range(lw) if rows[gy][gx]}
    for p in set(fill) | set(mark):
        f, m = fill.get(p, 0.0), mark.get(p, 0.0)
        canvas.blend(p[0], p[1], fill_color, f * (1 - m))
        canvas.blend(p[0], p[1], fg, (1 - f) * m)

    return x + BODY_W


def render(agents, five, seven, mode, low=LOW):
    glyphs = load_glyphs()
    colors = COLORS[mode]
    count = str(agents)
    groups = [("5H", five), ("7J", seven)]
    texts = ["-" if v is None else "%d%%" % v for _, v in groups]

    width = text_width(glyphs, count) + GAP_COUNT
    for i, text in enumerate(texts):
        width += BODY_W + GAP_TEXT + text_width(glyphs, text)
        if i < len(texts) - 1:
            width += GAP_GROUP
    canvas = Canvas(width + SCALE, H)

    x = draw_text(canvas, glyphs, count, 0, colors["fg"], 1.0 if agents else IDLE_ALPHA) + GAP_COUNT
    for (label, value), text in zip(groups, texts):
        x = draw_battery(canvas, glyphs, x, label, value, colors, low) + GAP_TEXT
        x = draw_text(canvas, glyphs, text, x, colors["fg"]) + GAP_GROUP
    return canvas


def parse_left(arg):
    return None if arg == "-" else max(0, min(100, int(arg)))


def main(argv):
    if len(argv) not in (5, 6) or argv[4] not in COLORS:
        sys.stderr.write(__doc__)
        return 2
    low = int(argv[5]) if len(argv) == 6 else LOW
    canvas = render(max(0, int(argv[1])), parse_left(argv[2]), parse_left(argv[3]), argv[4], low)
    sys.stdout.write("%d %d %s\n" % ((canvas.w + SCALE - 1) // SCALE, canvas.h // SCALE,
                                     base64.b64encode(canvas.png()).decode()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
