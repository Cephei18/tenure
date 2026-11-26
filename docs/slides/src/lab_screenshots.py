"""Capture the live Tenure Lab for slide 8 (asset H) with headless Chrome/Edge over the DevTools protocol.

    python docs/slides/src/lab_screenshots.py [url]        # default https://tenure-hazel.vercel.app/

Writes docs/slides/assets/H_lab_overview.png, H_lab_simulator.png, H_lab_live.png and H_lab_live_steps.png (2x).
Viewport 1024 CSS px wide (the narrowest width at which the Live proof list is a 4-column grid), deviceScaleFactor 2,
prefers-reduced-motion, sticky nav / toasts hidden. Each section is scrolled to the top of a tall viewport,
captured, and cropped by its getBoundingClientRect (no clip arithmetic across scroll offsets).
The Simulator is put in "Compare B vs C" and scrubbed to just after run C's FROZEN marker (block 170).
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

import websockets
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render import browser  # noqa: E402

PORT = 9333
W, H, DPR = 1024, 1700, 2
ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")
FROZEN_BLOCK_C = 170  # docs/RESULTS.md, headline seed: C FROZEN at block 170
SCRUB_TO = FROZEN_BLOCK_C + 2

def trim(im: Image.Image, margin: int = 40) -> Image.Image:
    """Drop rows/columns of plain page background (#14070c) around the content, keep `margin` px (2x)."""
    from PIL import ImageChops
    rgb = im.convert("RGB")
    diff = ImageChops.difference(rgb, Image.new("RGB", rgb.size, (0x14, 0x07, 0x0C))).convert("L").point(lambda v: 255 if v > 14 else 0)
    bb = diff.getbbox()
    if not bb:
        return im
    l, t, r, b = bb
    return im.crop((max(0, l - margin), max(0, t - margin), min(im.width, r + margin), min(im.height, b + margin)))


HIDE = """document.querySelectorAll('header, nav, [class*=sticky], [class*=fixed], [role=status], .toast-in')
  .forEach(e => e.style.setProperty('display','none','important'));"""


async def main(url: str) -> None:
    prof = tempfile.mkdtemp(prefix="labprof")
    p = subprocess.Popen([browser(), "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--remote-debugging-port={PORT}",
                          f"--user-data-dir={prof}", f"--window-size={W},{H}", "about:blank"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
                break
            except Exception:
                time.sleep(0.3)
        ws_url = [t for t in tabs if t["type"] == "page"][0]["webSocketDebuggerUrl"]
        async with websockets.connect(ws_url, max_size=2**28) as ws:
            n = 0

            async def call(m, **params):
                nonlocal n
                n += 1
                me = n
                await ws.send(json.dumps({"id": me, "method": m, "params": params}))
                while True:
                    r = json.loads(await ws.recv())
                    if r.get("id") == me:
                        if "error" in r:
                            raise RuntimeError(r["error"])
                        return r["result"]

            async def js(expr):
                r = await call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
                return r["result"].get("value")

            async def shoot(name, top_sel, bottom_sel=None, pad=24):
                await js(f"document.querySelector('{top_sel}').scrollIntoView({{block:'start', behavior:'instant'}}); window.scrollBy(0, -{pad})")
                await asyncio.sleep(1.5)
                await js(HIDE)
                rect = await js(f"""(() => {{ const a = document.querySelector('{top_sel}').getBoundingClientRect();
                    const b = document.querySelector('{bottom_sel or top_sel}').getBoundingClientRect();
                    return [a.left, a.top, a.right, b.bottom]; }})()""")
                shot = await call("Page.captureScreenshot", format="png")
                im = Image.open(io.BytesIO(base64.b64decode(shot["data"])))
                l, t, r, b = rect
                box = (max(0, int((l - pad) * DPR)), max(0, int((t - pad) * DPR)),
                       min(im.width, int((r + pad) * DPR)), min(im.height, int((b + pad) * DPR)))
                out = os.path.join(ASSETS, f"H_lab_{name}.png")
                img = trim(im.crop(box))
                img.save(out, optimize=True)
                print("wrote", out, img.size)

            await call("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=DPR, mobile=False)
            await call("Emulation.setEmulatedMedia", features=[{"name": "prefers-reduced-motion", "value": "reduce"}])
            await call("Page.enable")
            await call("Page.navigate", url=url)
            # wait for the live RPC reads: the hero tiles show "…" until the chain answers
            for _ in range(60):
                await asyncio.sleep(0.5)
                ok = await js("!!document.querySelector('#overview') && !document.querySelector('#overview').innerText.includes('…')")
                if ok:
                    break
            await asyncio.sleep(3)
            await js(HIDE)

            await shoot("overview", "#overview")
            # Simulator: Compare B vs C, scrubbed just past C's FROZEN marker
            await js("""[...document.querySelectorAll('#simulator [role=radio]')].find(b => b.textContent.includes('Compare')).click()""")
            await asyncio.sleep(0.5)
            await js(f"""(() => {{ const el = document.querySelector('#simulator input[aria-label=Block]');
                const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                set.call(el, '{SCRUB_TO}'); el.dispatchEvent(new Event('input', {{bubbles: true}}));
                el.dispatchEvent(new Event('change', {{bubbles: true}})); return el.value; }})()""")
            await asyncio.sleep(2)
            await shoot("simulator", "#simulator", "#sim-player")
            await shoot("live", "#live")
            await shoot("live_steps", "#live-steps", pad=8)
    finally:
        p.terminate()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "https://tenure-hazel.vercel.app/"))
