#!/usr/bin/env python3
"""Unit tests for the toolchain floor (fake tools, runners and servers)."""

import argparse
import io
import os
import plistlib
import struct
import sys
import tempfile
import threading
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import floor
import floor_apk
import floor_check
import floor_flow
import floor_run
import floor_sources
import floor_summary
import sol
import sol_summary


def touch(path, data=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def fake_sdk(root):
    """A fake SDK and platform tool directory."""
    for rel in (
            "sdk/dart-sdk/bin/dartaotruntime",
            "sdk/engine/frontend_server_aot.dart.snapshot",
            "sdk/engine/flutter_patched_sdk/platform_strong.dill",
            "sdk/engine/flutter_patched_sdk_product/platform_strong.dill",
            "sdk/engine/ios-release/gen_snapshot",
            "sdk/engine/android-arm64-release/gen_snapshot",
            "plat/codesign", "plat/apksigner", "plat/zipalign",
            "plat/keytool"):
        touch(os.path.join(root, rel))
    return [os.path.join(root, "sdk"), os.path.join(root, "plat")]


def make_spec(platform, mode, scratch, package="/pkg"):
    return floor.FloorSpec(platform, mode, package, "file:///app/main.dart",
                           "/pc.json", scratch)


class ChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.roots = fake_sdk(self.tmp)

    def chain(self, platform, mode):
        spec = make_spec(platform, mode, self.tmp)
        return floor.build_chain(spec, floor.resolve_tools(spec, self.roots))

    def test_debug_chains_start_a_resident_incremental_compile(self):
        for platform in ("ios", "android"):
            chain = self.chain(platform, "debug")
            frontend = [s for s in chain if s.kind == "frontend"]
            self.assertEqual(["compile", "recompile"],
                             [s.detail[0] for s in frontend])
            self.assertFalse(frontend[0].timed)
            self.assertIn("--incremental", frontend[0].argv)
            self.assertTrue(frontend[0].argv[0].startswith(self.tmp))
            self.assertEqual(0, sum(s.name == "gen_snapshot"
                                    for s in chain))

    def test_release_chains_run_exactly_one_gen_snapshot(self):
        for platform in ("ios", "android"):
            chain = self.chain(platform, "release")
            snaps = [s for s in chain if s.name == "gen_snapshot"]
            self.assertEqual(1, len(snaps))
            self.assertEqual("gen_snapshot",
                             os.path.basename(snaps[0].argv[0]))
            self.assertIn(
                "ios" if platform == "ios" else "android-arm64",
                snaps[0].argv[0])
            self.assertEqual([], [s for s in chain
                                  if s.kind == "frontend"])

    def test_resign_is_minimal(self):
        ios = self.chain("ios", "debug")[-1].argv
        self.assertNotIn("--deep", ios)
        android = self.chain("android", "debug")[-1].argv
        self.assertIn("--v1-signing-enabled", android)
        self.assertEqual("false",
                         android[android.index("--v1-signing-enabled") + 1])

    def test_missing_tool_names_itself(self):
        os.remove(os.path.join(self.tmp, "plat", "apksigner"))
        spec = make_spec("android", "debug", self.tmp)
        with self.assertRaises(floor.MissingToolError) as ctx:
            floor.resolve_tools(spec, self.roots)
        self.assertIn("apksigner", str(ctx.exception))

    def test_tools_come_from_roots_only(self):
        spec = make_spec("ios", "debug", self.tmp)
        with self.assertRaises(floor.MissingToolError):
            floor.resolve_tools(spec, [os.path.join(self.tmp, "empty")])


class SymlinkLayoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.real = os.path.join(self.tmp, "output_base", "external")
        self.root = os.path.join(self.tmp, "execroot", "external")
        os.makedirs(self.root)

    def link_repo(self, name, files):
        for rel in files:
            touch(os.path.join(self.real, name, rel))
        os.symlink(os.path.join(self.real, name),
                   os.path.join(self.root, name))

    def test_tool_behind_symlinked_directory(self):
        self.link_repo("sdk", ["dart-sdk/bin/dartaotruntime"])
        found = floor.find_tool("dartaotruntime", [self.root])
        self.assertEqual(found, os.path.join(self.root, "sdk",
                                             "dart-sdk/bin/dartaotruntime"))

    def test_package_config_behind_symlink(self):
        self.link_repo("pk", ["x/app.package_config.json"])
        self.assertTrue(floor.find_package_config([self.root], "app")
                        .endswith("app.package_config.json"))

    def test_symlink_loop_ends(self):
        self.link_repo("sdk", ["bin/dartaotruntime"])
        os.symlink(self.root, os.path.join(self.real, "sdk", "up"))
        os.symlink(os.path.join(self.real, "sdk"),
                   os.path.join(self.real, "sdk", "self"))
        done = []
        thread = threading.Thread(target=lambda: done.append(
            floor.find_tool("dartaotruntime", [self.root])), daemon=True)
        thread.start()
        thread.join(20)
        self.assertFalse(thread.is_alive(), "search did not end")
        self.assertTrue(done[0].endswith("dartaotruntime"))
        with self.assertRaises(floor.MissingToolError):
            floor.find_tool("nothere", [self.root])

    def test_dangling_symlink_skipped(self):
        os.symlink(os.path.join(self.tmp, "nowhere"),
                   os.path.join(self.root, "dead"))
        os.symlink(os.path.join(self.tmp, "nowhere"),
                   os.path.join(self.root, "dartaotruntime"))
        with self.assertRaises(floor.MissingToolError) as ctx:
            floor.find_tool("dartaotruntime", [self.root])
        self.assertIn("dartaotruntime", str(ctx.exception))
        self.assertIn(self.root, str(ctx.exception))

    def test_android_specs_resolve(self):
        fake_sdk(os.path.join(self.tmp, "src"))
        for name, rel in (("sdk", "sdk"), ("plat", "plat")):
            src = os.path.join(self.tmp, "src", rel)
            os.symlink(src, os.path.join(self.root, name))
        for mode in ("debug", "release"):
            spec = make_spec("android", mode, self.tmp)
            tools = floor.resolve_tools(spec, [self.root])
            self.assertEqual(set(tools), set(floor._tool_names(spec)))
            for path in tools.values():
                self.assertTrue(os.path.isfile(path))


def make_apk(path, with_manifest=True, payload="assets/flutter_assets/kernel_blob.bin"):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        if with_manifest:
            archive.writestr("AndroidManifest.xml", "<manifest/>")
        if payload:
            archive.writestr(payload, b"old" * 100)
        archive.writestr("classes.dex", b"dex" * 50)


def make_app(path, executable=True, plist=True):
    os.makedirs(path)
    if plist:
        with open(os.path.join(path, "Info.plist"), "wb") as fh:
            plistlib.dump({"CFBundleExecutable": "Runner"}, fh)
    if executable:
        touch(os.path.join(path, "Runner"))


def ok_runner(argv):
    return (0, "")


def bad_runner(argv):
    return (1, "boom")


TOOLS = {"codesign": "codesign", "apksigner": "apksigner",
         "zipalign": "zipalign"}


class CheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_good_packages_pass(self):
        app = os.path.join(self.tmp, "A.app")
        make_app(app)
        self.assertEqual((True, "ok"), floor_check.check_package(
            make_spec("ios", "debug", self.tmp, app), TOOLS, ok_runner))
        apk = os.path.join(self.tmp, "a.apk")
        make_apk(apk)
        self.assertEqual((True, "ok"), floor_check.check_package(
            make_spec("android", "debug", self.tmp, apk), TOOLS, ok_runner))

    def test_ios_failures(self):
        app = os.path.join(self.tmp, "A.app")
        make_app(app, executable=False)
        spec = make_spec("ios", "debug", self.tmp, app)
        ok, reason = floor_check.check_package(spec, TOOLS, bad_runner)
        self.assertFalse(ok)
        self.assertIn("codesign", reason)
        self.assertIn("executable", reason)
        bare = os.path.join(self.tmp, "B.app")
        make_app(bare, plist=False)
        ok, reason = floor_check.check_package(
            make_spec("ios", "debug", self.tmp, bare), TOOLS, ok_runner)
        self.assertEqual((False, "Info.plist missing"), (ok, reason))

    def test_android_failures(self):
        apk = os.path.join(self.tmp, "a.apk")
        make_apk(apk, with_manifest=False, payload=None)
        ok, reason = floor_check.check_package(
            make_spec("android", "release", self.tmp, apk), TOOLS,
            bad_runner)
        self.assertFalse(ok)
        for text in ("apksigner", "zipalign", "AndroidManifest.xml",
                     "payload"):
            self.assertIn(text, reason)


class ApkTest(unittest.TestCase):
    def test_replace_keeps_other_entries_byte_identical_and_aligned(self):
        path = os.path.join(tempfile.mkdtemp(), "a.apk")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", "<manifest/>",
                             zipfile.ZIP_DEFLATED)
            archive.writestr("lib/arm64-v8a/libapp.so", b"old" * 1000)
            archive.writestr("classes.dex", b"dex" * 50,
                             zipfile.ZIP_DEFLATED)
        with zipfile.ZipFile(path) as archive:
            before = {i.filename: archive.read(i) for i in archive.infolist()}
        new = b"newer-payload" * 5000
        floor_apk.replace_entry(path, "lib/arm64-v8a/libapp.so", new)
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(new, archive.read("lib/arm64-v8a/libapp.so"))
            self.assertEqual(before["classes.dex"],
                             archive.read("classes.dex"))
            self.assertEqual(3, len(archive.infolist()))
            info = archive.getinfo("lib/arm64-v8a/libapp.so")
            with open(path, "rb") as fh:
                fh.seek(info.header_offset + 26)
                nlen, elen = struct.unpack("<HH", fh.read(4))
            data_start = info.header_offset + 30 + nlen + elen
            self.assertEqual(0, data_start % floor_apk.PAGE)

    def test_missing_entry_raises(self):
        path = os.path.join(tempfile.mkdtemp(), "a.apk")
        make_apk(path)
        with self.assertRaises(KeyError):
            floor_apk.replace_entry(path, "nope", b"x")


class FakeServer:
    instances = []

    def __init__(self, argv):
        self.argv = argv
        self.calls = []
        self.proc = type("P", (), {"poll": lambda s: 0})()
        FakeServer.instances.append(self)

    def compile(self, entry):
        self.calls.append(("compile", entry))

    def recompile(self, entry, invalidated):
        self.calls.append(("recompile", entry, tuple(invalidated)))

    def quit(self):
        return 0.5


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.roots = fake_sdk(self.tmp)
        FakeServer.instances = []
        self.src = os.path.join(self.tmp, "main.dart")
        touch(self.src, b"old")
        self.swap = floor_sources.SourceSwap.snapshot(self.tmp)
        touch(self.src, b"new")

    def runner(self, argv):
        if "gen_snapshot" in argv[0]:
            touch(os.path.join(self.tmp, "libapp.so"), b"snap")
        return (0, 0.25, "")

    def apk_spec(self, mode):
        apk = os.path.join(self.tmp, "a.apk")
        make_apk(apk, payload="assets/flutter_assets/kernel_blob.bin"
                 if mode == "debug" else "lib/arm64-v8a/libapp.so")
        return floor.FloorSpec("android", mode, apk, "file:///m.dart",
                               "/pc", self.tmp)

    def test_debug_floor_sums_timed_steps_and_restores_sources(self):
        spec = self.apk_spec("debug")
        touch(os.path.join(self.tmp, "app.dill"), b"kernel")

        def checked(argv):
            return (0, 0.25, "")
        result = floor_run.run_floor(spec, self.roots, self.swap, checked,
                                     FakeServer)
        self.assertEqual("ok", result.reason, result.reason)
        self.assertTrue(result.identical)
        self.assertAlmostEqual(0.5 + 0.25, result.cpu_s, delta=0.05)
        self.assertEqual("compile", FakeServer.instances[0].calls[0][0])
        with open(self.src, "rb") as fh:
            self.assertEqual(b"new", fh.read())

    def test_failed_check_has_no_number(self):
        spec = self.apk_spec("debug")
        touch(os.path.join(self.tmp, "app.dill"), b"kernel")

        def runner(argv):
            return (1 if "zipalign" in argv[0] else 0, 0.1, "misaligned")
        result = floor_run.run_floor(spec, self.roots, self.swap, runner,
                                     FakeServer)
        self.assertFalse(result.identical)
        self.assertIsNone(result.cpu_s)
        self.assertIn("zipalign", result.reason)

    def test_missing_tool_is_a_reason(self):
        spec = self.apk_spec("release")
        result = floor_run.run_floor(spec, [os.path.join(self.tmp, "x")],
                                     self.swap, self.runner, FakeServer)
        self.assertFalse(result.identical)
        self.assertIn("dartaotruntime", result.reason)

    def test_release_floor_replaces_snapshot(self):
        spec = self.apk_spec("release")
        result = floor_run.run_floor(spec, self.roots, self.swap,
                                     self.runner, FakeServer)
        self.assertTrue(result.identical, result.reason)
        with zipfile.ZipFile(spec.package) as archive:
            self.assertEqual(b"snap", archive.read("lib/arm64-v8a/libapp.so"))
        self.assertEqual([], FakeServer.instances)


class FrontendTest(unittest.TestCase):
    def test_protocol(self):
        class Proc:
            pid = 1
            stdin = io.StringIO()
            stdout = iter(["result K1\n", "K1 out.dill 0\n"])
        written = []
        Proc.stdin.write = written.append
        Proc.stdin.flush = lambda: None
        server = floor_run.FrontendServer(
            ["fe"], popen=lambda *a, **k: Proc())
        orig = floor_run.process_cpu
        floor_run.process_cpu = lambda pid: 1.0
        try:
            server.compile("file:///m.dart")
        finally:
            server.errlog.close()
            floor_run.process_cpu = orig
        self.assertEqual("compile file:///m.dart\n", written[0])
        self.assertEqual("accept\n", written[1])
        self.assertEqual(1.0, server.baseline)


class FrontendDiagTest(unittest.TestCase):
    def server(self, lines, stderr=""):
        class Proc:
            pid = 1
            stdin = io.StringIO()
            stdout = iter(lines)
            returncode = None
        Proc.stdin.write = lambda text: None
        Proc.stdin.flush = lambda: None

        def popen(*args, **kwargs):
            kwargs["stderr"].write(stderr)
            return Proc()
        return floor_run.FrontendServer(["fe"], popen=popen)

    def failure(self, lines, stderr=""):
        server = self.server(lines, stderr)
        try:
            with self.assertRaises(floor.FloorError) as ctx:
                server._checked()
            return str(ctx.exception)
        finally:
            server.errlog.close()

    def test_fields_and_diagnostics(self):
        msg = self.failure(["result K\n", "bad one\n", "bad two\n",
                            "K out.dill 2\n"])
        for want in ("bad one", "bad two", "out.dill 2"):
            self.assertIn(want, msg)

    def test_no_output_file(self):
        msg = self.failure(["result K\n", "oops\n", "K\n"])
        self.assertIn("no output file", msg)
        self.assertIn("oops", msg)

    def test_pre_result_lines_kept(self):
        msg = self.failure(["warn one\n", "result K\n", "K\n"])
        self.assertIn("warn one", msg)
        self.assertIn("no output file", msg)
        self.assertIn("before result:", msg)

    def test_no_diagnostics_and_no_stderr(self):
        msg = self.failure(["result K\n", "K\n"])
        self.assertTrue(
            msg.endswith("the server printed no diagnostics and no stderr"))

    def test_many_pre_result_bounded(self):
        lines = (["pre%03d %s\n" % (i, "x" * 60) for i in range(100)]
                 + ["result K\n", "K\n"])
        msg = self.failure(lines)
        self.assertIn("pre000", msg)
        self.assertNotIn("pre030", msg)
        self.assertLess(len(msg), 4000)
        self.assertIn("no output file", msg)

    def test_stderr_tail_is_last_20(self):
        err = "".join("err%d\n" % i for i in range(50))
        msg = self.failure(["result K\n", "K\n"], err)
        self.assertIn("err49", msg)
        self.assertIn("err30", msg)
        self.assertNotIn("err29\n", msg + "\n")

    def test_many_diagnostics_bounded(self):
        lines = ["result K\n"] + ["diag%03d %s\n" % (i, "x" * 60)
                                  for i in range(100)] + ["K out.dill 7\n"]
        msg = self.failure(lines)
        self.assertIn("diag000", msg)
        self.assertNotIn("diag030", msg)
        self.assertLess(len(msg), 4000)
        self.assertIn("out.dill 7", msg)

    def test_ended_without_result(self):
        msg = self.failure(["noise\n"], "boom\nlast\n")
        self.assertIn("without a result", msg)
        self.assertIn("last", msg)

    def test_ended_without_result_keeps_pre_result(self):
        msg = self.failure(["orphan prelude\n"])
        self.assertIn("orphan prelude", msg)
        self.assertIn("without a result", msg)

    def test_passing_compile_unchanged(self):
        server = self.server(["result K\n", "K out.dill 0\n"])
        try:
            server._checked()
        finally:
            server.errlog.close()


class FlowTest(unittest.TestCase):
    def args(self, **extra):
        base = dict(work=tempfile.mkdtemp(), floor="on")
        base.update(extra)
        return argparse.Namespace(**base)

    def test_floor_off_gives_base_output(self):
        args = self.args(floor="off")
        self.assertIsNone(floor_flow.snapshot_sources(
            args, "sim_debug", "core_edit"))
        self.assertEqual({}, floor_flow.floor_fields(
            args, "sim_debug", "core_edit", None, None))

    def test_only_mobile_edit_flows(self):
        args = self.args()
        self.assertIsNone(floor_flow.snapshot_sources(
            args, "web_debug", "core_edit"))
        self.assertIsNone(floor_flow.snapshot_sources(
            args, "sim_debug", "clean"))
        self.assertIsNotNone(floor_flow.snapshot_sources(
            args, "android_debug", "app_edit"))

    def test_failure_sets_reason_only(self):
        args = self.args()
        built = argparse.Namespace(bazel_out="/nonexistent", plan=None,
                                   execroot="/nonexistent")
        fields = floor_flow.floor_fields(
            args, "android_debug", "core_edit", built,
            floor_sources.SourceSwap({}))
        self.assertFalse(fields["floor_identical"])
        self.assertIsNone(fields["toolchain_floor"])
        self.assertNotEqual("ok", fields["floor_reason"])

    def test_success_fields(self):
        args = self.args()
        tmp = tempfile.mkdtemp()
        pc = os.path.join(tmp, "bin", "app", "app.package_config.json")
        touch(pc, b"{}")
        apk = os.path.join(tmp, "x.apk")
        make_apk(apk)
        built = argparse.Namespace(
            bazel_out=tmp, execroot=tmp,
            plan=("archives", [apk], tmp))
        result = floor_run.FloorResult(1.5, 2.0, True, "ok", {"a": 1.5})
        fields = floor_flow.floor_fields(
            args, "android_debug", "core_edit", built,
            floor_sources.SourceSwap({}),
            runner=lambda spec, roots, swap: result)
        self.assertEqual(1.5, fields["toolchain_floor"]["cpu_s"])
        self.assertTrue(fields["floor_identical"])

    def built(self, tmp):
        return argparse.Namespace(bazel_out=tmp, execroot=tmp, plan=None)

    def test_build_spec_finds_named_package_config(self):
        tmp = tempfile.mkdtemp()
        pc = os.path.join(tmp, "bin", "app", "app.package_config.json")
        touch(pc, b"{}")
        apk = os.path.join(tmp, "x.apk")
        make_apk(apk)
        built = argparse.Namespace(bazel_out=tmp, execroot=tmp,
                                   plan=("archives", [apk], tmp))
        spec = floor_flow.build_spec("android_debug", built, tmp, tmp)
        self.assertEqual(pc, spec.packages)
        self.assertEqual("org-dartlang-app:///app/lib/main.dart", spec.entry)

    def test_build_spec_rejects_bare_package_config(self):
        for names in ((), ("package_config.json",)):
            tmp = tempfile.mkdtemp()
            for name in names:
                touch(os.path.join(tmp, "app", name), b"{}")
            with self.assertRaises(floor.MissingToolError) as ctx:
                floor_flow.build_spec("android_debug", self.built(tmp),
                                      tmp, tmp)
            self.assertIn("app.package_config.json", str(ctx.exception))
            self.assertIn(tmp, str(ctx.exception))


class FrontendArgvTest(unittest.TestCase):
    def test_multi_root_options_and_app_entry(self):
        tmp = tempfile.mkdtemp()
        roots = fake_sdk(tmp)
        for mode in ("debug", "release"):
            spec = floor.FloorSpec(
                "android", mode, "/pkg", "org-dartlang-app:///app/lib/main.dart",
                "/pc.json", tmp, ("/work", "/exec"))
            argv = floor.frontend_argv(
                spec, floor.resolve_tools(spec, roots), "/o.dill",
                incremental=mode == "debug")
            self.assertEqual(["/work", "/exec"], [
                argv[i + 1] for i, a in enumerate(argv)
                if a == "--filesystem-root"])
            self.assertEqual("org-dartlang-app", argv[
                argv.index("--filesystem-scheme") + 1])
            if mode == "release":
                self.assertEqual(spec.entry, argv[-1])


class FloorExitTest(unittest.TestCase):
    def summaries(self, **flows):
        return {"ios": {"flows": flows}}

    def test_failed_floor_exits_nonzero_and_names_flow(self):
        out = io.StringIO()
        flows = self.summaries(
            good={"floor_identical": True}, bad={
                "floor_identical": False, "floor_reason": "floor: nope"})
        old, sys.stdout = sys.stdout, out
        try:
            code = floor_summary.floor_failure_exit(flows)
        finally:
            sys.stdout = old
        self.assertEqual(1, code)
        self.assertIn("flow=bad", out.getvalue())
        self.assertNotIn("flow=good", out.getvalue())

    def test_run_exit_keeps_attribution_exit(self):
        flows = self.summaries(a={"floor_identical": True})
        self.assertEqual(0, floor_summary.run_exit(flows, True))
        flows["ios"]["flows"]["a"]["attribution"] = {"ok": False}
        self.assertEqual(0, floor_summary.run_exit(flows, False))
        self.assertEqual(1, floor_summary.run_exit(flows, True))

    def test_held_or_absent_floor_exits_zero(self):
        self.assertEqual(0, floor_summary.floor_failure_exit(self.summaries(
            a={"floor_identical": True}, b={"identical": True})))


def sol_record(floor_cpu=None, reason="ok", with_floor=True):
    record = {"flow": "x", "scenario": "core_edit", "method": "warm",
              "bazel": {"cpu_s": 30.0, "real_s": 40.0},
              "sol": {"cpu_s": 10.0, "real_s": 11.0}, "identical": True,
              "reason": "ok", "n_sol_actions": 3, "worker_steps": {},
              "profile": {}, "chain": {}}
    if with_floor:
        ok = floor_cpu is not None
        record["toolchain_floor"] = {"cpu_s": floor_cpu} if ok else None
        record["floor_identical"] = ok
        record["floor_reason"] = reason
    return record


class SummaryTest(unittest.TestCase):
    def test_floor_beside_unchanged_sol(self):
        records = [sol_record(5.0), sol_record(6.0), sol_record(7.0)]
        flow = sol_summary.summarize_flow(records, "cpu_seconds")
        base = sol_summary.summarize_flow(
            [sol_record(with_floor=False)] * 3, "cpu_seconds")
        self.assertEqual(base["sol"], flow["sol"])
        self.assertEqual(6.0, flow["toolchain_floor"])
        self.assertEqual([5.0, 7.0], flow["spread"]["toolchain_floor"])
        self.assertAlmostEqual(5.0, flow["bazel_over_toolchain_floor"])
        self.assertTrue(flow["floor_identical"])
        self.assertEqual("ok", flow["floor_reason"])

    def test_failed_floor_leaves_sol(self):
        records = [sol_record(5.0), sol_record(None, "apksigner verify failed")]
        flow = sol_summary.summarize_flow(records, "cpu_seconds")
        self.assertIsNone(flow["toolchain_floor"])
        self.assertFalse(flow["floor_identical"])
        self.assertIn("apksigner", flow["floor_reason"])
        self.assertEqual(10.0, flow["sol"])
        self.assertTrue(flow["identical"])

    def test_no_floor_keys_without_floor_records(self):
        flow = sol_summary.summarize_flow(
            [sol_record(with_floor=False)], "cpu_seconds")
        for key in ("toolchain_floor", "floor_identical", "floor_reason",
                    "bazel_over_toolchain_floor"):
            self.assertNotIn(key, flow)
        self.assertNotIn("toolchain_floor", flow["spread"])
        self.assertFalse(floor_summary.has_floor([sol_record(
            with_floor=False)]))

    def test_parser_floor_flag(self):
        parser = sol.build_parser()
        base = ["run", "--tools", "t", "--pristine", "p", "--work", "w",
                "--out-base", "o", "--results", "r", "--rep", "1"]
        self.assertEqual("on", parser.parse_args(base).floor)
        self.assertEqual("off", parser.parse_args(
            base + ["--floor=off"]).floor)


if __name__ == "__main__":
    unittest.main()
