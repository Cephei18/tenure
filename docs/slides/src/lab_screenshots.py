"""Capture Tenure Lab sections for slide 8 (asset H) with headless Chrome/Edge over the DevTools protocol.

    cd frontend && npx vite --port 5179          # terminal 1: the Lab
    python docs/slides/src/lab_screenshots.py http://localhost:5179/ <out_dir> live simulator
    python docs/slides/src/make_assets.py <out_dir>   # crops them into assets/H_lab_*.png

Viewport 960x1500 CSS px at 2x, prefers-reduced-motion, the sticky header hidden, each section scrolled to the top.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

import websockets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render import browser  # noqa: E402

PORT = 9333


async def main(url: str, outdir: str, ids: list[str]) -> None:
    os.makedirs(outdir, exist_ok=True)
    prof = tempfile.mkdtemp(prefix="labprof")
    p = subprocess.Popen([browser(), "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--remote-debugging-port={PORT}",
                          f"--user-data-dir={prof}", "--window-size=960,1500", "about:blank"],
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
                        return r.get("result", r)

            await call("Emulation.setDeviceMetricsOverride", width=960, height=1500, deviceScaleFactor=2, mobile=False)
            await call("Emulation.setEmulatedMedia", features=[{"name": "prefers-reduced-motion", "value": "reduce"}])
            await call("Page.enable")
            await call("Page.navigate", url=url)
            await asyncio.sleep(9)  # live RPC reads + charts
            await call("Runtime.evaluate", expression="document.querySelectorAll('header, nav, [class*=sticky], [class*=fixed]')"
                                                      ".forEach(e => e.style.setProperty('display','none','important'))")
            for sid in ids:
                await call("Runtime.evaluate", expression=f"document.getElementById('{sid}').scrollIntoView({{block:'start', behavior:'instant'}})")
                await asyncio.sleep(3)
                shot = await call("Page.captureScreenshot", format="png")
                with open(os.path.join(outdir, f"{sid}.png"), "wb") as f:
                    f.write(base64.b64decode(shot["data"]))
                print("captured", sid)
    finally:
        p.terminate()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3:] or ["live", "simulator"]))
