#!/usr/bin/env python3
"""Render faithful README preview images for AICreditsBar (menu bar, dropdown, settings).

Why rendered, not raw screencaps: macOS's capture sandbox in the build environment hides
the app's own (LSUIElement) windows from automated screenshots, so these panels are drawn
from the app's exact labels/colors/values. Re-run after UI changes. Output: docs/images/*.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

S = 2  # supersample for retina-crisp output
OUT = os.path.join(os.path.dirname(__file__), "images")
os.makedirs(OUT, exist_ok=True)

# palette (matches Cfg defaults in main.swift)
GREEN=(48,209,88); YELLOW=(255,214,0); RED=(255,66,69); GRAY=(152,152,157)
WHITE=(236,236,238); SUB=(164,164,170); SEP=(80,80,84)
MENU_BG=(42,42,46); BAR_BG=(30,30,32); WIN_BG=(46,46,50); TITLE_BG=(64,64,68)
FIELD_BG=(70,70,76); ACCENT=(10,132,255)

def font(path_opts, size, bold=False):
    for p in path_opts:
        if os.path.exists(p):
            try:
                f = ImageFont.truetype(p, size*S)
                if bold:
                    try: f.set_variation_by_name("Bold")
                    except Exception: pass
                return f
            except Exception: continue
    return ImageFont.load_default()

SF   = ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]
MONO = ["/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Courier.ttc"]
def ui(sz, bold=False): return font(SF, sz, bold)
def mono(sz): return font(MONO, sz)

def rrect(d, box, r, fill, outline=None, w=1):
    d.rounded_rectangle([c*S for c in box], radius=r*S, fill=fill, outline=outline, width=w*S)

def text(d, xy, s, f, fill, anchor="la"):
    d.text((xy[0]*S, xy[1]*S), s, font=f, fill=fill, anchor=anchor)

def tw(d, s, f): return d.textlength(s, font=f)/S

def save(img, name):
    p = os.path.join(OUT, name)
    img.resize((img.size[0]//S, img.size[1]//S), Image.LANCZOS).save(p)
    print("wrote", p, img.size[0]//S, "x", img.size[1]//S)

# ---------------------------------------------------------------- menu bar
import math
def _sunburst(d, cx, cy, r, col):  # Claude mark
    for i in range(11):
        a = i/11*2*math.pi
        d.line([(cx, cy), (cx+math.cos(a)*r, cy+math.sin(a)*r)], fill=col, width=int(2.2*S))
    d.ellipse([cx-r*0.22, cy-r*0.22, cx+r*0.22, cy+r*0.22], fill=col)
def _blossom(d, cx, cy, r, col):   # Codex mark
    pr = r*0.5
    for i in range(6):
        a = (i*60-90)*math.pi/180
        px, py = cx+math.cos(a)*r*0.55, cy+math.sin(a)*r*0.55
        d.ellipse([px-pr, py-pr, px+pr, py+pr], fill=col)
    d.ellipse([cx-r*0.25, cy-r*0.25, cx+r*0.25, cy+r*0.25], fill=BAR_BG)  # center hole
def _sparkle(d, cx, cy, r, col):   # Gemini mark
    k = r*0.18
    d.polygon([(cx,cy-r),(cx+k,cy-k),(cx+r,cy),(cx+k,cy+k),(cx,cy+r),(cx-k,cy+k),(cx-r,cy),(cx-k,cy-k)], fill=col)

def render_menubar():
    W,H = 250, 26
    img = Image.new("RGB", (W*S, H*S), BAR_BG); d = ImageDraw.Draw(img)
    fm = mono(13)
    x = 14*S; y = 5*S; r = 7*S
    def seg(mark, val, vc):
        nonlocal x
        mark(d, x+r, (H*S)//2, r, WHITE); x += r*2 + 4*S
        text(d, (x/S, y/S), val, fm, vc); x += tw(d, val, fm)*S + 14*S
    seg(_blossom, "9%", RED); seg(_sunburst, "73%", GREEN); seg(_sparkle, "—", GRAY)
    save(img, "menubar.png")

# ---------------------------------------------------------------- dropdown
def render_dropdown():
    fh = ui(13, bold=True); fd = mono(12); fk = ui(12)
    rows = [  # (kind, text, color)  kind: head/det/sep/item
        ("head","Codex — pro", WHITE),
        ("det","   5h: 54% left  · reset in 0h 42m", SUB),
        ("det","   week: 29% left  · reset in 4d 22h", SUB),
        ("det","   snapshot just now", SUB),
        ("sep",None,None),
        ("head","Claude — est.", WHITE),
        ("det","   5h: 31% left  (105.2M tok)  · reset in 3h 05m", SUB),
        ("det","   5h used 105.2M / 220.0M est.", SUB),
        ("det","   burn 1.2M/min · ~138M by reset", SUB),
        ("det","   7d: 47% left  (1.1B/7d)", SUB),
        ("det","   7d used 1.1B / 2.2B est. · calibrate in Settings", SUB),
        ("sep",None,None),
        ("head","Gemini — logged in", WHITE),
        ("det","   no local quota API — % unavailable", SUB),
        ("sep",None,None),
        ("item","Settings…","⌘,"),
        ("item","Refresh now","⌘R"),
        ("item","Quit AICreditsBar","⌘Q"),
    ]
    pad=10; lh=20; W=430
    H = pad*2 + sum(8 if r[0]=="sep" else lh for r in rows)
    img = Image.new("RGB",(W*S,H*S),(0,0,0)); d=ImageDraw.Draw(img)
    rrect(d,(0,0,W-1,H-1),10,MENU_BG,outline=(90,90,96),w=1)
    y=pad
    for kind,t,c in rows:
        if kind=="sep":
            d.line([(12*S,(y+3)*S),((W-12)*S,(y+3)*S)],fill=SEP,width=1*S); y+=8; continue
        if kind=="head": text(d,(12,y),t,fh,c)
        elif kind=="det": text(d,(12,y),t,fd,c)
        elif kind=="item":
            text(d,(14,y),t,fk,WHITE); text(d,(W-14,y),c,fk,SUB,anchor="ra")
        y+=lh
    save(img,"dropdown.png")

# ---------------------------------------------------------------- settings
def render_settings():
    fT=ui(13,bold=True); fL=ui(12); fH=ui(12,bold=True); fS=ui(11)
    W,H=470,600
    img=Image.new("RGB",(W*S,H*S),WIN_BG); d=ImageDraw.Draw(img)
    # title bar
    d.rectangle([0,0,W*S,28*S],fill=TITLE_BG)
    for i,c in enumerate([(255,95,86),(255,189,46),(39,201,63)]):
        d.ellipse([(14+i*18)*S, 9*S, (14+i*18+11)*S, 20*S],fill=c)
    text(d,(W/2,14),"AICreditsBar — Settings",ui(12,bold=True),WHITE,anchor="ma")
    y=46
    def head(t):
        nonlocal y; text(d,(20,y),t,fH,WHITE); y+=24
    def field(x,w,val,placeholder=False):
        rrect(d,(x,y-2,x+w,y+17),4,FIELD_BG,outline=(95,95,100),w=1)
        text(d,(x+7,y+1),val,fL,SUB if placeholder else WHITE)
    def popup(x,w,val):
        rrect(d,(x,y-2,x+w,y+17),4,FIELD_BG,outline=(95,95,100),w=1)
        text(d,(x+7,y+1),val,fL,WHITE); text(d,(x+w-14,y+1),"⌄",fL,SUB)
    def label(t): text(d,(150,y+1),t,fL,WHITE,anchor="ra")
    def check(x,t,on):
        rrect(d,(x,y-1,x+15,y+14),3,ACCENT if on else FIELD_BG,outline=(95,95,100),w=1)
        if on: text(d,(x+3,y-2),"✓",ui(12,bold=True),WHITE)
        text(d,(x+22,y+1),t,fL,WHITE)
        return x+22+tw(d,t,fL)+18

    def btn2(x,w,t):
        rrect(d,(x,y-3,x+w,y+16),5,(92,92,98)); text(d,(x+w/2,y+1),t,fS,WHITE,anchor="ma")
    head("Accurate login — exact official %")
    label("Claude:"); text(d,(160,y+1),"✓ logged in — exact official %",fS,GREEN); btn2(356,48,"Log in"); btn2(410,54,"Log out"); y+=24
    label("Codex:"); text(d,(160,y+1),"✓ official — via your codex CLI (no login needed)",fS,GREEN); y+=24
    text(d,(20,y+1),"Claude: log in once in-app for the exact official % (no DevTools). Codex is automatic via your codex CLI.",fS,SUB); y+=28
    head("Display")
    label("Show in menu bar:"); popup(160,170,"5-hour window"); y+=28
    label("Providers:");
    nx=check(160,"Codex",True); nx=check(nx,"Claude",True); check(nx,"Gemini",False); y+=26
    check(160,"Show provider labels (Cx/Cl/Gm)",True); y+=26
    label("Refresh every (s):"); field(160,70,"30"); y+=30

    head("Colors & thresholds")
    label("Thresholds:")
    text(d,(160,y+1),"green >",fL,WHITE); field(212,40,"50"); text(d,(262,y+1),"yellow ≥",fL,WHITE)
    field(320,40,"20"); text(d,(366,y+1),"% (else red)",fL,SUB); y+=28
    label("Colors:")
    cx=160
    for nm,col in [("High",GREEN),("Mid",YELLOW),("Low",RED),("Unk",GRAY)]:
        text(d,(cx,y+1),nm,fS,SUB); cx+=tw(d,nm,fS)+4
        rrect(d,(cx,y-1,cx+22,y+15),3,col,outline=(110,110,114),w=1); cx+=30
    y+=30

    head("Claude budget (estimate)")
    label("Plan:"); popup(160,150,"Custom"); y+=28
    label("5h budget (M tok):"); field(160,90,"108.6"); y+=28
    label("Weekly budget (M tok):"); field(160,90,"2238.9"); y+=30
    label("Calibrate:")
    text(d,(160,y+1),"real 5h used",fS,WHITE); field(238,42,"80")
    text(d,(286,y+1),"% weekly",fS,WHITE); field(338,42,"52"); text(d,(384,y+1),"%",fS,WHITE)
    rrect(d,(404,y-3,452,y+18),5,(92,92,98)); text(d,(428,y+1),"Calibrate",fS,WHITE,anchor="ma"); y+=22
    text(d,(160,y+1),"Run /usage in Claude Code, type the two numbers, click Calibrate.",fS,SUB); y+=24
    text(d,(20,y+1),"Claude has no official % on disk; calibrate it from /usage for accuracy.",fS,SUB); y+=30
    # footer
    fy=H-36
    rrect(d,(20,fy,150,fy+22),5,(92,92,98)); text(d,(85,fy+4),"Reset to defaults",fS,WHITE,anchor="ma")
    rrect(d,(W-90,fy,W-20,fy+22),5,ACCENT); text(d,(W-55,fy+4),"Done",fL,WHITE,anchor="ma")
    save(img,"settings.png")

render_menubar(); render_dropdown(); render_settings()
print("done")
