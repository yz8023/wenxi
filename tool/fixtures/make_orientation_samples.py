"""Generate original tiny QuickTime/MJPEG files with rotation and pixel aspect metadata.

No external footage or codec executable is needed. These are test fixtures only.
"""
import io
from pathlib import Path
import struct
from PIL import Image, ImageDraw


def atom(kind, content):
    return struct.pack('>I4s', len(content) + 8, kind.encode('ascii')) + content


def full(kind, content, flags=0):
    return atom(kind, struct.pack('>I', flags) + content)


def uints(*values):
    return struct.pack('>' + 'I' * len(values), *values)


identity = (65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30)
width, height, duration = 320, 180, 2000
picture = Image.new('RGB', (width, height), (31, 74, 131))
draw = ImageDraw.Draw(picture)
draw.rectangle((15, 15, 60, 165), fill=(81, 203, 224))
draw.text((80, 70), 'ASTERLINK METADATA', fill='white')
buffer = io.BytesIO()
picture.save(buffer, 'JPEG', quality=80)
frame = buffer.getvalue()
ftyp = atom('ftyp', b'qt  ' + uints(0) + b'qt  ')


def movie(rotation=False, pixel_aspect=(1, 1)):
    matrix = (0, 65536, 0, -65536, 0, 0, height << 16, 0, 1 << 30) if rotation else identity
    matrix_bytes = struct.pack('>9i', *matrix)
    mvhd = full('mvhd', uints(0, 0, 1000, duration, 65536) + struct.pack('>H', 256)
                + b'\0' * 10 + struct.pack('>9i', *identity) + b'\0' * 24 + uints(2))
    tkhd = full('tkhd', uints(0, 0, 1, 0, duration) + b'\0' * 8
                + struct.pack('>4h', 0, 0, 0, 0) + matrix_bytes + uints(width << 16, height << 16), 7)
    mdhd = full('mdhd', uints(0, 0, 1000, duration) + struct.pack('>HH', 0x55c4, 0))
    hdlr = full('hdlr', uints(0) + b'vide' + b'\0' * 12 + b'AsterLink original video\0')
    vmhd = full('vmhd', b'\0' * 8, 1)
    dinf = atom('dinf', full('dref', uints(1) + full('url ', b'', 1)))
    description = (b'\0' * 6 + struct.pack('>H', 1) + b'\0' * 16
                   + struct.pack('>HH', width, height) + uints(0x00480000, 0x00480000, 0)
                   + struct.pack('>H', 1) + bytes([15]) + b'AsterLink MJPEG' + b'\0' * 16
                   + struct.pack('>Hh', 24, -1))
    assert len(description) == 78
    description += atom('pasp', uints(*pixel_aspect))
    stsd = full('stsd', uints(1) + atom('jpeg', description))
    stts = full('stts', uints(1, 1, duration))
    stsc = full('stsc', uints(1, 1, 1, 1))
    stsz = full('stsz', uints(len(frame), 1))
    stco = full('stco', uints(1, len(ftyp) + 8))
    stbl = atom('stbl', stsd + stts + stsc + stsz + stco)
    trak = atom('trak', tkhd + atom('mdia', mdhd + hdlr + atom('minf', vmhd + dinf + stbl)))
    return ftyp + atom('mdat', frame) + atom('moov', mvhd + trak)


root = Path(__file__).resolve().parents[2] / 'test/fixtures'
root.mkdir(parents=True, exist_ok=True)
for name, content in [('player-rotated.mov', movie(rotation=True)),
                      ('player-anamorphic.mov', movie(pixel_aspect=(2, 1)))]:
    (root / name).write_bytes(content)
    print(name, len(content), 'bytes')
