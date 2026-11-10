"""Glue between the sol driver and the toolchain floor (see floor.py).

``snapshot_sources`` runs before a flow's edit is applied and
``floor_fields`` after the flow's replay chain has restored Bazel's
outputs. A floor failure only sets that flow's floor fields: it never
touches ``sol`` and never fails the replay chain.
"""

import os
import shutil
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from floor import FLOOR_CONFIGS  # noqa: E402
from floor import FloorError  # noqa: E402
from floor import FloorSpec  # noqa: E402
from floor import find_tool  # noqa: E402
from floor_run import run_floor  # noqa: E402
from floor_sources import SourceSwap  # noqa: E402
from run_rep import make_writable_tree  # noqa: E402

_PLATFORM = {"sim_debug": ("ios", "debug"),
             "device_release": ("ios", "release"),
             "android_debug": ("android", "debug"),
             "android_release": ("android", "release")}
FLOOR_KEYS = ("toolchain_floor", "floor_identical", "floor_reason")


def floor_enabled(args, config, scenario):
    """True for a mobile edit flow while ``--floor`` is not ``off``."""
    return (getattr(args, "floor", "on") != "off"
            and config in FLOOR_CONFIGS and scenario != "clean")


def snapshot_sources(args, config, scenario):
    """Pre-edit Dart sources for the flow (None when no floor runs)."""
    if not floor_enabled(args, config, scenario):
        return None
    return SourceSwap.snapshot(args.work)


def _extract_ipa(ipa, dest):
    """The .app directory inside an .ipa, modes kept."""
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            path = archive.extract(info, dest)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(path, mode)
    payload = os.path.join(dest, "Payload")
    apps = [n for n in os.listdir(payload) if n.endswith(".app")]
    if not apps:
        raise FloorError("ipa %s has no .app bundle" % ipa)
    return os.path.join(payload, sorted(apps)[0])


def copy_package(plan, scratch):
    """A writable copy of the built package, never Bazel's output."""
    kind = plan[0]
    if kind == "files":
        source = os.path.dirname(plan[1][0])
    elif kind == "archives":
        apks = [p for p in plan[1] if p.endswith(".apk")]
        if not apks:
            raise FloorError("flow declares no .apk to replace in")
        dest = os.path.join(scratch, "app.apk")
        shutil.copyfile(apks[0], dest)
        os.chmod(dest, 0o644)
        return dest
    elif plan[2]:
        source = plan[2][0]
    else:
        return _extract_ipa(plan[1][0], scratch)
    dest = os.path.join(scratch, os.path.basename(source))
    shutil.copytree(source, dest, symlinks=True)
    make_writable_tree(dest)
    return dest


def apple_roots(find=subprocess.run):
    """Directory of the Xcode ``codesign`` (``xcrun --find``), or []."""
    try:
        proc = find(["xcrun", "--find", "codesign"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True, check=False)
    except OSError:
        return []
    path = (proc.stdout or "").strip()
    return [os.path.dirname(path)] if proc.returncode == 0 and path else []


def build_spec(config, built, work, scratch):
    """The FloorSpec for a flow from its build's declared outputs."""
    platform, mode = _PLATFORM[config]
    packages = find_tool("package_config.json", [built.bazel_out],
                         hint="app")
    entry = "file://" + os.path.join(os.path.abspath(work), "app", "lib",
                                     "main.dart")
    return FloorSpec(platform, mode, copy_package(built.plan, scratch),
                     entry, packages, scratch)


def floor_fields(args, config, scenario, built, swap, runner=run_floor):
    """The floor keys of one flow record ({} when no floor runs)."""
    if swap is None:
        return {}
    scratch = args.work + "-floor-%s-%s" % (config, scenario)
    shutil.rmtree(scratch, ignore_errors=True)
    os.makedirs(scratch)
    try:
        spec = build_spec(config, built, args.work, scratch)
        roots = [os.path.join(built.execroot, "external")]
        roots += apple_roots() if spec.platform == "ios" else []
        result = runner(spec, roots, swap)
        floor = None
        if result.identical:
            floor = {"cpu_s": result.cpu_s, "real_s": result.real_s,
                     "steps": result.steps}
        return {"toolchain_floor": floor,
                "floor_identical": result.identical,
                "floor_reason": result.reason}
    except (FloorError, OSError, ValueError) as exc:
        return {"toolchain_floor": None, "floor_identical": False,
                "floor_reason": "floor: %s" % exc}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
