#!/usr/bin/env python3
"""Draws the charts in images/ from paired results (results/*.json).

  python3 tool/charts.py results/<pair>.json [more results/<pair>.json ...]

Writes images/chart_scenes.svg and images/chart_scaling.svg from the first
result, and images/chart_phones.svg with one group of bars per result when
several are given. Turn them into PNG with any browser, e.g.
  chrome --headless --screenshot=images/chart_scenes.png --window-size=920,520 images/chart_scenes.svg
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SURFACE, INK, SECOND, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
FIRST, OTHER = "#2a78d6", "#eb6834"
FONT = 'font-family="system-ui, -apple-system, Segoe UI, sans-serif"'
SCENES = {
    "hatch": "Hatched shapes", "chart": "Line chart", "grid": "Graph paper", "waveform": "Waveform",
    "starfield": "Starfield", "wireframe": "Wireframe sphere", "spiro": "Long polyline", "rain": "Rain",
}


def text(x, y, value, size=13, fill=INK, anchor="start", weight="400"):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" text-anchor="{anchor}" '
        f'font-weight="{weight}" {FONT}>{value}</text>'
    )


def legend(x, y, a, b):
    return (
        f'<rect x="{x}" y="{y - 10}" width="12" height="12" rx="2" fill="{FIRST}"/>'
        + text(x + 18, y, a, 13, SECOND)
        + f'<rect x="{x + 170}" y="{y - 10}" width="12" height="12" rx="2" fill="{OTHER}"/>'
        + text(x + 188, y, b, 13, SECOND)
    )


def bar(x, y, width, height, fill):
    # Square at the baseline, 4 px rounded at the data end.
    r = min(4, width / 2)
    return (
        f'<path d="M{x:.1f},{y:.1f} h{width - r:.1f} a{r},{r} 0 0 1 {r},{r} v{height - 2 * r:.1f} '
        f'a{r},{r} 0 0 1 -{r},{r} h-{width - r:.1f} z" fill="{fill}"/>'
    )


def scenes(rows, a, b, title_a, title_b):
    found = [r for r in rows if r["spec"] in SCENES]
    found.sort(key=lambda r: -r[a]["rasterInstructions"])
    left, right, top, pitch = 190, 800, 112, 44
    width, height = 920, top + pitch * len(found) + 56
    scale = (right - left) / 80e6
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>',
        text(24, 36, "Raster thread work per frame, eight scenes drawn with drawRawPoints", 17, INK, weight="600"),
        text(24, 58, "Million CPU instructions per frame. OnePlus 6, Impeller on OpenGL ES, profile build, middle of three paired rounds.", 12.5, SECOND),
        legend(24, 86, title_a, title_b),
    ]
    for tick in range(0, 81, 20):
        x = left + tick * 1e6 * scale
        out.append(f'<line x1="{x:.1f}" y1="{top - 6}" x2="{x:.1f}" y2="{top + pitch * len(found) - 8}" stroke="{AXIS if tick == 0 else GRID}" stroke-width="1"/>')
        out.append(text(x, top + pitch * len(found) + 10, str(tick), 12, MUTED, "middle"))
    out.append(text(left, top + pitch * len(found) + 32, "Million instructions per frame", 12, MUTED))
    for index, row in enumerate(found):
        y = top + index * pitch
        first, other = row[a]["rasterInstructions"], row[b]["rasterInstructions"]
        out.append(text(left - 12, y + 11, SCENES[row["spec"]], 13, INK, "end"))
        out.append(text(left - 12, y + 26, f'{row[a]["segments"]:,} segments', 11.5, MUTED, "end"))
        out.append(bar(left, y, first * scale, 13, FIRST))
        out.append(bar(left, y + 15, max(other * scale, 3), 13, OTHER))
        change = (other - first) / first * 100
        out.append(text(left + first * scale + 8, y + 11, f"{first / 1e6:.1f}", 12, SECOND))
        out.append(text(left + max(other * scale, 3) + 8, y + 26, f"{other / 1e6:.1f}  ({change:+.0f}%)".replace("-", "−"), 12, SECOND))
    out.append("</svg>")
    return "\n".join(out)


def scaling(rows, a, b, title_a, title_b):
    points = []
    for row in rows:
        spec = row["spec"]
        if spec.startswith("lines:n=") and "," not in spec:
            points.append((int(spec.split("=")[1]), row[a]["rasterInstructions"], row[b]["rasterInstructions"]))
    points.sort()
    left, right, top, bottom = 70, 760, 112, 400
    width, height = 920, 460
    sx = (right - left) / 1600
    sy = (bottom - top) / 30e6
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>',
        text(24, 36, "Raster thread work per frame, by lines in one drawRawPoints call", 17, INK, weight="600"),
        text(24, 58, "Million CPU instructions per frame. Parallel lines, 1.2 px wide, round caps. OnePlus 6, Impeller on OpenGL ES.", 12.5, SECOND),
        legend(24, 86, title_a, title_b),
    ]
    for tick in range(0, 31, 10):
        y = bottom - tick * 1e6 * sy
        out.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="{AXIS if tick == 0 else GRID}" stroke-width="1"/>')
        out.append(text(left - 10, y + 4, str(tick), 12, MUTED, "end"))
    for tick in (0, 400, 800, 1200, 1600):
        out.append(text(left + tick * sx, bottom + 20, f"{tick:,}", 12, MUTED, "middle"))
    out.append(text(left, bottom + 44, "Lines in the call", 12, MUTED))
    for which, color in ((1, FIRST), (2, OTHER)):
        path = " ".join(
            f'{"M" if i == 0 else "L"}{left + p[0] * sx:.1f},{bottom - p[which] * sy:.1f}'
            for i, p in enumerate(points)
        )
        out.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        for p in points:
            out.append(f'<circle cx="{left + p[0] * sx:.1f}" cy="{bottom - p[which] * sy:.1f}" r="4" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
    last = points[-1]
    out.append(text(right + 12, bottom - last[1] * sy + 4, f"{title_a}: {last[1] / 1e6:.1f}", 12.5, SECOND))
    out.append(text(right + 12, bottom - last[2] * sy + 4, f"{title_b}: {last[2] / 1e6:.1f}", 12.5, SECOND))
    out.append("</svg>")
    return "\n".join(out)


def phones(results, title_a, title_b):
    """The hatch scene on every phone: one pair of bars per result."""
    left, right, top, pitch = 250, 800, 112, 52
    width, height = 920, top + pitch * len(results) + 56
    scale = (right - left) / 20e6
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>',
        text(24, 36, "The hatched shapes scene on three phones", 17, INK, weight="600"),
        text(24, 58, "Million CPU instructions per frame on the raster thread. 963 line segments in 8 drawRawPoints calls (931 on the Pixel 5).", 12.5, SECOND),
        legend(24, 86, title_a, title_b),
    ]
    bottom = top + pitch * len(results) - 8
    for tick in range(0, 21, 5):
        x = left + tick * 1e6 * scale
        out.append(f'<line x1="{x:.1f}" y1="{top - 6}" x2="{x:.1f}" y2="{bottom}" stroke="{AXIS if tick == 0 else GRID}" stroke-width="1"/>')
        out.append(text(x, bottom + 18, str(tick), 12, MUTED, "middle"))
    out.append(text(left, bottom + 40, "Million instructions per frame", 12, MUTED))
    for index, result in enumerate(results):
        a, b = list(result["apps"])
        row = next(r for r in result["scenarios"] if r["spec"] == "hatch")
        first, other = row[a]["rasterInstructions"], row[b]["rasterInstructions"]
        phone = result["phone"]
        y = top + index * pitch
        out.append(text(left - 12, y + 11, phone["model"].replace("Google ", ""), 13, INK, "end"))
        out.append(text(left - 12, y + 26, f'{phone["backend"].replace("Impeller ", "")}, {phone["refreshHz"]} Hz', 11.5, MUTED, "end"))
        out.append(bar(left, y, first * scale, 13, FIRST))
        out.append(bar(left, y + 15, max(other * scale, 3), 13, OTHER))
        change = (other - first) / first * 100
        out.append(text(left + first * scale + 8, y + 11, f"{first / 1e6:.1f}", 12, SECOND))
        out.append(text(left + max(other * scale, 3) + 8, y + 26, f"{other / 1e6:.1f}  ({change:+.0f}%)".replace("-", "−"), 12, SECOND))
    out.append("</svg>")
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    results = [json.loads(Path(name).read_text()) for name in sys.argv[1:]]
    result = results[0]
    a, b = list(result["apps"])
    title_a, title_b = "Unpatched engine", "Patched engine"
    images = ROOT / "images"
    images.mkdir(exist_ok=True)
    (images / "chart_scenes.svg").write_text(scenes(result["scenarios"], a, b, title_a, title_b))
    (images / "chart_scaling.svg").write_text(scaling(result["scenarios"], a, b, title_a, title_b))
    made = "images/chart_scenes.svg images/chart_scaling.svg"
    if len(results) > 1:
        (images / "chart_phones.svg").write_text(phones(results, title_a, title_b))
        made += " images/chart_phones.svg"
    print(made)


if __name__ == "__main__":
    main()
