"""Build docs/slides/Tenure_UHI11.pptx: an editable PowerPoint version of deck.html (same content, images, notes).

    python docs/slides/src/build_pptx.py

Layout mirrors deck.html in slide pixels (1920x1080 -> 13.333 x 7.5 in, so 1 px = 6350 EMU and a CSS font size of
N px = N/2 pt). Text is real, editable text in Inter (bundled in docs/slides/fonts/; PowerPoint substitutes a
system sans if Inter is not installed). Charts and diagrams are the PNGs in docs/slides/assets/. Speaker notes are
parsed from the <aside class="notes"> blocks of deck.html, so the two decks cannot drift apart.
"""

from __future__ import annotations

import html
import json
import os
import re
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Emu, Pt
from PIL import Image

SLIDES = Path(__file__).resolve().parent.parent
ROOT = SLIDES.parent.parent
A = SLIDES / "assets"
FONT = "Inter"

_tok = ROOT / "docs" / "design-tokens.json"
C = {"bg": "#14070c", "surface": "#1f0a12", "surface2": "#2a0f19", "border": "#3d1724", "primary": "#e11d48",
     "accent": "#f472b6", "soft": "#fbcfe8", "text": "#ffffff", "muted": "#c99aae", "full": "#4ade80",
     "restricted": "#fbbf24", "frozen": "#e11d48"}
if _tok.exists():
    C.update({k: v for k, v in json.loads(_tok.read_text(encoding="utf-8"))["color"].items() if k in C})


def rgb(h: str) -> RGBColor:
    return RGBColor.from_string(h.lstrip("#").upper())


def E(px: float) -> Emu:
    return Emu(int(round(px * 6350)))


def notes_from_html() -> list[str]:
    src = (SLIDES / "deck.html").read_text(encoding="utf-8")
    out = []
    for block in re.findall(r'<aside class="notes">(.*?)</aside>', src, flags=re.S):
        items = re.findall(r"<li>(.*?)</li>", block, flags=re.S)
        out.append("\n".join("- " + html.unescape(re.sub(r"<[^>]+>", "", i)).strip() for i in items))
    return out


class Deck:
    def __init__(self):
        self.prs = Presentation()
        self.prs.slide_width, self.prs.slide_height = E(1920), E(1080)
        self.blank = self.prs.slide_layouts[6]
        self.n = 0

    def slide(self, footer=True):
        s = self.prs.slides.add_slide(self.blank)
        s.background.fill.solid()
        s.background.fill.fore_color.rgb = rgb(C["bg"])
        self.n += 1
        if footer:
            self.text(s, 96, 1022, 600, 30, "Tenure · UHI11", 20, C["muted"])
            self.text(s, 1524, 1022, 300, 30, str(self.n), 20, C["muted"], align=PP_ALIGN.RIGHT)
        return s

    def box(self, s, x, y, w, h, fill=None, line=None, lw=2, r=16, name=None):
        shp = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, E(x), E(y), E(w), E(h))
        shp.adjustments[0] = min(0.5, r / min(w, h))
        if fill:
            shp.fill.solid()
            shp.fill.fore_color.rgb = rgb(fill)
        else:
            shp.fill.background()
        if line:
            shp.line.color.rgb = rgb(line)
            shp.line.width = E(lw)
        else:
            shp.line.fill.background()
        shp.shadow.inherit = False
        if name:
            shp.name = name
        return shp

    def text(self, s, x, y, w, h, content, size=24, color=None, bold=False, align=PP_ALIGN.LEFT,
             anchor=MSO_ANCHOR.TOP, spacing=None, caps=False, line_spacing=1.15, name=None, link=None):
        """content: str, or list of paragraphs; a paragraph is a str or a list of (text, color, bold[, size])."""
        tb = s.shapes.add_textbox(E(x), E(y), E(w), E(h))
        if name:
            tb.name = name
        tf = tb.text_frame
        tf.word_wrap = True
        tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
        tf.vertical_anchor = anchor
        paras = content if isinstance(content, list) else [content]
        for i, para in enumerate(paras):
            p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
            p.alignment = align
            p.line_spacing = line_spacing
            runs = para if isinstance(para, list) else [(para, color, bold)]
            for run in runs:
                t, c, b = run[0], run[1] or color or C["text"], run[2]
                sz = run[3] if len(run) > 3 else size
                r = p.add_run()
                r.text = t.upper() if caps else t
                f = r.font
                f.name = FONT
                f.size = Pt(sz / 2)
                f.bold = b
                f.color.rgb = rgb(c)
                if link:
                    r.hyperlink.address = link
                    f.color.rgb = rgb(c)  # keep the theme colour, not the default hyperlink blue
                if spacing:
                    rPr = r._r.get_or_add_rPr()
                    rPr.set("spc", str(int(spacing * 100)))
        return tb

    def image(self, s, path, x, y, w=None, h=None, alt=""):
        iw, ih = Image.open(path).size
        if w and not h:
            h = w * ih / iw
        elif h and not w:
            w = h * iw / ih
        pic = s.shapes.add_picture(str(path), E(x), E(y), E(w), E(h))
        pic._element.nvPicPr.cNvPr.set("descr", alt)
        return pic

    def shot(self, s, path, x, y, w, vis_h=None, top=0, alt=""):
        """A screenshot with a 2 px border, optionally cropped to vis_h slide px starting `top` px down."""
        iw, ih = Image.open(path).size
        full_h = w * ih / iw
        vis_h = vis_h or full_h
        pic = s.shapes.add_picture(str(path), E(x), E(y), E(w), E(vis_h))
        pic.crop_top = top / full_h
        pic.crop_bottom = max(0.0, 1 - (top + vis_h) / full_h)
        pic._element.nvPicPr.cNvPr.set("descr", alt)
        self.box(s, x, y, w, vis_h, fill=None, line=C["border"], lw=2, r=12)
        return pic

    def kicker_title(self, s, kicker, title):
        self.text(s, 96, 84, 1728, 34, kicker, 22, C["accent"], True, caps=True, spacing=3.5)
        self.text(s, 96, 116, 1728, 80, title, 60, C["text"], True, line_spacing=1.0)


def theme_hyperlinks(path: Path, color: str) -> None:
    """PowerPoint paints hyperlinks with the theme's hlink colour (default dark blue, unreadable on this background)
    and ignores the run colour, so set hlink/folHlink in every theme part to the deck's accent."""
    import zipfile
    tmp = path.with_suffix(".tmp")
    hexv = color.lstrip("#").upper()
    with zipfile.ZipFile(path) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename.startswith("ppt/theme/theme") and item.filename.endswith(".xml"):
                x = data.decode("utf-8")
                for tag in ("hlink", "folHlink"):
                    x = re.sub(rf"<a:{tag}>.*?</a:{tag}>", f'<a:{tag}><a:srgbClr val="{hexv}"/></a:{tag}>', x, flags=re.S)
                data = x.encode("utf-8")
            zout.writestr(item, data)
    tmp.replace(path)


def build():
    d = Deck()
    notes = notes_from_html()
    soft, muted, acc, txt = C["soft"], C["muted"], C["accent"], C["text"]

    # 1 title
    s = d.slide(footer=False)
    d.text(s, 96, 282, 1100, 34, "A Uniswap v4 hook · UHI11 · Curated Liquidity", 22, acc, True, caps=True, spacing=3.5)
    d.text(s, 92, 330, 1100, 220, "Tenure", 220, txt, True, line_spacing=0.9)
    d.text(s, 96, 570, 1100, 150, ["Earned autonomy for", "AI liquidity curators"], 60, soft, True, line_spacing=1.1)
    d.text(s, 96, 764, 900, 44, "Gopika Chauhan", 34, txt, True)
    for i, (name, fill, ink) in enumerate((("FULL", C["full"], C["bg"]), ("RESTRICTED", C["restricted"], C["bg"]),
                                           ("FROZEN", C["frozen"], txt))):
        y = 330 + i * 154
        b = d.box(s, 1340, y, 430, 92, fill=fill, r=46, name=f"tier {name}")
        d.text(s, 1340, y, 430, 92, name, 38, ink, True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, spacing=2)
        if i < 2:
            d.text(s, 1340, y + 98, 430, 50, "↓", 30, muted, align=PP_ALIGN.CENTER)

    # 2 problem
    s = d.slide()
    d.kicker_title(s, "The problem", "Curators are trusted with everything")
    pts = [("Curators are fully trusted.", "Stream Finance, Nov 2025: curator vault deposits fell from ~$10B to ~$6.9B."),
           ("AI curators can be poisoned undetectably.",
            "Princeton, “AI Agents in Cryptoland”: memory injection works; detectors help little once stored context is corrupted.")]
    y = 244
    for head, sub in pts:
        d.text(s, 96, y, 980, 54, head, 40, txt, True)
        d.text(s, 96, y + 56, 960, 70, sub, 23, muted, line_spacing=1.3)
        y += 166
    d.text(s, 96, y, 960, 120, [[("A poisoned curator doesn't steal. ", txt, True), ("It bleeds the vault", acc, True),
                                 (" with small, valid-looking decisions.", txt, True)]], 40, line_spacing=1.2)
    d.box(s, 1120, 244, 704, 542, fill=C["surface"], line=C["border"], name="tools card")
    d.text(s, 1158, 282, 640, 34, "Today's tools", 24, acc, True, caps=True, spacing=3)
    tools = [("Static caps", " (Arrakis-style)", "Stop one big loss, miss many small ones."),
             ("Guardians & timelocks", " (Morpho, Yearn)", "Need a human awake."),
             ("Curator scorecards", "", "Read after the damage."),
             ("Agent spending limits", " (Kusari)", "Limit what an agent does, not how well.")]
    for i, (a, b, c) in enumerate(tools):
        y = 330 + i * 106
        ln = s.shapes.add_connector(1, E(1158), E(y), E(1786), E(y))
        ln.line.color.rgb = rgb(C["border"])
        ln.line.width = E(2)
        d.text(s, 1158, y + 16, 640, 36, [[(a, txt, True, 27), (b, muted, False, 22)]], 27)
        d.text(s, 1158, y + 54, 640, 34, c, 24, soft)

    # 3 insight
    s = d.slide()
    d.text(s, 96, 286, 1728, 34, "The insight", 22, acc, True, align=PP_ALIGN.CENTER, caps=True, spacing=3.5)
    d.text(s, 96, 338, 1728, 240, [[("Don't detect the compromise.", txt, True)], [("Measure the damage.", acc, True)]],
           104, align=PP_ALIGN.CENTER, line_spacing=1.0)
    d.text(s, 96, 612, 1728, 50, "Human, bot or poisoned AI: a harmful decision is harmful whoever made it.", 36, soft,
           align=PP_ALIGN.CENTER)
    x = 432
    for lab, w, hi in (("Human", 160, False), ("Bot", 108, False), ("Poisoned AI", 224, False)):
        d.box(s, x, 728, w, 66, fill=C["surface"], line=C["border"], r=33)
        d.text(s, x, 728, w, 66, lab, 28, txt, True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        x += w + 22
    d.text(s, x, 728, 50, 66, "→", 36, acc, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    d.box(s, x + 72, 728, 436, 66, fill=C["surface2"], line=C["primary"], r=33)
    d.text(s, x + 72, 728, 436, 66, "same decision, same grade", 28, txt, True, align=PP_ALIGN.CENTER,
           anchor=MSO_ANCHOR.MIDDLE)

    # 4 layers
    s = d.slide()
    d.kicker_title(s, "How Tenure works", "Four layers")
    cards = [("Mandate", "Depositor rules enforced by the hook. Changes are timelocked."),
             ("Decision scoring", "Every rebalance graded twice at a fair oracle price."),
             ("Budget → autonomy", "Losses drain, time refills. FULL → RESTRICTED → FROZEN."),
             ("Reputation", "Proven good decisions earn a bigger budget and deposit cap.")]
    for i, (t, b) in enumerate(cards):
        x = 96 + i * 439
        d.box(s, x, 236, 411, 262, fill=C["surface"], line=C["border"])
        o = s.shapes.add_shape(MSO_SHAPE.OVAL, E(x + 32), E(268), E(48), E(48))
        o.fill.solid(); o.fill.fore_color.rgb = rgb(C["primary"]); o.line.fill.background()
        d.text(s, x + 32, 268, 48, 48, str(i + 1), 24, txt, True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        d.text(s, x + 32, 334, 360, 44, t, 32, txt, True)
        d.text(s, x + 32, 384, 350, 110, b, 24, soft, line_spacing=1.3)
    d.image(s, A / "C_tiers.png", 96, 532, w=1728, alt="Tier bar: FROZEN below 20%, RESTRICTED 20-50%, FULL from 50%; guardian restore to 35%.")
    d.text(s, 96, 848, 1400, 44, [[("✓ ", C["full"], True), ("Depositors can always withdraw, in every tier.", txt, True)]], 30)

    # 5 how
    s = d.slide()
    d.kicker_title(s, "How it works", "Every rebalance is graded twice")
    d.image(s, A / "B_lifecycle.png", 96, 228, w=1728, alt="Rebalance lifecycle in five steps.")
    d.box(s, 96, 638, 1728, 98, fill=C["surface"], line=C["border"])
    d.text(s, 134, 638, 1680, 98, [[("MARKOUT   ", acc, True, 22), ("alpha = NAV(new position) − NAV(did nothing), ", txt, True, 36),
                                    ("at the fair price, 50 blocks later", soft, True, 36)]], 36, anchor=MSO_ANCHOR.MIDDLE)
    d.text(s, 96, 780, 240, 80, ["WHY IT MUST", "BE A HOOK"], 22, acc, True, anchor=MSO_ANCHOR.MIDDLE, spacing=3)
    for i, t in enumerate(("Blocks unmeasured liquidity moves", "Reads the pool independently", "Settles grades on ordinary swaps")):
        x = 354 + i * 500
        d.box(s, x, 768, 470, 108, fill=C["surface"], line=C["border"])
        d.text(s, x + 28, 768, 430, 108, [[("✓  ", C["full"], True, 30), (t, txt, True, 26)]], 26, anchor=MSO_ANCHOR.MIDDLE)

    # 6 reactive
    s = d.slide()
    d.kicker_title(s, "Reactive Network", "Two problems a single chain can't solve")
    rows = [("Problem 1", "Grades are due 50 blocks later. Settling inside a swap cost that trader ~146k extra gas.",
             "Keeper-free settlement from Lasna.", "Deployed and reacting live; the callback path is proven in tests."),
            ("Problem 2", "A curator caught in one vault stayed free in its others.",
             "FROZEN is relayed across vaults and chains.", "Freeze-only: a compromised relay can't hurt depositors.")]
    for i, (pl, pt, st, ss) in enumerate(rows):
        y = 212 + i * 176
        d.box(s, 96, y, 832, 150, fill=C["surface"], line=C["border"])
        d.text(s, 126, y + 22, 780, 26, pl, 19, muted, True, caps=True, spacing=3)
        d.text(s, 126, y + 54, 780, 90, pt, 29, txt, True, line_spacing=1.2)
        d.text(s, 928, y, 64, 150, "→", 40, acc, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
        d.box(s, 992, y, 832, 150, fill=C["surface2"], line=acc)
        d.text(s, 1022, y + 22, 780, 26, "Solution", 19, acc, True, caps=True, spacing=3)
        d.text(s, 1022, y + 54, 780, 40, st, 29, txt, True)
        d.text(s, 1022, y + 96, 780, 34, ss, 21, muted)
    d.text(s, 96, 562, 1600, 34, [[("PROOF, LIVE ON TESTNET   ", acc, True, 22), ("vault A froze → Lasna reacted → vault B froze", muted, False, 22)]], 22)
    d.image(s, A / "E_relay_timeline.png", 160, 606, w=1600, alt="Relay timeline: 68,837,823 -> Lasna 9,291,302 -> 68,837,825: 2 blocks, ~2 seconds.")

    # 7 chainlink + unichain
    s = d.slide()
    d.kicker_title(s, "Chainlink + Unichain", "A fair price, and a cheap place to grade")
    d.text(s, 96, 222, 860, 40, "Chainlink", 30, txt, True)
    d.box(s, 96, 268, 860, 112, fill=C["surface"], line=C["border"])
    d.text(s, 126, 288, 800, 26, "Problem", 19, muted, True, caps=True, spacing=3)
    d.text(s, 126, 320, 800, 50, "The pool's own price can be pushed within one block.", 29, txt, True)
    d.box(s, 96, 396, 860, 150, fill=C["surface2"], line=acc)
    d.text(s, 126, 416, 800, 26, "Solution", 19, acc, True, caps=True, spacing=3)
    d.text(s, 126, 448, 800, 90, "Every measurement uses a manipulation-resistant fair price.", 29, txt, True, line_spacing=1.2)
    d.text(s, 96, 576, 860, 40, "Unichain", 30, txt, True)
    d.box(s, 96, 622, 860, 150, fill=C["surface"], line=C["border"])
    d.text(s, 126, 642, 800, 26, "Problem", 19, muted, True, caps=True, spacing=3)
    d.text(s, 126, 674, 800, 90, "Grading adds ~538k gas per rebalance: ~$16 on mainnet.", 29, txt, True, line_spacing=1.2)
    d.text(s, 96, 792, 860, 28, "Solution · grade on a 1-second L2", 19, acc, True, caps=True, spacing=3)
    for i, (big, lab, col) in enumerate((("~1.6¢", "per rebalance", acc), ("< 1 min", "for the 50-block window", txt),
                                         ("~17%", "more gas per swap", txt))):
        x = 96 + i * 292
        d.box(s, x, 828, 276, 96, fill=C["surface"], line=C["border"])
        d.text(s, x + 18, 840, 250, 46, big, 36, col, True)
        d.text(s, x + 18, 888, 250, 28, lab, 19, muted)
    d.image(s, A / "A_architecture.png", 1012, 232, w=800, alt="Architecture diagram.")

    # 8 live demo: 2x2 grid of 852 px cells (same geometry as deck.html)
    s = d.slide()
    d.kicker_title(s, "Live demo · Unichain Sepolia + Reactive Lasna", "The attack, live on testnet")
    d.text(s, 1224, 132, 600, 44, "https://tenure-hazel.vercel.app/", 30, acc, True, align=PP_ALIGN.RIGHT,
           link="https://tenure-hazel.vercel.app/")
    d.shot(s, A / "H_lab_overview.png", 96, 216, 852, vis_h=237, top=202, alt="Tenure Lab overview: live tiles (vault A FROZEN, budget 17.0%, vault B relayFrozen true).")
    for i, (t, col) in enumerate((("Poisoned at tick 20 → FROZEN at tick 25", C["frozen"]),
                                  ("Relayed to vault B in 2 blocks", acc),
                                  ("Depositor withdrew everything while FROZEN", C["full"]))):
        y = 470 + i * 40
        o = s.shapes.add_shape(MSO_SHAPE.OVAL, E(96), E(y + 13), E(14), E(14))
        o.fill.solid(); o.fill.fore_color.rgb = rgb(col); o.line.fill.background()
        d.text(s, 124, y, 820, 40, t, 27, txt, True, anchor=MSO_ANCHOR.MIDDLE)
    d.shot(s, A / "H_lab_simulator.png", 972, 216, 852, vis_h=383, top=0, alt="Tenure Lab simulator, Compare B vs C at block 172: static caps FULL, Tenure FROZEN.")
    d.shot(s, A / "H_lab_live_steps.png", 96, 618, 852, alt="Tenure Lab live proof: the 8 proven steps, relay to vault B 2 blocks later.")
    d.image(s, A / "D_live_budget.png", 972, 618, w=852, alt="Vault A budget per tick, live Tick events: poisoned 20, RESTRICTED 23, FROZEN 25.")

    # 9 results
    s = d.slide()
    d.kicker_title(s, "Results", "Same attack, with and without Tenure")
    for i, (big, lab, col) in enumerate((("20/20", ["attack runs", "frozen"], C["primary"]),
                                         ("never", ["honest curator", "restricted"], C["full"]),
                                         ("−59%", ["attacker profit", "(median)"], acc))):
        x = 96 + i * 585
        d.box(s, x, 222, 557, 142, fill=C["surface"], line=C["border"])
        d.text(s, x + 32, 236, 300, 100, big, 68, col, True, anchor=MSO_ANCHOR.MIDDLE)
        d.text(s, x + 255 if i != 2 else x + 255, 270, 290, 80, lab, 25, soft, line_spacing=1.1)
    d.image(s, A / "F_results.png", 96, 404, w=840, alt="Slow bleed 9.52% vs 1.74% of NAV; attacker profit 1,587 vs 650 tokens.")
    d.image(s, A / "G_playground.png", 984, 404, w=840, alt="Losses let through: 8,376 / 8,376 / 2,471 tokens.")
    d.text(s, 96, 852, 1728, 40, [[("258", txt, True), (" Foundry + ", soft, False), ("53", txt, True), (" Python + ", soft, False),
                                   ("48", txt, True), (" frontend tests · Python and Solidity agree to the wei on ", soft, False),
                                   ("1,992", txt, True), (" vectors · ", soft, False), ("7", txt, True),
                                   (" invariants, ", soft, False), ("128,000", txt, True), (" random calls", soft, False)]], 25)

    # 10 close
    s = d.slide()
    d.kicker_title(s, "Tenure", "Autonomy that has to be earned")
    cols = [("Scorecards", "tell you after the damage.", 0, 514, False), ("Guardians", "need someone awake.", 542, 514, False),
            ("Tenure", "acts automatically, at the moment of every decision.", 1084, 644, True)]
    for lab, body, dx, w, hi in cols:
        x = 96 + dx
        d.box(s, x, 268, w, 330, fill=C["surface2"] if hi else C["surface"], line=C["primary"] if hi else C["border"])
        d.text(s, x + 36, 306, w - 72, 30, lab, 24, acc if hi else muted, True, caps=True, spacing=3)
        d.text(s, x + 36, 352, w - 72, 220, body, 50, txt, True, line_spacing=1.1)
    d.text(s, 96, 694, 560, 30, "Code", 24, muted, caps=True, spacing=3)
    d.text(s, 96, 730, 620, 50, "github.com/Cephei18/tenure", 36, txt, True)
    d.text(s, 680, 694, 560, 30, "Tenure Lab", 24, muted, caps=True, spacing=3)
    d.text(s, 680, 730, 700, 50, "https://tenure-hazel.vercel.app/", 36, acc, True, link="https://tenure-hazel.vercel.app/")
    d.text(s, 96, 838, 600, 44, "Thank you.", 30, soft)

    assert len(notes) == len(d.prs.slides), (len(notes), len(d.prs.slides))
    for sl, n in zip(d.prs.slides, notes):
        sl.notes_slide.notes_text_frame.text = n
    out = SLIDES / "Tenure_UHI11.pptx"
    d.prs.core_properties.title = "Tenure · UHI11"
    d.prs.core_properties.author = "Gopika Chauhan"
    d.prs.save(out)
    theme_hyperlinks(out, C["accent"])
    print("wrote", out.relative_to(ROOT))


if __name__ == "__main__":
    build()
