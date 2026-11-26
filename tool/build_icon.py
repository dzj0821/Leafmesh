"""Regenerate Leafmesh's application icon (requires Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SIZE = 1024
image = Image.new('RGBA', (SIZE, SIZE))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((16, 16, 1008, 1008), radius=224, fill='#27766c')

def curve(a, b, c, d):
    result = []
    for i in range(101):
        t = i / 100
        result.append(tuple((1-t)**3*a[k] + 3*(1-t)**2*t*b[k] + 3*(1-t)*t*t*c[k] + t**3*d[k] for k in (0, 1)))
    return result

leaf = curve((296, 712), (204, 432), (450, 242), (774, 236))
leaf += curve((774, 236), (790, 552), (614, 792), (296, 712))
draw.polygon(leaf, fill='#e0f0cf')
draw.line([(254, 790), (380, 654), (534, 488), (678, 336)], fill='#27766c', width=32)
draw.line([(380, 654), (365, 476)], fill='#27766c', width=22)
draw.line([(534, 488), (688, 496)], fill='#27766c', width=22)
for x, y in [(380, 654), (365, 476), (688, 496)]:
    draw.ellipse((x-27, y-27, x+27, y+27), fill='#27766c')

image.save(ROOT/'windows/runner/resources/app_icon.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
(ROOT/'artwork').mkdir(exist_ok=True)
image.resize((512,512), Image.Resampling.LANCZOS).save(ROOT/'artwork/leafmesh.png')
print('Leafmesh application icon generated.')
