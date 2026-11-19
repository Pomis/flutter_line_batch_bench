#!/usr/bin/env python3
"""Builds the line batch bench and runs it on an Android phone over adb.

One build, every scenario in turn for several rounds:

  python3 tool/bench.py run
  python3 tool/bench.py run --scenarios scenes --counters
  python3 tool/bench.py run --flutter ~/src/flutter/bin/flutter --am-extra "--ez enable-impeller false"

Two engines against each other. Each APK needs an app id of its own, which
`build --suffix` gives it; the engines are then taken in turn, one launch per
scenario and engine, with CPU cycles and instructions counted per frame and
a hash of the pixels each engine drew:

  SRC=~/src/flutter/engine/src
  ENGINE="--local-engine=android_profile_arm64 --local-engine-host=host_profile_arm64 --local-engine-src-path=$SRC"
  python3 tool/bench.py build --suffix base    --flutter ~/src/flutter/bin/flutter --engine "$ENGINE" -o base.apk
  # ...switch the engine checkout to the other branch and rebuild it...
  python3 tool/bench.py build --suffix patched --flutter ~/src/flutter/bin/flutter --engine "$ENGINE" -o patched.apk
  python3 tool/bench.py pair base=base.apk patched=patched.apk

Scenario sets: `scenes` (eight small drawings), `lines` (plain lines, one
property changed at a time), `fallbacks` and `controls` (cases a change to
line batching should leave alone), `ways` (the same 800 lines by five ways of
drawing), `all`. A single scenario can be given as the app reads it, e.g.
`lines:n=800,cap=butt` (see lib/main.dart).

The counters need `simpleperf` from an Android NDK (found through
ANDROID_NDK_HOME, ANDROID_HOME or the default SDK folder) and a profile
build, which is what this builds. Results are printed and saved as JSON in
results/.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = "com.example.line_batch_bench"
DEVICE_SIMPLEPERF = "/data/local/tmp/simpleperf"

SCENES = ["hatch", "chart", "grid", "waveform", "starfield", "wireframe", "spiro", "rain"]
SETS: dict[str, list[tuple[str, str]]] = {
    "scenes": [(name, name) for name in SCENES],
    "lines": [
        ("2 lines", "lines:n=2"),
        ("10 lines", "lines:n=10"),
        ("50 lines", "lines:n=50"),
        ("100 lines", "lines:n=100"),
        ("400 lines", "lines:n=400"),
        ("800 lines", "lines:n=800"),
        ("1600 lines", "lines:n=1600"),
        ("800, butt caps", "lines:n=800,cap=butt"),
        ("800, square caps", "lines:n=800,cap=square"),
        ("800, 0.3 px wide", "lines:n=800,w=0.3"),
        ("800, 4 px wide", "lines:n=800,w=4"),
        ("800, 12 px wide", "lines:n=800,w=12"),
        ("800, crossing", "lines:n=800,layout=cross"),
        ("800 short ticks", "lines:n=800,layout=ticks"),
        ("800, random", "lines:n=800,layout=random"),
        ("800, opaque", "lines:n=800,alpha=1"),
        ("800, clipped", "lines:n=800,clip=1"),
        ("800, turned canvas", "lines:n=800,rot=1"),
        ("800 in 40 calls", "lines:n=800,calls=40"),
        ("800 in 200 calls", "lines:n=800,calls=200"),
        ("polyline, 800 points", "lines:way=polygon,n=800"),
        ("polyline, 3000 points", "lines:way=polygon,n=3000"),
    ],
    "fallbacks": [
        ("800 hairlines (width 0)", "lines:n=800,w=0"),
        ("100 blurred lines", "lines:n=100,fx=blur"),
        ("200 lines, overlay blend", "lines:n=200,fx=overlay"),
        ("800 lines, color filter", "lines:n=800,fx=filter"),
    ],
    "controls": [
        ("empty frame", "lines:way=empty"),
        ("800 drawLine calls", "lines:way=drawline,n=800"),
        ("800 as one drawVertices", "lines:way=vertices,n=800"),
    ],
    "ways": [
        ("empty frame", "lines:way=empty"),
        ("800 drawLine calls", "lines:way=drawline,n=800"),
        ("800 in one drawRawPoints", "lines:n=800"),
        ("800 as one stroked path", "lines:way=path,n=800"),
        ("800 as one drawVertices", "lines:way=vertices,n=800"),
    ],
}
SETS["all"] = SETS["scenes"] + SETS["lines"] + SETS["fallbacks"] + SETS["controls"]


class RunError(Exception):
    pass


def adb(serial: str, *args: str, check: bool = True, timeout: float = 120) -> str:
    done = subprocess.run(
        ["adb", "-s", serial, *args], capture_output=True, text=True, timeout=timeout
    )
    if check and done.returncode != 0:
        raise RunError(f"adb {' '.join(args)}\n{done.stdout}{done.stderr}")
    return done.stdout.strip()


def pick_device(wanted: str | None) -> str:
    listed = subprocess.run(["adb", "devices"], capture_output=True, text=True).stdout
    ready = [line.split()[0] for line in listed.splitlines()[1:] if line.endswith("\tdevice")]
    if wanted:
        if wanted not in ready:
            sys.exit(f"{wanted} is not connected over adb (connected: {', '.join(ready) or 'none'}).")
        return wanted
    if len(ready) != 1:
        sys.exit(f"Connect one phone or pass --device (connected: {', '.join(ready) or 'none'}).")
    return ready[0]


class KeepAwake:
    """Keeps the screen on for the run, then puts the phone's setting back."""

    def __init__(self, serial: str) -> None:
        self.serial = serial
        self.previous = "0"

    def __enter__(self) -> "KeepAwake":
        value = adb(self.serial, "shell", "settings", "get", "global", "stay_on_while_plugged_in")
        self.previous = value if value.isdigit() else "0"
        adb(self.serial, "shell", "settings", "put", "global", "stay_on_while_plugged_in", "7")
        adb(self.serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
        adb(self.serial, "shell", "wm", "dismiss-keyguard", check=False)
        time.sleep(1.5)
        state = adb(self.serial, "shell", "dumpsys", "window", check=False)
        if "isKeyguardShowing=true" in state or "mShowingLockscreen=true" in state:
            self.__exit__()
            raise RunError("The phone is locked. Unlock it and run again.")
        return self

    def __exit__(self, *_: object) -> None:
        adb(
            self.serial, "shell", "settings", "put", "global",
            "stay_on_while_plugged_in", self.previous, check=False,
        )


def phone(serial: str) -> dict:
    def prop(name: str) -> str:
        return adb(serial, "shell", "getprop", name, check=False)

    battery = adb(serial, "shell", "dumpsys", "battery", check=False)
    heat = re.search(r"temperature: (\d+)", battery)
    return {
        "model": f"{prop('ro.product.manufacturer')} {prop('ro.product.model')}".strip(),
        "android": prop("ro.build.version.release"),
        "chip": prop("ro.soc.model") or prop("ro.board.platform"),
        "batteryC": int(heat.group(1)) / 10 if heat else None,
    }


def simpleperf() -> Path:
    roots = [os.environ.get("ANDROID_NDK_HOME"), os.environ.get("ANDROID_NDK_ROOT")]
    for sdk in (
        os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
        Path.home() / "Library/Android/sdk", Path.home() / "Android/Sdk",
    ):
        if sdk and (Path(sdk) / "ndk").is_dir():
            roots += sorted((Path(sdk) / "ndk").iterdir(), reverse=True)
    for root in roots:
        if root:
            found = Path(root) / "simpleperf/bin/android/arm64/simpleperf"
            if found.exists():
                return found
    sys.exit("No simpleperf: install an Android NDK or set ANDROID_NDK_HOME.")


def scenarios(text: str) -> list[tuple[str, str]]:
    # Sets are separated by commas. A scenario has commas of its own, so
    # scenarios are separated by `|`.
    parts = text.split("|") if "|" in text else [text] if ":" in text else text.split(",")
    found: list[tuple[str, str]] = []
    for part in parts:
        if part in SETS:
            found += SETS[part]
        elif part:
            found.append((part, part))
    return found


def build(flutter: str, engine: str, suffix: str | None, out: Path | None) -> Path:
    print(f"Building the profile APK{' as .' + suffix if suffix else ''}...", flush=True)
    made = subprocess.run(
        [
            flutter, "build", "apk", "--profile", "--target-platform", "android-arm64",
            *([f"--android-project-arg=benchSuffix={suffix}"] if suffix else []),
            *engine.split(),
        ],
        cwd=ROOT, capture_output=True, text=True,
    )
    apk = ROOT / "build/app/outputs/flutter-apk/app-profile.apk"
    if made.returncode != 0 or not apk.exists():
        sys.exit(f"The build failed:\n{made.stdout[-3000:]}\n{made.stderr[-3000:]}")
    if out:
        shutil.copy(apk, out)
        return out
    return apk


def flutter_version(flutter: str) -> dict:
    out = subprocess.run(
        [flutter, "--version", "--machine"], capture_output=True, text=True, cwd=ROOT
    ).stdout
    try:
        found = json.loads(out[out.index("{"):])
        return {key: found.get(key) for key in ("frameworkVersion", "channel", "frameworkRevision", "engineRevision", "dartSdkVersion")}
    except ValueError:
        return {}


def app_id(apk: Path) -> str:
    """The APK's application id, read from its manifest with aapt2 or aapt."""
    for sdk in (
        os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
        Path.home() / "Library/Android/sdk", Path.home() / "Android/Sdk",
    ):
        if not sdk:
            continue
        for tool in sorted(Path(sdk).glob("build-tools/*/aapt2"), reverse=True):
            out = subprocess.run(
                [str(tool), "dump", "badging", str(apk)], capture_output=True, text=True
            ).stdout
            found = re.search(r"package: name='([^']+)'", out)
            if found:
                return found.group(1)
    sys.exit("Could not read the APK's app id: aapt2 from the Android SDK build-tools is needed.")


def install(serial: str, apk: Path) -> None:
    done = subprocess.run(
        ["adb", "-s", serial, "install", "-r", str(apk)], capture_output=True, text=True
    )
    if "Success" not in done.stdout:
        raise RunError(f"Install failed: {done.stdout} {done.stderr}")


def play(serial: str, app: str, route: str, timeout: float, extra: str = "", on_start=None) -> list[dict]:
    """Starts the app with a plan and collects its LINEBENCH log lines."""
    adb(serial, "shell", "am", "force-stop", app, check=False)
    adb(serial, "logcat", "-c", check=False)
    adb(
        serial, "shell", "am", "start", "-n", f"{app}/{NAMESPACE}.MainActivity",
        "--es", "route", f"'{route}'", *extra.split(),
    )
    lines: list[dict] = []
    seen: set[str] = set()
    started = time.time()
    told = False
    while time.time() - started < timeout:
        time.sleep(1)
        log = adb(serial, "logcat", "-d", "-s", "flutter:I", check=False)
        for raw in re.findall(r"LINEBENCH (\{.*\})", log):
            if raw not in seen:
                seen.add(raw)
                lines.append(json.loads(raw))
        if any(line["type"] == "start" and not line.get("widthPx") for line in lines):
            # A build from before the app waited for its view: it will not finish.
            raise RunError("The app started before its view had a size.")
        if on_start and not told and any(line["type"] == "start" for line in lines):
            told = True
            on_start()
        if any(line["type"] == "done" for line in lines):
            return lines
        if time.time() - started > 12:
            focus = adb(serial, "shell", "dumpsys", "window", check=False)
            front = [l for l in focus.splitlines() if "mCurrentFocus" in l or "mFocusedApp" in l]
            if not any(app in line for line in front):
                raise RunError("The bench is no longer in front (a notification, a crash, the lock screen?).")
    raise RunError("Timed out waiting for the bench.")


def count_threads(text: str, seconds: float, fps: float, app: str) -> dict:
    """Cycles and instructions per frame for the raster and the UI thread, out
    of `simpleperf stat --per-thread` (rows: thread, pid, tid, count, event)."""
    row: dict = {}
    for line in text.splitlines():
        found = re.match(r"\s*(\S.*?)\s+\d+\s+(\d+)\s+([\d,]+)\s+(cpu-cycles|instructions)\b", line)
        if not found or fps <= 0:
            continue
        thread, _tid, value, event = found.groups()
        # Android runs Dart on the app's main thread, which is named after the
        # app id; older engines had a thread named 1.ui.
        key = (
            "raster" if thread == "1.raster"
            else "ui" if thread.startswith("1.ui") or (len(thread) > 6 and thread in app)
            else None
        )
        if key:
            name = f"{key}{'Cycles' if event == 'cpu-cycles' else 'Instructions'}"
            row[name] = row.get(name, 0) + int(value.replace(",", "")) / seconds / fps
    return row


def one_launch(serial: str, app: str, spec: str, seconds: float, extra: str) -> dict:
    """One scenario in a launch of its own, with the counters read meanwhile."""
    text: dict = {}
    window = max(2.0, seconds - 1.5)

    def count() -> None:
        # The app draws its pixel hash and warms up for a second first.
        time.sleep(2.2)
        text["stat"] = adb(
            serial, "shell", DEVICE_SIMPLEPERF, "stat", "--app", app, "--per-thread",
            "-e", "cpu-cycles,instructions", "--duration", f"{window:g}",
            check=False, timeout=120,
        )

    lines = play(serial, app, f"/?s={spec}&seconds={seconds:g}&rounds=1", 60 + seconds, extra, count)
    step = next(line for line in lines if line["type"] == "step")
    step.update(count_threads(text.get("stat", ""), window, step["fps"], app))
    return step


def push_simpleperf(serial: str) -> None:
    adb(serial, "push", str(simpleperf()), DEVICE_SIMPLEPERF)
    adb(serial, "shell", "chmod", "a+x", DEVICE_SIMPLEPERF)


def summary(steps: list[dict]) -> dict:
    row: dict = {"rounds": len(steps), "segments": steps[0].get("segments") if steps else None}
    for key in (
        "fps", "rasterCpuMsPerFrame", "uiCpuMsPerFrame", "rasterP50", "uiP50",
        "rasterInstructions", "rasterCycles", "uiInstructions", "uiCycles",
    ):
        values = [s[key] for s in steps if s.get(key) is not None]
        if values:
            row[key] = statistics.median(values)
            row[key + "Range"] = [min(values), max(values)]
    row["hash"] = sorted({s.get("hash") for s in steps if s.get("hash")})
    return row


def number(row: dict, key: str, scale: float = 1.0) -> float:
    found = row.get(key)
    return float("nan") if found is None else found / scale


def run_single(serial: str, apk: Path, plan: list[tuple[str, str]], args) -> dict:
    app = app_id(apk)
    install(serial, apk)
    result: dict = {"app": app}
    try:
        route = f"/?s={'|'.join(spec for _, spec in plan)}&seconds={args.seconds:g}&rounds={args.rounds}"
        lines = play(
            serial, app, route, 60 + len(plan) * args.rounds * (args.seconds + 4.5), args.am_extra
        )
        result["start"] = next(l for l in lines if l["type"] == "start")
        by: dict[str, list[dict]] = {}
        for step in (l for l in lines if l["type"] == "step"):
            by.setdefault(step["spec"], []).append(step)
        counted: dict[str, list[dict]] = {}
        if args.counters:
            push_simpleperf(serial)
            for _ in range(args.counter_rounds):
                for _, spec in plan:
                    counted.setdefault(spec, []).append(
                        one_launch(serial, app, spec, 8, args.am_extra)
                    )
        result["scenarios"] = []
        print(
            f"\n{'scenario':26} {'lines':>5} {'fps':>5} {'low':>5}  {'raster CPU ms/frame':>22}  "
            f"{'UI CPU ms/frame':>20}" + ("  raster instr M  cycles M" if counted else "")
        )
        for label, spec in plan:
            row = summary(by.get(spec, []))
            extra = summary(counted[spec]) if spec in counted else {}
            result["scenarios"].append({"label": label, "spec": spec, "plan": row, "counted": extra})
            low, high = row.get("rasterCpuMsPerFrameRange", [float("nan")] * 2)
            ulow, uhigh = row.get("uiCpuMsPerFrameRange", [float("nan")] * 2)
            print(
                f"{label[:26]:26} {row.get('segments') or 0:>5} {number(row, 'fps'):5.1f} "
                f"{row.get('fpsRange', [float('nan')])[0]:5.1f}  "
                f"{number(row, 'rasterCpuMsPerFrame'):8.2f} ({low:5.2f}-{high:5.2f})  "
                f"{number(row, 'uiCpuMsPerFrame'):6.2f} ({ulow:5.2f}-{uhigh:5.2f})"
                + (
                    f"  {number(extra, 'rasterInstructions', 1e6):14.2f}  "
                    f"{number(extra, 'rasterCycles', 1e6):8.2f}"
                    if counted else ""
                )
            )
    finally:
        adb(serial, "shell", "am", "force-stop", app, check=False)
        adb(serial, "uninstall", app, check=False)
        adb(serial, "shell", "rm", "-f", DEVICE_SIMPLEPERF, check=False)
    return result


def run_pair(serial: str, apks: dict[str, Path], plan: list[tuple[str, str]], args) -> dict:
    ids = {name: app_id(apk) for name, apk in apks.items()}
    if len(set(ids.values())) < len(ids):
        raise RunError(f"The APKs share an app id ({ids}): build each with its own --suffix.")
    for apk in apks.values():
        install(serial, apk)
    push_simpleperf(serial)
    names = list(apks)
    steps: dict[str, dict[str, list[dict]]] = {spec: {n: [] for n in names} for _, spec in plan}
    result: dict = {"apps": ids}
    try:
        for round_index in range(args.rounds):
            for index, (label, spec) in enumerate(plan):
                # The engines in turn; which one goes first changes every time.
                order = names if (round_index + index) % 2 == 0 else names[::-1]
                for name in order:
                    for _ in range(3):
                        try:
                            steps[spec][name].append(
                                one_launch(serial, ids[name], spec, args.seconds, args.am_extra)
                            )
                            break
                        except RunError as error:
                            print(f"  {label} on {name}: {error} Trying again.", flush=True)
                            time.sleep(5)
                print(f"  round {round_index + 1}/{args.rounds}  {label}", flush=True)
    finally:
        for app in ids.values():
            adb(serial, "shell", "am", "force-stop", app, check=False)
            adb(serial, "uninstall", app, check=False)
        adb(serial, "shell", "rm", "-f", DEVICE_SIMPLEPERF, check=False)
    result["scenarios"] = [
        {
            "label": label, "spec": spec,
            **{name: summary(steps[spec][name]) for name in names if steps[spec][name]},
        }
        for label, spec in plan
    ]
    show_pair(result["scenarios"], names)
    return result


def show_pair(rows: list[dict], names: list[str]) -> None:
    a, b = names
    print(
        f"\n{'scenario':26} {'lines':>5}  {'raster instr M/frame':>22} {'change':>7}  "
        f"{'raster cycles M':>16} {'change':>7}  {'raster CPU ms':>14}  {'fps':>11}  pixels"
    )
    print(f"{'':26} {'':>5}  {a + ' > ' + b:>22}")
    for row in rows:
        def pair(key: str, scale: float, digits: int) -> tuple[str, str]:
            x, y = number(row.get(a, {}), key, scale), number(row.get(b, {}), key, scale)
            change = f"{(y - x) / x * 100:+.0f}%" if x == x and y == y and x else "n/a"
            return f"{x:.{digits}f} > {y:.{digits}f}", change

        instructions, d1 = pair("rasterInstructions", 1e6, 2)
        cycles, d2 = pair("rasterCycles", 1e6, 2)
        cpu, _ = pair("rasterCpuMsPerFrame", 1, 1)
        fps, _ = pair("fps", 1, 1)
        ha, hb = row.get(a, {}).get("hash", []), row.get(b, {}).get("hash", [])
        same = "same" if ha and ha == hb and len(ha) == 1 else f"DIFFER {ha} {hb}"
        print(
            f"{row['label'][:26]:26} {row.get(a, {}).get('segments') or 0:>5}  {instructions:>22} {d1:>7}  "
            f"{cycles:>16} {d2:>7}  {cpu:>14}  {fps:>11}  {same}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    def common(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--scenarios", default=None, help="sets, or scenarios separated by |")
        sub.add_argument("--seconds", type=float, default=None, help="how long a scenario is measured")
        sub.add_argument("--rounds", type=int, default=None)
        sub.add_argument("--device", default=None, help="an adb serial, when several phones are connected")
        sub.add_argument("--am-extra", default="", help='extra `am start` arguments, e.g. "--ez enable-impeller false"')
        sub.add_argument("--name", default=None, help="a name for the saved result")

    def builds(sub: argparse.ArgumentParser) -> None:
        sub.add_argument("--flutter", default="flutter", help="the flutter tool to build with")
        sub.add_argument("--engine", default="", help="--local-engine... arguments for an engine built from source")

    run = commands.add_parser("run", help="build one APK and play every scenario on it")
    common(run)
    builds(run)
    run.add_argument("--apk", default=None, help="an APK built earlier, instead of building")
    run.add_argument("--counters", action="store_true", help="also count cycles and instructions per frame")
    run.add_argument("--counter-rounds", type=int, default=3)

    make = commands.add_parser("build", help="build an APK, with an app id of its own if asked")
    builds(make)
    make.add_argument("--suffix", default=None, help="added to the app id, so two builds install side by side")
    make.add_argument("-o", "--out", default=None, help="copy the APK here")

    pair = commands.add_parser("pair", help="play two APKs against each other")
    common(pair)
    pair.add_argument("apks", nargs=2, metavar="NAME=APK")

    args = parser.parse_args()
    if args.command == "build":
        print(build(args.flutter, args.engine, args.suffix, Path(args.out) if args.out else None))
        return

    serial = pick_device(args.device)
    result: dict = {"phone": phone(serial)}
    if args.command == "pair":
        apks = {part.split("=", 1)[0]: Path(part.split("=", 1)[1]) for part in args.apks}
        plan = scenarios(args.scenarios or "all")
        args.seconds = args.seconds or 6
        args.rounds = args.rounds or 3
        name = args.name or "_vs_".join(apks)
    else:
        if args.apk:
            apk = Path(args.apk)
        else:
            apk = build(args.flutter, args.engine, None, None)
            result["flutter"] = flutter_version(args.flutter)
        plan = scenarios(args.scenarios or "ways")
        args.seconds = args.seconds or 4
        args.rounds = args.rounds or 5
        name = args.name or (result.get("flutter", {}).get("frameworkVersion") or apk.stem)
    try:
        with KeepAwake(serial):
            result.update(
                run_pair(serial, apks, plan, args) if args.command == "pair"
                else run_single(serial, apk, plan, args)
            )
    except RunError as error:
        sys.exit(str(error))
    result["phone"]["batteryCAfter"] = phone(serial)["batteryC"]
    result.update({
        "name": name, "seconds": args.seconds, "rounds": args.rounds, "amExtra": args.am_extra,
        "when": datetime.datetime.now().isoformat(timespec="seconds"),
    })
    out = ROOT / "results"
    out.mkdir(exist_ok=True)
    saved = out / f"{datetime.datetime.now():%Y-%m-%d_%H%M%S}_{re.sub(r'[^A-Za-z0-9._-]+', '_', name)}.json"
    saved.write_text(json.dumps(result, indent=1) + "\n")
    print(f"\nSaved: {saved.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
