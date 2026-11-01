#!/usr/bin/env python3
"""Render the README architecture as a static SVG and a small looping GIF.

Original code-drawn diagram. No network requests or model calls.
"""
from pathlib import Path
import html
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/assets'
NODES = [
    ('Meta glasses', ['Camera + routed audio', 'The wearer’s point of view']),
    ('iPhone app', ['Local DSP + confirmations', 'Account-bound offline queue']),
    ('Protected backend', ['Meta inference when needed', 'Durable records + alert state']),
    ('Care connection', ['Read-only daily summary', 'Separate acknowledgment']),
]
FONT = next(p for p in [Path('/System/Library/Fonts/Helvetica.ttc'),Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')] if p.exists())

def render():
    OUT.mkdir(exist_ok=True)
    title = ImageFont.truetype(str(FONT), 38)
    heading = ImageFont.truetype(str(FONT), 20)
    body = ImageFont.truetype(str(FONT), 13)
    small = ImageFont.truetype(str(FONT), 11)
    frames = []
    for frame in range(40):
        image = Image.new('RGB', (1080, 420), '#0c0e0f')
        draw = ImageDraw.Draw(image)
        draw.text((40, 32), 'Cadence. From a moment to follow-through.', font=title, fill='#f5f5f7')
        draw.text((42, 94), 'Swift on iPhone  /  FastAPI  /  SQLite  /  Meta models', font=body, fill='#999fa5')
        active = frame // 10
        for index,(name,lines) in enumerate(NODES):
            x = 40 + index*260
            stroke = '#a7dab8' if index==active else '#353b3b'
            draw.rounded_rectangle((x,155,x+220,320),radius=14,fill='#141819',outline=stroke,width=2)
            draw.text((x+20,174),f'0{index+1}',font=small,fill='#99b7a3')
            draw.text((x+20,211),name,font=heading,fill='#edf0ef')
            for row,line in enumerate(lines):
                draw.text((x+20,249+row*23),line,font=body,fill='#a6adb0')
            if index<3:
                draw.line((x+227,237,x+252,237),fill='#525b57',width=2)
                draw.line((x+246,232,x+252,237,x+246,242),fill='#525b57',width=2)
                if index==active:
                    progress = (frame % 10)/9
                    dot = x+228+progress*24
                    draw.ellipse((dot-3,234,dot+3,240),fill='#b9edc9')
        draw.text((42,365),'Local cues stay on the phone. Models interpret bounded requests. Confirmed records persist.',font=body,fill='#b4bfc0')
        draw.text((42,392),'Conceptual flow  ·  Inference is optional  ·  Not a clinical validation',font=small,fill='#777f82')
        frames.append(image)
    frames[0].save(OUT/'architecture-flow.gif',save_all=True,append_images=frames[1:],duration=130,loop=0,optimize=True,disposal=2)
    svg=['<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="420" viewBox="0 0 1080 420" role="img" aria-labelledby="title desc">',
         '<title id="title">Cadence architecture</title><desc id="desc">Glasses provide camera and audio to an iPhone. The iPhone runs local DSP, confirmations and offline queues. A protected backend performs bounded Meta inference and stores records and alert state. A care dashboard displays a daily summary and tracks separate acknowledgment.</desc>',
         '<rect width="1080" height="420" fill="#0c0e0f"/>',
         '<g font-family="-apple-system,Helvetica,Arial,sans-serif">',
         '<text x="40" y="72" font-size="36" fill="#f5f5f7">Cadence. From a moment to follow-through.</text>',
         '<text x="42" y="112" font-size="14" fill="#999fa5">Swift on iPhone / FastAPI / SQLite / Meta models</text>']
    for index,(name,lines) in enumerate(NODES):
        x=40+index*260
        svg += [f'<rect x="{x}" y="155" width="220" height="165" rx="14" fill="#141819" stroke="#465a4e"/>',
                f'<text x="{x+20}" y="190" font-size="11" fill="#99b7a3">0{index+1}</text>',
                f'<text x="{x+20}" y="231" font-size="20" fill="#edf0ef">{html.escape(name)}</text>']
        for row,line in enumerate(lines): svg.append(f'<text x="{x+20}" y="265" dy="{row*23}" font-size="13" fill="#a6adb0">{html.escape(line)}</text>')
        if index<3: svg.append(f'<path d="M{x+227} 237h25m-6-5 6 5-6 5" stroke="#778f80" fill="none"/>')
    svg+=['<text x="42" y="380" font-size="13" fill="#b4bfc0">Local cues stay on the phone. Models interpret bounded requests. Confirmed records persist.</text>',
          '<text x="42" y="406" font-size="11" fill="#777f82">Conceptual flow · Inference is optional · Not a clinical validation</text></g></svg>']
    (OUT/'architecture.svg').write_text('\n'.join(svg))
    print('Rendered docs/assets/architecture-flow.gif and architecture.svg')

if __name__ == '__main__': render()
