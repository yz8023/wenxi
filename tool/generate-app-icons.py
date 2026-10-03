"""Generate app, launcher and Windows icons from UI/图标.jpeg (Pillow).

The original artwork is retained. Only outside whitespace is removed; Android
adaptive icons get a separate cloud foreground so launcher masks do not clip it.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "UI" / "图标.jpeg"
RES = ROOT / "android/app/src/main/res"
REVIEW = ROOT / ".local/icon-review"
GENERATED: list[Path] = []


def fill_holes(mask: Image.Image) -> Image.Image:
    result = mask.copy()
    ImageDraw.floodfill(result, (0, 0), 128)
    return result.point(lambda value: 0 if value == 128 else 255)


def fit(image: Image.Image, size: int, padding: int = 0) -> Image.Image:
    result = Image.new("RGBA", (size, size))
    scaled = ImageOps.contain(image, (size - 2 * padding,) * 2, Image.Resampling.LANCZOS)
    result.alpha_composite(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2))
    return result


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Palette compression removes JPEG texture noise at launcher resolutions.
    image.quantize(colors=256, method=Image.Quantize.FASTOCTREE,
                   dither=Image.Dither.NONE).save(path, optimize=True, compress_level=9)
    GENERATED.append(path)


def write_xml(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value.strip() + "\n", encoding="utf-8")
    GENERATED.append(path)


def bitmap(resource: str) -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Generated from the user-provided cloud/document artwork. -->
<bitmap xmlns:android="http://schemas.android.com/apk/res/android"
    android:src="@drawable/{resource}"
    android:gravity="fill" android:filter="true" android:antialias="true" />'''


source = ImageOps.exif_transpose(Image.open(SOURCE)).convert("RGB")
red, green, blue = source.split()
outer = fill_holes(ImageChops.subtract(blue, red).point(lambda value: 255 if value > 35 else 0))
outer_box = outer.getbbox()
assert outer_box is not None
art = source.convert("RGBA")
art.putalpha(outer.filter(ImageFilter.GaussianBlur(0.65)))
art = art.crop(outer_box)
app = fit(art, 512, padding=4)
save_png(app, ROOT / "assets/icons/app.png")

# Keep the connected white cloud and fill its internal document/arrow cutouts.
bright = ImageChops.multiply(red.point(lambda value: 255 if value > 135 else 0),
                             green.point(lambda value: 255 if value > 165 else 0))
bright = ImageChops.multiply(bright, outer.filter(ImageFilter.MinFilter(7)))
ImageDraw.floodfill(bright, (source.width // 2, source.height // 4), 128)
cloud_mask = fill_holes(bright.point(lambda value: 255 if value == 128 else 0))
cloud_box = cloud_mask.getbbox()
assert cloud_box and cloud_box[2] - cloud_box[0] > 600 and cloud_box[3] - cloud_box[1] > 600
cloud = source.convert("RGBA")
cloud.putalpha(cloud_mask.filter(ImageFilter.GaussianBlur(0.65)))
cloud = cloud.crop(cloud_box)

# 60dp of a 108dp layer: key artwork fits the adaptive-icon safe region.
foreground = fit(cloud, 648, padding=144)
save_png(foreground, RES / "drawable-nodpi/app_icon_foreground.png")
mono = Image.new("RGBA", cloud.size, "white")
mono_mask = ImageChops.subtract(cloud.getchannel("B"), cloud.getchannel("R")).point(
    lambda value: 255 if value < 118 else 0).filter(ImageFilter.GaussianBlur(0.6))
mono.putalpha(ImageChops.multiply(mono_mask, cloud.getchannel("A")))
monochrome = fit(mono, 648, padding=144)
save_png(monochrome, RES / "drawable-nodpi/app_icon_monochrome.png")
save_png(app, RES / "drawable-nodpi/app_icon_legacy.png")
write_xml(RES / "drawable/ic_launcher.xml", bitmap("app_icon_legacy"))
write_xml(RES / "drawable/ic_launcher_foreground.xml", bitmap("app_icon_foreground"))
write_xml(RES / "drawable/ic_launcher_monochrome.xml", bitmap("app_icon_monochrome"))
write_xml(RES / "drawable/ic_launcher_background.xml", '''
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr xmlns:aapt="http://schemas.android.com/aapt" name="android:fillColor">
            <gradient android:startX="18" android:startY="0"
                android:endX="80" android:endY="108" android:type="linear">
                <item android:offset="0" android:color="#FF66BFF4" />
                <item android:offset="0.5" android:color="#FF288AFB" />
                <item android:offset="1" android:color="#FF0862F1" />
            </gradient>
        </aapt:attr>
    </path>
</vector>''')
write_xml(RES / "mipmap/ic_launcher.xml", '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Android 7 fallback; API 26+ uses the adaptive icon. -->
<inset xmlns:android="http://schemas.android.com/apk/res/android"
    android:drawable="@drawable/ic_launcher" />''')
write_xml(RES / "mipmap/ic_launcher_round.xml", '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Density-specific round PNGs are supplied for Android 7 launchers. -->
<inset xmlns:android="http://schemas.android.com/apk/res/android"
    android:drawable="@drawable/ic_launcher" />''')

for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
    save_png(fit(art, size, max(1, size // 64)), RES / f"mipmap-{density}/ic_launcher.png")
    circle = fit(art, size * 4)
    mask = Image.new("L", circle.size)
    ImageDraw.Draw(mask).ellipse((0, 0, circle.width - 1, circle.height - 1), fill=255)
    circle.putalpha(ImageChops.multiply(circle.getchannel("A"), mask))
    save_png(circle.resize((size, size), Image.Resampling.LANCZOS),
             RES / f"mipmap-{density}/ic_launcher_round.png")

for path in (ROOT / "assets/icons/app.ico", ROOT / "windows/runner/resources/app_icon.ico"):
    path.parent.mkdir(parents=True, exist_ok=True)
    fit(art, 256, 2).quantize(colors=256, method=Image.Quantize.FASTOCTREE,
                           dither=Image.Dither.NONE).convert("RGBA").save(
        path, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    GENERATED.append(path)

REVIEW.mkdir(parents=True, exist_ok=True)
preview = Image.new("RGB", (900, 330), "#f2f4f8")
draw = ImageDraw.Draw(preview)
preview.paste(app.resize((240, 240), Image.Resampling.LANCZOS), (24, 45),
              app.resize((240, 240), Image.Resampling.LANCZOS))
draw.text((24, 18), "App / Windows", fill="black")
# The visible launcher mask spans the central 72dp of an adaptive layer.
visible = foreground.crop((108, 108, 540, 540)).resize((240, 240), Image.Resampling.LANCZOS)
adaptive = Image.new("RGBA", (240, 240), "#278afb")
adaptive.alpha_composite(visible)
mask = Image.new("L", adaptive.size)
ImageDraw.Draw(mask).ellipse((0, 0, 239, 239), fill=255)
adaptive.putalpha(mask)
preview.paste(adaptive, (326, 45), adaptive)
draw.text((326, 18), "Android circle", fill="black")
themed = Image.new("RGBA", (240, 240), "#dbe8ff")
glyph = monochrome.crop((108, 108, 540, 540)).resize((240, 240), Image.Resampling.LANCZOS)
tint = Image.new("RGBA", glyph.size, "#163c6d")
tint.putalpha(glyph.getchannel("A"))
themed.alpha_composite(tint)
themed.putalpha(mask)
preview.paste(themed, (626, 45), themed)
draw.text((626, 18), "Android themed", fill="black")
preview.save(REVIEW / "app-icons.png", optimize=True)
inventory = {
    "source": str(SOURCE.relative_to(ROOT)),
    "sourceSha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    "sourceBytes": SOURCE.stat().st_size,
    "sourceDimensions": source.size,
    "outsideCrop": outer_box,
    "cloudCrop": cloud_box,
    "files": [{"path": str(p.relative_to(ROOT)), "bytes": p.stat().st_size,
               "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in GENERATED],
}
(REVIEW / "inventory.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=False), encoding="utf-8")
print(json.dumps({"files": len(GENERATED), "appPngBytes": (ROOT / "assets/icons/app.png").stat().st_size,
                  "totalBytes": sum(p.stat().st_size for p in GENERATED),
                  "cloudCrop": cloud_box, "preview": str(REVIEW / "app-icons.png")}, ensure_ascii=True))
