# -*- coding: utf-8 -*-
# Uniform font renderer: re-renders ALL displayed glyph slots with one font (PIL),
# replacing the mixed original-JP + GDI-YaHei look. Matches font_preview.py exactly.
#   - custom zh chars: slot list from injected_slots.txt (char/row/col)
#   - native-reuse zh chars: native_reuse.txt (char/code) -> slot via patched table
#   - retained JP codes: retained_codes.txt (code) -> SJIS decode -> slot via table
import argparse, struct, sys
from PIL import Image, ImageDraw, ImageFont

BANDS = [(1,24),(28,50),(53,75),(81,103),(105,129),(131,154),(157,180),(183,206),
    (210,285),(287,311),(314,336),(340,361),(366,387),(392,413),(418,439),
    (444,465),(470,491),(496,517),(522,543),(548,569),(574,595),(600,621),
    (626,647),(652,673),(678,699),(704,725),(730,751),(756,777),(782,803),
    (808,829),(834,855),(860,881),(886,907),(912,933),(938,959),(964,985),
    (990,1011),(1016,1037),(1042,1063),(1068,1089),(1094,1115),(1120,1141),
    (1146,1167),(1172,1193),(1198,1219),(1224,1245),(1250,1271),(1276,1297),
    (1302,1323),(1328,1349),(1354,1374)]
N_ROWS = 53

def row_y(r):
    if r <= 7: return BANDS[r][0]
    if r <= 10: return BANDS[8][0] + (r - 8) * 25
    return BANDS[9 + (r - 11)][0]

def row_h(r):
    if r <= 7: return BANDS[r][1] - BANDS[r][0] + 1
    if r <= 10: return 25
    b = BANDS[9 + (r - 11)]
    return b[1] - b[0] + 1

def load_table(path):
    data = open(path, "rb").read()
    rows, cur = [], []
    for i in range(0, len(data) - 1, 2):
        code = (data[i] << 8) | data[i + 1]
        if code == 0x0D0A:
            rows.append(cur); cur = []
        else:
            cur.append(code)
    if cur: rows.append(cur)
    pos = {}
    for r, row in enumerate(rows):
        for c, code in enumerate(row):
            pos.setdefault(code, (r, c))
    return pos

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bmp", required=True)
    ap.add_argument("--table", required=True)
    ap.add_argument("--slots", required=True, help="injected_slots.txt")
    ap.add_argument("--native", required=True, help="native_reuse.txt")
    ap.add_argument("--retained", required=True, help="retained_codes.txt")
    ap.add_argument("--font", required=True)
    ap.add_argument("--px", type=int, default=24)
    ap.add_argument("--preview", default=None)
    a = ap.parse_args()

    data = bytearray(open(a.bmp, "rb").read())
    w = struct.unpack("<i", data[0x12:0x16])[0]
    h_raw = struct.unpack("<i", data[0x16:0x1A])[0]
    h = abs(h_raw)
    row_bytes = ((w + 31) // 32) * 4
    PXOFF = 0x3E
    print("font bmp %dx%d topdown=%s" % (w, h, h_raw < 0))

    def set_px(x, y, v):
        sy = h - 1 - y if h_raw > 0 else y
        idx = PXOFF + sy * row_bytes + x // 8
        bit = 7 - (x % 8)
        if v: data[idx] |= (1 << bit)
        else: data[idx] &= (~(1 << bit)) & 0xFF

    code_pos = load_table(a.table)

    # collect render jobs: (char, row, col, kind)
    jobs = {}
    n_custom = n_native = n_ret = 0
    for ln in open(a.slots, encoding="utf-8-sig"):
        p = ln.rstrip("\n").split("\t")
        if len(p) != 4: continue
        ch = p[0]
        r = int(p[1].replace("row", ""))
        c = int(p[2].replace("col", ""))
        jobs[(r, c)] = (ch, "custom")
        n_custom += 1
    for ln in open(a.native, encoding="utf-8-sig"):
        p = ln.rstrip("\n").split("\t")
        if len(p) != 2: continue
        code = int(p[1], 16)
        if code in code_pos:
            r, c = code_pos[code]
            jobs[(r, c)] = (p[0], "native")
            n_native += 1
    for ln in open(a.retained, encoding="utf-8-sig"):
        ln = ln.strip()
        if not ln: continue
        code = int(ln, 16)
        if code not in code_pos: continue
        try:
            ch = bytes([code >> 8, code & 0xFF]).decode("cp932")
        except UnicodeDecodeError:
            continue
        if not ch.strip(): continue
        r, c = code_pos[code]
        jobs[(r, c)] = (ch, "retained")
        n_ret += 1
    print("jobs: %d custom, %d native, %d retained -> %d slots" % (n_custom, n_native, n_ret, len(jobs)))

    # render
    CAN = 72
    WIN = 22   # game samples the top 22 rows of each band
    stat = {"ok": 0, "empty": [], "tofu": [], "shrunk": []}
    fonts = {}
    for (r, c), (ch, kind) in sorted(jobs.items()):
        if not (0 <= r < N_ROWS): continue
        rh = row_h(r)
        chosen = None
        for try_px in (a.px, a.px - 1, a.px - 2):
            if try_px not in fonts: fonts[try_px] = ImageFont.truetype(a.font, try_px)
            im = Image.new("L", (CAN, CAN), 255)
            d = ImageDraw.Draw(im)
            d.text((36, 36), ch, font=fonts[try_px], fill=0, anchor="mm")
            im_px = im.load()
            minx, miny, maxx, maxy = 99, 99, -1, -1
            for y in range(CAN):
                for x in range(CAN):
                    if im_px[x, y] < 128:
                        if x < minx: minx = x
                        if y < miny: miny = y
                        if x > maxx: maxx = x
                        if y > maxy: maxy = y
            if maxx < 0: break
            inkW, inkH = maxx - minx + 1, maxy - miny + 1
            if inkH <= WIN and inkW <= 23:
                if try_px != a.px: stat["shrunk"].append(ch)
                chosen = (im, im_px)
                break
        if chosen is None:
            if maxx < 0:
                stat["empty"].append(ch); continue
            chosen = (im, im_px)
        im, im_px = chosen
        # tofu heuristic: hollow rectangle ~border only
        minx, miny, maxx, maxy = 99, 99, -1, -1
        for y in range(CAN):
            for x in range(CAN):
                if im_px[x, y] < 128:
                    if x < minx: minx = x
                    if y < miny: miny = y
                    if x > maxx: maxx = x
                    if y > maxy: maxy = y
        inkW, inkH = maxx - minx + 1, maxy - miny + 1
        if inkW >= 18 and inkH >= 18:
            hollow = all(im_px[minx + x, miny] < 128 and im_px[minx + x, maxy] < 128 for x in range(inkW)) and \
                     all(im_px[minx, miny + y] < 128 and im_px[maxx, miny + y] < 128 for y in range(inkH)) and \
                     all(im_px[x, y] >= 128 for y in range(miny + 3, maxy - 2) for x in range(minx + 3, maxx - 2))
            if hollow:
                stat["tofu"].append(ch); continue
        # clear cell then write: em-box placement, clamped so ink stays in band rows 0..21
        x0 = 1 + c * 24
        y0 = row_y(r)
        lim = min(rh, WIN) - 1
        top = 36 - WIN // 2
        if miny < top: top = miny
        elif maxy > top + lim: top = maxy - lim
        xb = 24
        if minx < xb: xb = minx
        elif maxx > xb + 23: xb = maxx - 23
        for yy in range(rh):
            for xx in range(24):
                set_px(x0 + xx, y0 + yy, 0)
        for yy in range(rh):
            for xx in range(24):
                if im_px[xb + xx, top + yy] < 128:
                    set_px(x0 + xx, y0 + yy, 1)
        stat["ok"] += 1

    open(a.bmp, "wb").write(bytes(data))
    print("rendered %d glyphs (shrunk %d: %s); empty: %s; tofu-suspect: %s" % (
        stat["ok"], len(stat["shrunk"]), "".join(stat["shrunk"])[:60] or "-",
        "".join(stat["empty"])[:50] or "-", "".join(stat["tofu"])[:50] or "-"))
    if stat["empty"] or stat["tofu"]:
        print("WARNING: some glyphs kept original (see above)")

    if a.preview:
        # full-font contact sheet: rows of 42 cells, 3x scale, only rows that have jobs
        S = 3
        rows_with = sorted(set(r for (r, c) in jobs))
        total_h = sum(row_h(r) for r in rows_with) * S + len(rows_with) * 4
        sheet = Image.new("L", (42 * 24 * S + 4, total_h + 4), 128)
        dd = ImageDraw.Draw(sheet)
        oy = 2
        def getpx(x, y):
            sy = h - 1 - y if h_raw > 0 else y
            idx = PXOFF + sy * row_bytes + x // 8
            bit = 7 - (x % 8)
            return (data[idx] >> bit) & 1
        for r in rows_with:
            rh = row_h(r)
            y0 = row_y(r)
            for c in range(42):
                x0 = 1 + c * 24
                for yy in range(rh):
                    for xx in range(24):
                        if getpx(x0 + xx, y0 + yy):
                            dd.rectangle([2 + c * 24 * S + xx * S, oy + yy * S,
                                          2 + c * 24 * S + xx * S + S - 1, oy + yy * S + S - 1], fill=0)
            oy += rh * S + 4
        sheet.save(a.preview)
        print("preview:", a.preview)

if __name__ == "__main__":
    main()
