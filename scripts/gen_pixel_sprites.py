#!/usr/bin/env python3
"""Genera los sprites pixel-art de la UI (priv/static/assets/sprites/*.svg).

Cada sprite se define como un mapa ASCII: un carácter = un píxel, '.' = vacío.
Los sprites animados son tiras horizontales de frames del mismo tamaño; la CSS
los recorre con `steps(n)`. El SVG usa `shape-rendering="crispEdges"`, así que
escala sin blur a cualquier múltiplo.

Uso:
    python3 scripts/gen_pixel_sprites.py            # escribe los SVG
    python3 scripts/gen_pixel_sprites.py --preview out.png   # + hoja de contacto (PIL)
"""

import os
import sys

OUT = os.path.join(os.path.dirname(__file__), "..", "priv", "static", "assets", "sprites")

PALETTE = {
    "K": "#140c08",  # contorno
    "W": "#fff6e0",  # blanco cálido
    "Y": "#ffd23f",  # oro / llama
    "O": "#ff8a1f",  # antorcha
    "R": "#e03a3a",  # rojo dragón
    "r": "#8e1b1b",  # rojo sombra
    "M": "#5a0f1c",  # rojo profundo (membrana)
    "B": "#8a5a2b",  # madera
    "b": "#4e3018",  # madera sombra
    "L": "#e4ddef",  # acero claro
    "S": "#9d93b3",  # acero
    "s": "#5a526e",  # acero sombra
    "C": "#46e0c8",  # arcano
    "c": "#1d8a86",  # arcano sombra
    "P": "#9b6bff",  # púrpura
    "p": "#4b2d9a",  # púrpura sombra
    "G": "#7bd389",  # musgo
    "g": "#2f7a4a",  # musgo sombra
    "T": "#ecd6a7",  # pergamino
    "t": "#b48a52",  # pergamino sombra
    # piedra de la mazmorra (fondo): contraste mínimo a propósito
    "z": "#0e0a16",  # mortero
    "x": "#191225",  # ladrillo
    "X": "#1f1730",  # ladrillo, canto iluminado
    "v": "#150f20",  # ladrillo, mancha
    # pergamino de la crónica
    "q": "#ead2a0",  # papel
    "Q": "#dfc38c",  # mota oscura
    "u": "#f1ddb2",  # mota clara
}


def rows(block):
    # Las líneas en blanco no son píxeles (un vacío se dibuja con '.'), así que
    # se descartan: permite concatenar bloques (llama + soporte de la antorcha).
    lines = [l.rstrip() for l in block.split("\n") if l.strip()]
    # Quita la indentación común (los mapas van indentados en el código).
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    return [l[indent:] for l in lines]


def frame_grid(block, w, h, name):
    rs = rows(block)
    if len(rs) != h:
        raise SystemExit(f"{name}: {len(rs)} filas, esperaba {h}")
    for i, r in enumerate(rs):
        if len(r) > w:
            raise SystemExit(f"{name}: fila {i} mide {len(r)} > {w}: {r!r}")
    return [r.ljust(w, ".") for r in rs]


def svg(frames, w, h):
    """Tira horizontal de frames → SVG con un <path> por color."""
    by_color = {}
    for fi, grid in enumerate(frames):
        ox = fi * w
        for y, row in enumerate(grid):
            x = 0
            while x < w:
                ch = row[x]
                if ch == ".":
                    x += 1
                    continue
                run = 1
                while x + run < w and row[x + run] == ch:
                    run += 1
                by_color.setdefault(ch, []).append(f"M{ox + x} {y}h{run}v1h-{run}z")
                x += run
    total_w = w * len(frames)
    paths = "".join(
        f'<path fill="{PALETTE[ch]}" d="{"".join(ds)}"/>' for ch, ds in sorted(by_color.items())
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_w} {h}" '
        f'width="{total_w}" height="{h}" shape-rendering="crispEdges">{paths}</svg>\n'
    )


SPRITES = {}


def sprite(name, w, h, *frames):
    SPRITES[name] = (w, h, [frame_grid(f, w, h, f"{name}[{i}]") for i, f in enumerate(frames)])


# ------------------------------------------------------------------ iconos

sprite("heart", 9, 8, """
    .KKK.KKK.
    KWWRKRRRK
    KWRRRRRRK
    KRRRRRRrK
    .KRRRRrK.
    ..KRRrK..
    ...KrK...
    ....K....
""")

sprite("shield", 9, 10, """
    KKKKKKKKK
    KLLLYSSsK
    KLLLYSSsK
    KYYYYYYYK
    KLSSYSSsK
    KLSSYSSsK
    .KSSYSsK.
    .KSSYSsK.
    ..KSYsK..
    ...KKK...
""")

sprite("skull", 9, 9, """
    ..KKKKK..
    .KWWWWWK.
    KWWWWWWLK
    KWKKWKKLK
    KWKKWKKLK
    KWWWKWWLK
    .KWLLLLK.
    .KWKWKLK.
    ..KKKKK..
""")

sprite("swords", 12, 12, """
    KK........KK
    KLK......KLK
    .KLK....KLK.
    ..KLK..KLK..
    ...KLKKLK...
    ....KLLK....
    ....KLLK....
    ..YKLKKLKY..
    ..KYK..KYK..
    .KBKY..YKBK.
    KBK......KBK
    KK........KK
""")

sprite("d20", 13, 14, """
    ......K......
    ....KKCKK....
    ..KKCCWCCKK..
    KKCCCCWCCCCKK
    KcKCCCWCCCKcK
    KccKCCWCCKccK
    KcccKCWCKcccK
    KcccKCCCKcccK
    KccKCCCCCKccK
    KcKKKKKKKKKcK
    KKcccccccccKK
    ..KKcccccKK..
    ....KKcKK....
    ......K......
""")

sprite("orb", 10, 11, """
    ...KKKK...
    ..KWPPPK..
    .KWPPPPpK.
    KPWPPPPPpK
    KPPPPPPPpK
    KPPPPPPppK
    .KPPPPppK.
    ..KKKKKK..
    .KYYYYYYK.
    KYBBBBBBbK
    KKKKKKKKKK
""")

sprite("key", 13, 7, """
    .KKK.........
    KYWYK........
    KY.YKKKKKKKKK
    KY.YYYYYYYYYK
    KYYYKKKKYKYKK
    .KKK....K.K..
    .............
""")

sprite("eye", 13, 9, """
    ....KKKKK....
    ..KKWWWWWKK..
    .KWWWKKKWWWK.
    KWWWKCCWKWWWK
    KWWWKCKCKWWWK
    KWWWKCCCKWWWK
    .KWWWKKKWWWK.
    ..KKWWWWWKK..
    ....KKKKK....
""")

sprite("gear", 11, 11, """
    ....KKK....
    .KK.KSK.KK.
    .KSKKSKKSK.
    ..KSSSSSK..
    KKKSsKsSKKK
    KSSSK.KSSSK
    KKKSsKsSKKK
    ..KSSSSSK..
    .KSKKSKKSK.
    .KK.KSK.KK.
    ....KKK....
""")

sprite("scroll", 12, 12, """
    .KKKKKKKKK..
    KTTTTTTTTTK.
    KtKKKKKKKTTK
    .KTTTTTTTKK.
    .KTbbbbbTK..
    .KTTTTTTTK..
    .KTbbbbTTK..
    .KTTTTTTTK..
    .KTbbbbbTK..
    .KKTTTTTTTK.
    KTTKKKKKKtK.
    .KKKKKKKKK..
""")

sprite("book", 12, 11, """
    .KKKKKKKKKK.
    KPPPPPPPPPpK
    KPPYYYYYYPpK
    KPPYPPPPYPpK
    KPPYPCCPYPpK
    KPPYPCCPYPpK
    KPPYPPPPYPpK
    KPPYYYYYYPpK
    KPPPPPPPPPpK
    KWWWWWWWWWWK
    .KKKKKKKKKK.
""")

sprite("boot", 10, 10, """
    ..KKKKK...
    ..KBBBK...
    ..KBBbK...
    ..KBBbK...
    ..KBBbK...
    ..KBBbKK..
    .KBBBBbbK.
    KBBBBBBbbK
    KbbbbbbbbK
    KKKKKKKKKK
""")

sprite("potion", 9, 11, """
    ...KKK...
    ...KBK...
    ...KKK...
    ..KWLLK..
    .KWLLLLK.
    KRRRRRRrK
    KWRRRRRrK
    KWRRRRRrK
    KRRRRRrrK
    .KRRRrrK.
    ..KKKKK..
""")

sprite("quill", 12, 12, """
    .........KKK
    ........KWWK
    .......KWLWK
    ......KWLWK.
    .....KWLWK..
    ....KWLWK...
    ...KWLWK....
    ...KLWK.....
    ..KSKK......
    ..KsK.......
    .KsK........
    .K..........
""")

sprite("arrow", 7, 9, """
    KK.....
    KYK....
    KYYK...
    KYYYK..
    KYYYOK.
    KYYOK..
    KYOK...
    KOK....
    KK.....
""")

# --------------------------------------------------------------- antorcha
# 3 frames de llama sobre el mismo soporte.

_TORCH_BASE = """
    ....KbBBBBbK....
    ....KKbBBbKK....
    .....KBBBbK.....
    .....KbBBbK.....
    ......KBbK......
    ......KBbK......
    ......KBbK......
    .....KSSSsK.....
    ......KBbK......
    ......KBbK......
    ......KbbK......
    .......KK.......
"""

sprite("torch", 16, 24, """
    .......K........
    ......KRK.......
    ......KRK..K....
    .....KROK.KRK...
    .....KROOKROK...
    ....KROOYOROK...
    ....KROYYYOK....
    ...KROYYWYORK...
    ...KROYWWYORK...
    ...KROYWWYOK....
    ....KROYYORK....
    .....KKKKKK.....
""" + _TORCH_BASE, """
    ........K.......
    .......KRK......
    ...K...KRK......
    ..KRK.KROK......
    ..KROKROOK......
    ...KROYOOK......
    ...KROYYYORK....
    ...KROYWYYORK...
    ...KROYWWYORK...
    ....KROWWYORK...
    ....KROYYORK....
    .....KKKKKK.....
""" + _TORCH_BASE, """
    ................
    .........K......
    ........KRK.....
    .......KROK.....
    ......KROOK.....
    .....KROYOK.K...
    .....KROYYOKRK..
    ....KROYYWYORK..
    ...KROYWWWYORK..
    ...KROYWWYOORK..
    ....KROYYYORK...
    .....KKKKKK.....
""" + _TORCH_BASE)

# ---------------------------------------------------------------- dragón
# Dragón rojo de perfil (mira a la derecha), 2 frames: alas arriba / abajo.

_DRAGON_BODY = """
    ....................................KK..KK......
    ...................................KrRKKrRK.....
    ...................................KrRRRRRRKK...
    ..................................KRRRRRRRWRRK..
    ..................................KRRRRRRRKRRRKK
    ..................................KRRRRRRRRRRRRK
    .................................KRRRRRRRWKWKWKK
    .................................KRRRRRRKK......
    ................................KRRRRRRKWKWKWK.
    ................................KRRRRRRRRRRRRK.
    ...............................KRRRRRRKKKKKKK..
    ...............................KRRORRK.........
    ..............................KRROORK..........
    ..............................KRROORK..........
    .............................KRROOORK..........
    ......................KKKKKKKRRROOORK..........
    ...................KKKRRRRRRRRRROOORK..........
    .................KKRRRRRRRRRRRRROOORK..........
    ................KRRRRRRRRRRRRRRROOORK..........
    ...............KRRRRRRRRRRRRRRRROOOOK..........
    ..............KrRRRRRRRRRRRRRRRROOOOK..........
    ..............KrRRRRRRRRRRRRRRRROOOK...........
    .............KrrRRRRRRRRRRRRRROOOOK............
    .............KrrRRRRRRRRRRRRROOOOK.............
    ......KKK....KrrrRRRRRRRRRROOOOOK..............
    ....KKRRRK...KrrrrRRRRRRROOOOOKK...............
    ...KRRKKRRK..KrrrrKKKKKKKKKKKK.................
    ..KRRK..KRRKKrrrrKrRRK..KrRRK..................
    ..KRK....KRRRrrrKKrRRK..KrRRK..................
    ..KRK.....KKKKKK.KrRRK..KrRRK..................
    ...KRK...........KrRRK..KrRRK..................
    ...KRRK.........KrRRRK.KrRRRK..................
    ....KKRK........KWKWKK.KWKWKK..................
    ......KK........KKKKK..KKKKK...................
"""


# Púas dorsales y ojo: retoques píxel a píxel sobre el cuerpo base.
_DRAGON_TOUCHES = [
    # ojo dorado con pupila
    (42, 3, "Y"),
    # púas del cuello (asoman a la izquierda del contorno)
    (31, 8, "K"), (30, 9, "K"), (31, 9, "O"),
    (30, 11, "K"), (29, 12, "K"), (30, 12, "O"),
    (29, 14, "K"), (28, 15, "K"), (29, 15, "O"),
    # púas del lomo (asoman por arriba)
    (25, 14, "K"), (25, 15, "O"), (26, 14, "K"),
    (20, 15, "K"), (20, 16, "O"), (21, 15, "K"),
    (16, 17, "K"), (16, 18, "O"), (17, 17, "K"),
]


def _dragon(wing_rows):
    body = [list(r.ljust(48, ".")) for r in rows(_DRAGON_BODY)]
    for x, y, ch in _DRAGON_TOUCHES:
        body[y][x] = ch
    body = ["".join(r) for r in body]
    wing = rows(wing_rows)
    out = []
    for y, row in enumerate(body):
        row = row.ljust(48, ".")
        if y < len(wing):
            w = wing[y].ljust(48, ".")
            row = "".join(wc if wc != "." and bc == "." else bc for bc, wc in zip(row, w))
        out.append(row)
    return "\n".join(out)


_WING_UP = """
    ......KK........................................
    ......KMK.......................................
    .....KMMKK......................................
    .....KMMMMKK....................................
    ....KMMMMMMMKK..................................
    ....KMMrMMMMMMKK................................
    ...KMMMrMMMMMMMMKK..............................
    ...KMMMrMMMrMMMMMMKK............................
    ..KMMMMrMMMrMMMMMMMMK...........................
    ..KMMMMrMMMrMMMMrMMMMK..........................
    .KMMMMMrMMMrMMMMrMMMMMK.........................
    .KMMMMrMMMMrMMMMrMMMMMMK........................
    KMMMMMrMMMrMMMMMrMMMMMMMK.......................
    KMMMMrMMMMrMMMMrMMMMMMMMK.......................
    KMMMKrMMMKrMMMKrMMMMMMMMK.......................
    .KKK.KMMK.KMMK.KMMMMMMMMK.......................
    ......KK...KK...KKKKKKKK........................
"""

_WING_DOWN = """
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ................................................
    ............KKKKKKKKKKK.........................
    ........KKKKMMMMMMMMMMMK........................
    .....KKKMMMMMMMMMMMMMMMMK.......................
    ...KKMMMMMMrrrrrrrrMMMMMMK......................
    ..KMMMMrrrrMMMMMMMMrrrrMMK......................
    .KMMrrrMMMMMMrMMMMMMMMMMMK......................
    KMMrMMMMMMMMrMMMMMMrMMMMK.......................
    KMrMMMMMrMMrMMMMMrMMMMMK........................
    KKKMMMMrMMrMMMMMrMMMMKK.........................
    ...KKKKKKKKKKKKKKKKKK...........................
"""

SPRITES["dragon"] = (
    48,
    34,
    [
        frame_grid(_dragon(_WING_UP), 48, 34, "dragon[up]"),
        frame_grid(_dragon(_WING_DOWN), 48, 34, "dragon[down]"),
    ],
)

# Aliento de fuego: 3 frames que crecen desde la boca.
sprite("fire", 24, 10, """
    ........................
    ........................
    ........................
    KKKK....................
    OYYOKK..................
    KOOYOK..................
    .KKKK...................
    ........................
    ........................
    ........................
""", """
    ........................
    ..........KKK...........
    ....KKKKKKROOKK.........
    KKKKOOOOYYYYYOOK........
    OYYYYWWWYYYYYYOOK.......
    KOOOYYYYYYOOOOOK........
    .KKKKOOOOOOKKKK.........
    .....KKKKKK.............
    ........................
    ........................
""", """
    ...............KK.......
    ..........KKKKKROKKK....
    ....KKKKKKOOOOYYYOORK...
    KKKKOOOOYYYYYYYYYYYOOK..
    OYYYYWWWWWWWYYYYYYYYYOK.
    KOOOYYYYYYYYYYYYOOOOOOK.
    .KKKKOOOOOOOOOOOOOKKK...
    .....KKKKKROOOORKK......
    ..........KKKKKK........
    ........................
""")


def _bricks():
    """Baldosa 32x16: dos hiladas de ladrillos 16x8 desplazadas media pieza."""
    w, h = 32, 16
    grid = [["x"] * w for _ in range(h)]
    specks = {(5, 4), (22, 3), (11, 12), (27, 13), (3, 14), (19, 6)}
    for y in range(h):
        for x in range(w):
            course = y // 8
            joints = (0, 16) if course == 0 else (8, 24)
            if y % 8 == 0 or x in joints:
                grid[y][x] = "z"
            elif y % 8 == 1:
                grid[y][x] = "X"
            elif (x, y) in specks:
                grid[y][x] = "v"
    return ["".join(r) for r in grid]


SPRITES["bricks"] = (32, 16, [_bricks()])

# Pergamino: papel con motas sueltas; a 3x se lee como grano pixelado.
sprite("parchment", 16, 16, """
    qqqqqqqqqqqqqqqq
    qqqQqqqqqqqqquqq
    qqqqqqqqqQqqqqqq
    quqqqqqqqqqqqqqq
    qqqqqqquqqqqqqQq
    qqqqqqqqqqqqqqqq
    qqqQqqqqqqqqqqqq
    qqqqqqqqqqqQqqqq
    qqqqqquqqqqqqqqq
    qQqqqqqqqqqqqqqq
    qqqqqqqqqqqqquqq
    qqqqqqqqQqqqqqqq
    qqquqqqqqqqqqqqq
    qqqqqqqqqqqqqqQq
    qqqqqqqqqqquqqqq
    qqqqqQqqqqqqqqqq
""")


def preview(path):
    from PIL import Image

    scale = 6
    tiles = []
    for name, (w, h, frames) in SPRITES.items():
        img = Image.new("RGBA", (w * len(frames), h), (0, 0, 0, 0))
        for fi, grid in enumerate(frames):
            for y, row in enumerate(grid):
                for x, ch in enumerate(row):
                    if ch != ".":
                        c = PALETTE[ch]
                        img.putpixel((fi * w + x, y), tuple(int(c[i : i + 2], 16) for i in (1, 3, 5)) + (255,))
        tiles.append(img.resize((img.width * scale, img.height * scale), Image.NEAREST))
    W = max(t.width for t in tiles) + 40
    H = sum(t.height + 20 for t in tiles) + 20
    sheet = Image.new("RGBA", (W, H), (43, 35, 64, 255))
    y = 20
    for t in tiles:
        sheet.paste(t, (20, y), t)
        y += t.height + 20
    sheet.save(path)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (w, h, frames) in SPRITES.items():
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(svg(frames, w, h))
    print(f"{len(SPRITES)} sprites → {os.path.normpath(OUT)}")
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
