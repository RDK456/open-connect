# python tools/make_icon.py  -> regenerates every app icon (Windows .ico, Android mipmaps, docs/icon.png)
import os
from PIL import Image, ImageChops, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048  # supersampled master


def master():
    # diagonal blue gradient
    g = Image.new('RGB', (S, S))
    px = g.load()
    a, b = (37, 99, 235), (79, 70, 229)
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S)
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    rr = Image.new('L', (S, S), 0)
    ImageDraw.Draw(rr).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * 0.225), fill=255)

    def ring(cx, r, w):
        m = Image.new('L', (S, S), 0)
        d = ImageDraw.Draw(m)
        c = S // 2
        d.ellipse((cx - r, c - r, cx + r, c + r), fill=255)
        d.ellipse((cx - r + w, c - r + w, cx + r - w, c + r - w), fill=0)
        return m

    c = S // 2
    r, w, off = int(S * 0.235), int(S * 0.085), int(S * 0.135)
    left, right = ring(c - off, r, w), ring(c + off, r, w)
    out = g.copy()
    out.paste(Image.new('RGB', (S, S), 'white'), mask=ImageChops.lighter(left, right))
    res = out.convert('RGBA')
    res.putalpha(rr)
    return res


def main():
    m = master()
    os.makedirs(os.path.join(ROOT, 'docs'), exist_ok=True)
    m.resize((1024, 1024), Image.LANCZOS).save(os.path.join(ROOT, 'docs', 'icon.png'))
    sizes = [16, 24, 32, 48, 64, 128, 256]
    ico = m.resize((256, 256), Image.LANCZOS)
    for rel in ('app/windows/runner/resources/app_icon.ico', 'app/assets/tray.ico'):
        ico.save(os.path.join(ROOT, rel), sizes=[(s, s) for s in sizes])
    res = os.path.join(ROOT, 'app/android/app/src/main/res')
    for d, s in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        m.resize((s, s), Image.LANCZOS).save(os.path.join(res, f'mipmap-{d}', 'ic_launcher.png'))
    print('icons written')


if __name__ == '__main__':
    main()
