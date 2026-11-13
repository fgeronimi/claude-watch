#!/usr/bin/env python3
"""Dessine l'icône de la barre de menus : nombre d'agents actifs, puis deux jauges
façon batterie, étiquetées 5H et 7J, chacune avec le pourcentage de quota restant.

    render_bar.py <agents> <reste 5 h|-> <reste 7 j|-> <template|light|dark> [seuil rouge] [compact|wide]

compact : les deux jauges l'une au-dessus de l'autre (étroit, par défaut).
wide    : tout sur une ligne.

Écrit sur stdout : "<largeur pt> <hauteur pt> <PNG en base64>".
Bibliothèque standard uniquement (le python3 livré avec macOS suffit).
"""
import base64
import os
import struct
import sys
import zlib

SCALE = 2            # pixels par point (Retina)
LOW = 20             # % restant sous lequel la batterie passe au rouge (par défaut)
OUTLINE_ALPHA = 0.5
IDLE_ALPHA = 0.45    # "0" agent : chiffre atténué
TRACKING = 1         # espace entre deux caractères, en pixels

# Géométries, en points.
WIDE = {
    "height": 16, "body": (27, 13), "radius": 3.5, "fill_radius": 1.5, "gap_fill": 1,
    "label": "L", "text": "t", "text_cell": 16,
    "gap_count": 4, "gap_text": 3, "gap_group": 6,
}
COMPACT = {
    "height": 20, "body": (21, 9), "radius": 2.5, "fill_radius": 1, "gap_fill": 0.5,
    "label": "l", "text": "s", "text_cell": 9,
    "gap_count": 3, "gap_text": 2, "row_gap": 2,
}
COUNT_SET, COUNT_CELL = "t", 16   # le nombre d'agents garde la grande taille

COLORS = {
    "template": {"fg": (0, 0, 0), "red": (0, 0, 0)},
    "light": {"fg": (0, 0, 0), "red": (255, 59, 48)},
    "dark": {"fg": (255, 255, 255), "red": (255, 69, 58)},
}


def px(points):
    return int(round(points * SCALE))


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
        head = (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
                + chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        tail = chunk(b"IEND", b"")
        # Commentaire de longueur ajustée pour que la taille soit multiple de 3 : le base64
        # n'a alors pas de « = » final, qu'un analyseur « clé=valeur » pourrait mal lire.
        note = b"Software\x00claude-watch"
        note += b" " * (-(len(head) + len(tail) + 12 + len(note)) % 3)
        return head + chunk(b"tEXt", note) + tail


def rounded_rect(x0, y0, x1, y1, r):
    """Couverture (0..1) d'un rectangle arrondi, par pixel, suréchantillonnée 4x4."""
    r = max(0.0, min(r, (x1 - x0) / 2.0, (y1 - y0) / 2.0))
    cover = {}
    n = 4
    for py in range(int(y0), int(y1) + 1):
        for qx in range(int(x0), int(x1) + 1):
            hits = 0
            for sy in range(n):
                for sx in range(n):
                    x, y = qx + (sx + 0.5) / n, py + (sy + 0.5) / n
                    if not (x0 <= x <= x1 and y0 <= y <= y1):
                        continue
                    dx = max(x0 + r - x, 0, x - (x1 - r))
                    dy = max(y0 + r - y, 0, y - (y1 - r))
                    if dx * dx + dy * dy <= r * r:
                        hits += 1
            if hits:
                cover[(qx, py)] = hits / float(n * n)
    return cover


def text_width(glyphs, prefix, text):
    return sum(glyphs[prefix + c][0] for c in text) + TRACKING * (len(text) - 1)


def draw_text(canvas, glyphs, prefix, text, x, y, color, alpha=1.0):
    """Écrit `text` avec le jeu `prefix`, haut de cellule en y. Renvoie le bord droit."""
    for c in text:
        w, h, rows = glyphs[prefix + c]
        for gy in range(h):
            for gx in range(w):
                canvas.blend(x + gx, y + gy, color, rows[gy][gx] * alpha)
        x += w + TRACKING
    return x - TRACKING


def draw_battery(canvas, glyphs, geo, x, y, label, left, colors, low):
    """Jauge dont le coin haut gauche est (x, y), remplie à `left` % (None : inconnu)."""
    fg = colors["fg"]
    fill_color = colors["red"] if left is not None and left <= low else fg
    w, h = px(geo["body"][0]), px(geo["body"][1])
    stroke = SCALE
    inset = stroke + px(geo["gap_fill"])

    outer = rounded_rect(x, y, x + w, y + h, geo["radius"] * SCALE)
    inner = rounded_rect(x + stroke, y + stroke, x + w - stroke, y + h - stroke, (geo["radius"] - 1) * SCALE)
    for p, a in outer.items():
        canvas.blend(p[0], p[1], fg, max(0.0, a - inner.get(p, 0.0)) * OUTLINE_ALPHA)

    # Remplissage : coins arrondis côté gauche, bord droit net (lisible quand il coupe l'étiquette).
    fill = {}
    if left:
        full = w - 2 * inset
        edge = x + inset + max(1.5 * SCALE, full * min(left, 100) / 100.0)
        whole = rounded_rect(x + inset, y + inset, x + inset + full, y + h - inset, geo["fill_radius"] * SCALE)
        for p, a in whole.items():
            a *= max(0.0, min(1.0, edge - p[0]))
            if a > 0:
                fill[p] = a

    # Étiquette à la place de l'éclair : découpée dans le remplissage, pleine en dehors.
    lw, lh, rows = glyphs[geo["label"] + label]
    lx, ly = x + (w - lw) // 2, y + (h - lh) // 2
    mark = {(lx + gx, ly + gy): rows[gy][gx] for gy in range(lh) for gx in range(lw) if rows[gy][gx]}
    for p in set(fill) | set(mark):
        f, m = fill.get(p, 0.0), mark.get(p, 0.0)
        canvas.blend(p[0], p[1], fill_color, f * (1 - m))
        canvas.blend(p[0], p[1], fg, (1 - f) * m)


def render(agents, five, seven, mode, low=LOW, layout="compact"):
    glyphs = load_glyphs()
    colors = COLORS[mode]
    geo = COMPACT if layout == "compact" else WIDE
    height = px(geo["height"])
    count = str(agents)
    groups = [("5H", five), ("7J", seven)]
    texts = ["-" if v is None else "%d%%" % v for _, v in groups]
    body_w, body_h = px(geo["body"][0]), px(geo["body"][1])
    count_w = text_width(glyphs, COUNT_SET, count)
    count_y = (height - px(COUNT_CELL)) // 2
    count_alpha = 1.0 if agents else IDLE_ALPHA
    text_cell = px(geo["text_cell"])

    if layout == "compact":
        text_w = max(text_width(glyphs, geo["text"], t) for t in texts)
        canvas = Canvas(count_w + px(geo["gap_count"]) + body_w + px(geo["gap_text"]) + text_w + SCALE, height)
        x = draw_text(canvas, glyphs, COUNT_SET, count, 0, count_y, colors["fg"], count_alpha) + px(geo["gap_count"])
        top = (height - 2 * body_h - px(geo["row_gap"])) // 2
        for i, ((label, value), text) in enumerate(zip(groups, texts)):
            y = top + i * (body_h + px(geo["row_gap"]))
            draw_battery(canvas, glyphs, geo, x, y, label, value, colors, low)
            draw_text(canvas, glyphs, geo["text"], text, x + body_w + px(geo["gap_text"]),
                      y + (body_h - text_cell) // 2, colors["fg"])
        return canvas

    width = count_w + px(geo["gap_count"])
    for i, text in enumerate(texts):
        width += body_w + px(geo["gap_text"]) + text_width(glyphs, geo["text"], text)
        if i < len(texts) - 1:
            width += px(geo["gap_group"])
    canvas = Canvas(width + SCALE, height)
    x = draw_text(canvas, glyphs, COUNT_SET, count, 0, count_y, colors["fg"], count_alpha) + px(geo["gap_count"])
    for (label, value), text in zip(groups, texts):
        draw_battery(canvas, glyphs, geo, x, (height - body_h) // 2, label, value, colors, low)
        x += body_w + px(geo["gap_text"])
        x = draw_text(canvas, glyphs, geo["text"], text, x, (height - text_cell) // 2, colors["fg"]) + px(geo["gap_group"])
    return canvas


def parse_left(arg):
    return None if arg == "-" else max(0, min(100, int(arg)))


def main(argv):
    if not 5 <= len(argv) <= 7 or argv[4] not in COLORS:
        sys.stderr.write(__doc__)
        return 2
    low = int(argv[5]) if len(argv) > 5 else LOW
    layout = argv[6] if len(argv) > 6 else "compact"
    if layout not in ("compact", "wide"):
        sys.stderr.write(__doc__)
        return 2
    canvas = render(max(0, int(argv[1])), parse_left(argv[2]), parse_left(argv[3]), argv[4], low, layout)
    sys.stdout.write("%d %d %s\n" % ((canvas.w + SCALE - 1) // SCALE, canvas.h // SCALE,
                                     base64.b64encode(canvas.png()).decode()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
