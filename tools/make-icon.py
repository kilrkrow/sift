from PIL import Image, ImageDraw
TEAL=(23,107,135,255); TEAL_D=(14,74,96,255); SLATE=(92,108,124,255); AMBER=(242,169,0,255); WHITE=(255,255,255,255)
def draw(size):
    S=size*8
    im=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(im)
    u=S/32.0
    small=size<=20
    # log lines (top): rounded bars of varying length
    bars=[(3,2.2,29),(3,6.6,23),(3,11.0,27)] if not small else [(3,2.5,29),(3,8.0,24)]
    th=2.6*u if not small else 3.4*u
    for x0,y,x1 in bars:
        d.rounded_rectangle([x0*u,y*u,x1*u,y*u+th],radius=th/2,fill=SLATE)
    # funnel body
    top=15.0 if not small else 13.5
    poly=[(2*u,top*u),(30*u,top*u),(19*u,24*u),(19*u,29.5*u),(13*u,31*u),(13*u,24*u)]
    d.polygon(poly,fill=TEAL)
    # funnel rim highlight
    d.rectangle([2*u,top*u,30*u,(top+2.0)*u],fill=TEAL_D)
    # sieve holes (not on tiny sizes)
    if size>=32:
        for cx in (10,14,18,22):
            r=0.9*u
            cy=(top+4.4)*u
            d.ellipse([cx*u-r,cy-r,cx*u+r,cy+r],fill=WHITE)
        for cx in (14,18):
            r=0.9*u; cy=(top+7.6)*u
            d.ellipse([cx*u-r,cy-r,cx*u+r,cy+r],fill=WHITE)
    # filtered output: amber drop/line under spout
    d.rounded_rectangle([20.5*u,27.5*u,30*u,30.5*u],radius=1.5*u,fill=AMBER)
    return im.resize((size,size),Image.LANCZOS)
sizes=[16,20,24,32,40,48,64,128,256]
imgs=[draw(s) for s in sizes]
import io, struct
def dib(im):
    # 32-bit BGRA DIB, bottom-up, plus a 1-bit AND mask (classic ICO entry,
    # readable by Windows 7 and by the LCL icon reader)
    w, h = im.size
    px = im.load()
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    stride = ((w + 31) // 32) * 4
    andm = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(stride)
        for x in range(w):
            if px[x, y][3] == 0:
                row[x // 8] |= 0x80 >> (x % 8)
        andm += row
    hdr = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, len(xor) + len(andm), 0, 0, 0, 0)
    return hdr + bytes(xor) + bytes(andm)
def png(im):
    b = io.BytesIO(); im.save(b, format='PNG'); return b.getvalue()
# sizes below 256 as DIB entries, 256 as PNG (the standard Vista+ layout)
blobs = [dib(i) if s < 256 else png(i) for s, i in zip(sizes, imgs)]
out = struct.pack('<HHH', 0, 1, len(blobs))
off = 6 + 16 * len(blobs)
for s, b in zip(sizes, blobs):
    out += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(b), off)
    off += len(b)
out += b''.join(blobs)
open('sift.ico', 'wb').write(out)
big=Image.new('RGBA',(sum(sizes)+10*len(sizes),256),(255,255,255,255))
x=0
for s,i in zip(sizes,imgs):
    big.paste(i,(x,256-s),i); x+=s+10
big.save('preview.png')
for s,i in zip(sizes,imgs): i.save(f'icon{s}.png')
