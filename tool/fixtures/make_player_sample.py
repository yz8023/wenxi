"""Generate an original MJPEG + two PCM audio tracks + UTF-8 subtitle MKV.

The small deterministic fixture needs Pillow only when regenerated; it contains
no downloaded media or third-party footage. Matroska timecodes are milliseconds.
"""
import io
import math
from pathlib import Path
import struct
from PIL import Image, ImageDraw


def vint(value):
    for length in range(1, 9):
        if value < (1 << (7*length))-1:
            return ((1 << (7*length)) | value).to_bytes(length, 'big')
    raise ValueError(value)


def element(identifier, content):
    code = bytes.fromhex(identifier)
    if isinstance(content, str): content = content.encode('utf-8')
    if isinstance(content, int): content = content.to_bytes(max(1, (content.bit_length()+7)//8), 'big')
    if isinstance(content, float): content = struct.pack('>d', content)
    return code+vint(len(content))+content


def track(number, kind, codec, name, language, extra=b''):
    return element('AE', element('D7', number)+element('73C5', number)+element('83', kind)
                   +element('86', codec)+element('536E', name)+element('22B59C', language)+extra)


header = element('1A45DFA3', element('4286', 1)+element('42F7', 1)+element('42F2', 4)
                 +element('42F3', 8)+element('4282', 'matroska')+element('4287', 4)+element('4285', 2))
info = element('1549A966', element('2AD7B1', 1000000)+element('4489', 9000.0)
               +element('4D80', 'AsterLink fixture')+element('5741', 'AsterLink fixture'))
video = element('E0', element('B0', 320)+element('BA', 180))
audio = element('E1', element('B5', 8000.0)+element('9F', 1)+element('6264', 16))
tracks = element('1654AE6B', track(1, 1, 'V_MJPEG', 'AsterLink sample', 'und', video)
                 +track(2, 2, 'A_PCM/INT/LIT', 'English tone', 'eng', audio)
                 +track(3, 2, 'A_PCM/INT/LIT', 'Chinese tone', 'zho', audio)
                 +track(4, 17, 'S_TEXT/UTF8', 'Embedded Chinese', 'zho'))


def block(track_number, timestamp, data):
    return vint(track_number)+struct.pack('>h', timestamp)+b'\x80'+data


parts = [element('E7', 0)]
for frame in range(90):
    image = Image.new('RGB', (320, 180), (18, 38+frame, 76+frame))
    draw = ImageDraw.Draw(image)
    draw.rectangle((20+frame*2, 64, 80+frame*2, 124), fill=(55, 170, 240))
    draw.text((12, 14), 'ASTERLINK  /  ORIGINAL TEST MEDIA', fill='white')
    draw.text((12, 146), 'Frame %02d - 2 audio tracks + subtitles' % frame, fill='white')
    output = io.BytesIO(); image.save(output, 'JPEG', quality=75)
    timestamp = frame*100
    parts.append(element('A3', block(1, timestamp, output.getvalue())))
    for number, frequency in ((2, 440), (3, 660)):
        samples = [int(1500*math.sin(2*math.pi*frequency*(frame*800+i)/8000)) for i in range(800)]
        parts.append(element('A3', block(number, timestamp, struct.pack('<800h', *samples))))
    if frame in (10, 50):
        text = 'AsterLink 内嵌字幕测试' if frame == 10 else '第二条字幕 / Second caption'
        parts.append(element('A0', element('A1', block(4, timestamp, text.encode('utf-8')))+element('9B', 2500)))
segment = element('18538067', info+tracks+element('1F43B675', b''.join(parts)))
root = Path(__file__).resolve().parents[2]/'test/fixtures'
root.mkdir(parents=True, exist_ok=True)
(root/'player-sample.mkv').write_bytes(header+segment)
(root/'player-external.srt').write_text('1\n00:00:00,000 --> 00:00:08,500\nAsterLink 外挂字幕 / External subtitle\n', encoding='utf-8')
print('Generated', root/'player-sample.mkv', (root/'player-sample.mkv').stat().st_size, 'bytes')
