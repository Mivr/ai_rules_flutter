#!/usr/bin/env python3
"""Toolchain floor chains for the mobile edit flows of the perf bench.

The replay floor (``sol.py``) re-runs the tool binaries Bazel ran, so it
contains whatever the rules decided to run. The toolchain floor is written
by hand against the SDK and platform tools directly, the way a person with
a resident compiler would do the same edit:

- debug edit (iOS simulator debug, Android debug): a resident
  ``frontend_server`` in incremental mode compiles the app once untimed,
  then recompiles after the body edit; the kernel blob is replaced inside
  the already built package in place; then the least re-signing the
  platform accepts (iOS: seal the changed bundle only, the unchanged
  frameworks keep their signatures; Android: re-sign once, no recompression
  and no realignment of unchanged entries). The timed cost is the
  recompile, the replace and the re-sign.
- release edit (iOS device release, Android release): the AOT kernel
  compile, one ``gen_snapshot``, the snapshot replaced inside the existing
  package, then the same minimum re-sign. Nothing else is timed.

Every tool path comes from the roots the bench workspace resolves (the
build's external repositories and the platform tool locations), never from
a host install; an unfindable tool is named in the error. This module only
builds the chain (pure data); ``floor_run.py`` executes it and
``floor_check.py`` checks the replaced package.
"""

import dataclasses
import os

FLOOR_CONFIGS = ("sim_debug", "device_release", "android_debug",
                 "android_release")
_DEBUG_PASS = "floorpass"


class FloorError(RuntimeError):
    """The floor cannot run or its package failed the check."""


class MissingToolError(FloorError):
    """A tool the chain needs is not under any resolved root."""


@dataclasses.dataclass(frozen=True)
class FloorSpec:
    """What one floor chain works on.

    platform is ``ios`` or ``android``, mode ``debug`` or ``release``.
    package is the built ``.app``/``App.framework`` directory or the APK
    (a copy in scratch, never Bazel's output); entry is the root library
    URI, packages the package_config.json, scratch a writable directory.
    """

    platform: str
    mode: str
    package: str
    entry: str
    packages: str
    scratch: str


@dataclasses.dataclass(frozen=True)
class Step:
    """One chain step.

    kind is ``exec`` (a tool run to completion), ``frontend`` (the
    resident incremental compile: ``compile`` untimed, ``recompile``
    timed) or ``replace`` (the in-place payload replacement, ``call``
    names which one). timed steps add to the floor number.
    """

    name: str
    kind: str
    argv: tuple = ()
    timed: bool = True
    detail: tuple = ()


def find_tool(name, roots, hint=None):
    """Path of the tool whose path ends with ``name`` under the roots.

    ``name`` may be a path suffix (``flutter_patched_sdk/platform_strong.dill``).
    A ``hint`` substring prefers matching paths. Raises MissingToolError
    naming the tool and the roots searched.
    """
    suffix = os.sep + name
    found = []
    for root in roots:
        for dirpath, _, filenames in os.walk(root):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                if path.endswith(suffix):
                    found.append(path)
    if hint:
        preferred = [path for path in found if hint in path]
        found = preferred or found
    if not found:
        raise MissingToolError("floor tool %r not found under %s"
                               % (name, ", ".join(roots) or "(no roots)"))
    return sorted(found)[0]


def _tool_names(spec):
    """(name, hint) pairs the chain of this spec needs, by tool key."""
    sdk = ("flutter_patched_sdk_product" if spec.mode == "release"
           else "flutter_patched_sdk")
    names = {"dartaotruntime": ("dartaotruntime", None),
             "frontend": ("frontend_server_aot.dart.snapshot", None),
             "platform": (sdk + "/platform_strong.dill", None)}
    if spec.mode == "release":
        arch = "ios" if spec.platform == "ios" else "android-arm64"
        names["gen_snapshot"] = ("gen_snapshot", arch + "-release")
    if spec.platform == "ios":
        names["codesign"] = ("codesign", None)
    else:
        names["apksigner"] = ("apksigner", None)
        names["zipalign"] = ("zipalign", None)
        names["keytool"] = ("keytool", None)
    return names


def resolve_tools(spec, roots):
    """{tool key: path} for the spec; the first missing tool raises."""
    return {key: find_tool(name, roots, hint)
            for key, (name, hint) in _tool_names(spec).items()}


def frontend_argv(spec, tools, output, incremental):
    """The frontend_server command line (debug: resident incremental)."""
    sdk_root = os.path.dirname(tools["platform"]) + os.sep
    argv = [tools["dartaotruntime"], tools["frontend"],
            "--sdk-root", sdk_root, "--platform", tools["platform"],
            "--target=flutter", "--packages", spec.packages,
            "--output-dill", output]
    if incremental:
        argv += ["--incremental", "--track-widget-creation",
                 "--enable-asserts"]
    else:
        argv += ["--aot", "--tfa", "-Ddart.vm.product=true", spec.entry]
    return tuple(argv)


def sign_steps(spec, tools):
    """The minimum re-sign steps for the platform (timed).

    iOS seals the changed bundle only: no ``--deep``, so nested frameworks
    keep their signatures. Android signs the package once with the v2
    scheme only: no v1 entries are added, no entry is recompressed or
    realigned.
    """
    if spec.platform == "ios":
        argv = (tools["codesign"], "--force", "--sign", "-",
                "--preserve-metadata=identifier,entitlements,flags",
                spec.package)
        return [Step("resign", "exec", argv)]
    keystore = os.path.join(spec.scratch, "floor.keystore")
    pass_arg = "pass:" + _DEBUG_PASS
    keygen = (tools["keytool"], "-genkeypair", "-keystore", keystore,
              "-storepass", _DEBUG_PASS, "-keypass", _DEBUG_PASS,
              "-alias", "floor", "-keyalg", "RSA", "-keysize", "2048",
              "-validity", "3650", "-dname", "CN=floor")
    sign = (tools["apksigner"], "sign", "--ks", keystore,
            "--ks-pass", pass_arg, "--key-pass", pass_arg,
            "--v1-signing-enabled", "false",
            "--v2-signing-enabled", "true", spec.package)
    return [Step("keygen", "exec", keygen, timed=False),
            Step("resign", "exec", sign)]


def payload_name(spec):
    """Package entry/file the replace step swaps (None: found at run time)."""
    if spec.mode == "debug":
        return "kernel_blob.bin"
    return "libapp.so" if spec.platform == "android" else "App"


def build_chain(spec, tools):
    """Ordered Steps of the floor chain for one mobile edit flow."""
    out = os.path.join(spec.scratch, "app.dill")
    if spec.mode == "debug":
        argv = frontend_argv(spec, tools, out, incremental=True)
        front = [Step("frontend-compile", "frontend", argv, timed=False,
                      detail=("compile", spec.entry)),
                 Step("frontend-recompile", "frontend", argv,
                      detail=("recompile", spec.entry))]
        source = out
    else:
        argv = frontend_argv(spec, tools, out, incremental=False)
        snapshot = os.path.join(spec.scratch, payload_name(spec))
        front = [Step("aot-kernel", "exec", argv),
                 Step("gen_snapshot", "exec",
                      gen_snapshot_argv(spec, tools, out, snapshot))]
        source = snapshot
    replace = Step("replace", "replace", (), detail=(
        source, payload_name(spec)))
    sign = sign_steps(spec, tools)
    return [step for step in sign if not step.timed] + front + [
        replace] + [step for step in sign if step.timed]


def gen_snapshot_argv(spec, tools, kernel, snapshot):
    """The single gen_snapshot invocation of a release chain."""
    if spec.platform == "ios":
        kind = ("--snapshot_kind=app-aot-macho-dylib",
                "--macho=" + snapshot)
    else:
        kind = ("--snapshot_kind=app-aot-elf", "--elf=" + snapshot)
    return (tools["gen_snapshot"], "--deterministic") + kind + (kernel,)
