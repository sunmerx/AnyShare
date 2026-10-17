# E-2 latency clock (glass-to-glass measurement rig)

Measures the true end-to-end latency of the screen-sharing pipeline
(capture → encode → network → decode → display) **without any cross-machine
clock synchronization**, by photographing two screens in one frame:

| Screen | Content | Meaning |
|---|---|---|
| Physical screen (this PC) | "reference" clock | what the sender renders *live* |
| Target device screen (e.g. Ubuntu via ffplay) | "stream" clock | the same clock as it arrives through the pipeline |

One phone photo of both screens shows two readings; their difference is the
glass-to-glass latency.

## Usage (Windows, sender side)

```powershell
# auto-detect the virtual display (smallest screen), run until Escape/close
powershell -sta -NoProfile -ExecutionPolicy Bypass -File clock-windows.ps1

# explicit virtual-screen index + auto-stop after 120 s
powershell -sta -NoProfile -ExecutionPolicy Bypass -File clock-windows.ps1 -VirtualScreenIndex 2 -Seconds 120
```

Start the video stream first (E-2 demo rig; the stream script lives in the
local-only `docs/` tree, not in this repository), then run this tool. Screens
are listed with their device names/bounds in the console so you can verify the
assignment; the auto-pick warns loudly because "smallest screen" is a
heuristic, not a guarantee.

## Procedure

1. Start the stream to the target device.
2. Run this tool; verify the two windows land on the right screens.
3. Hold one phone so **both screens are in the same photo**; take 5+ photos.
4. Read both clock values in a photo; `target − reference` = latency.
5. Discard outliers (shutter/refresh beat), report the median.

## Pitfalls

- Phone shutter can smear the decimals; prefer a dark room + short exposure if possible.
- The two clock windows update every 16 ms; values within one refresh period
  (~17 ms at 60 Hz) are the measurement resolution floor.
- Do not resize/move windows after the photo setup is validated.
- To stop: press Escape, or close either clock window. (`Ctrl+C` does not
  reliably interrupt the WinForms message loop - use Escape/Alt+F4 or `-Seconds`.)
- On a single-screen machine (or if the VDD is set as primary) the tool errors
  out - the reference and stream clocks must be on two different displays.
