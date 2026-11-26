"""Render docs/slides/deck.html with headless Chromium (Chrome or Edge) over the DevTools protocol.

    python docs/slides/src/render.py

Writes docs/slides/slide-previews/slide-NN.png (1920x1080, one per slide) and docs/slides/Tenure_UHI11.pdf
(one slide per page, 1920x1080 px pages). Needs: `pip install websockets`, and Chrome or Edge installed
(set CHROME=/path/to/chrome to override the search).
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

import websockets

SLIDES = Path(__file__).resolve().parent.parent
DECK = SLIDES / "deck.html"
N_SLIDES = 10
PORT = 9341

CANDIDATES = [
    os.environ.get("CHROME", ""),
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    shutil.which("google-chrome") or "", shutil.which("chromium") or "", shutil.which("msedge") or "",
]


def browser() -> str:
    for c in CANDIDATES:
        if c and os.path.exists(c):
            return c
    raise SystemExit("no Chrome/Edge found; set CHROME=/path/to/chrome")


async def main() -> None:
    prof = tempfile.mkdtemp(prefix="deckprof")
    proc = subprocess.Popen([browser(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                             f"--remote-debugging-port={PORT}", f"--user-data-dir={prof}", "about:blank"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
                break
            except Exception:
                time.sleep(0.3)
        ws_url = [t for t in tabs if t["type"] == "page"][0]["webSocketDebuggerUrl"]
        async with websockets.connect(ws_url, max_size=2**29) as ws:
            seq = 0

            async def call(method, **params):
                nonlocal seq
                seq += 1
                me = seq
                await ws.send(json.dumps({"id": me, "method": method, "params": params}))
                while True:
                    r = json.loads(await ws.recv())
                    if r.get("id") == me:
                        if "error" in r:
                            raise RuntimeError(r["error"])
                        return r["result"]

            async def ready():
                for _ in range(100):
                    r = await call("Runtime.evaluate", returnByValue=True, awaitPromise=True,
                                   expression="document.fonts.ready.then(() => document.readyState === 'complete' && [...document.images].every(i => i.complete))")
                    if r["result"].get("value"):
                        return
                    await asyncio.sleep(0.1)

            await call("Page.enable")
            await call("Emulation.setDeviceMetricsOverride", width=1920, height=1080, deviceScaleFactor=1, mobile=False)
            url = DECK.as_uri()
            await call("Page.navigate", url=url + "#1")
            await asyncio.sleep(1.0)
            await ready()
            out = SLIDES / "slide-previews"
            out.mkdir(exist_ok=True)
            for n in range(1, N_SLIDES + 1):
                await call("Runtime.evaluate", expression=f"location.hash = '#{n}'")
                await asyncio.sleep(0.4)
                await ready()
                shot = await call("Page.captureScreenshot", format="png")
                (out / f"slide-{n:02d}.png").write_bytes(base64.b64decode(shot["data"]))
                print("wrote", f"slide-previews/slide-{n:02d}.png")
            await call("Emulation.clearDeviceMetricsOverride")
            pdf = await call("Page.printToPDF", printBackground=True, preferCSSPageSize=True,
                             marginTop=0, marginBottom=0, marginLeft=0, marginRight=0)
            (SLIDES / "Tenure_UHI11.pdf").write_bytes(base64.b64decode(pdf["data"]))
            print("wrote Tenure_UHI11.pdf")
    finally:
        proc.terminate()
        time.sleep(0.5)
        shutil.rmtree(prof, ignore_errors=True)


if __name__ == "__main__":
    asyncio.run(main())
