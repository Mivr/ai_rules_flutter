"""Tests for `path:` dependency spokes: tree watching and lock-root resolution.

A path package is symlinked into its spoke, so the generator reads it in
place. Two hermeticity properties pin the wiring:

* Every file and directory under the package is `ctx.watch`ed. Bazel does
  not watch reads inside a repository's own directory, so an unwatched
  nested directory (an asset folder gaining a file, say) leaves a stale
  spoke and the app silently ships the wrong asset set.
* A `path:` entry resolves against the lock file's own directory, and only
  the root module's workspace is reachable from a spoke. The resolution
  helper joins lock-dir + entry; anything else is refused elsewhere.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter:extensions.bzl", "foreign_lock_path_error", "workspace_relative_lock_path")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "link_path_package",
)

def _tree_node(tree, rel):
    """The node at `rel` ("a/b") in a nested-dict tree, files are None."""
    node = tree
    if rel == "":
        return node
    for seg in rel.split("/"):
        if type(node) != "dict" or seg not in node:
            return "missing"
        node = node[seg]
    return node

def _make_mock_link_ctx(tree, path_value = "platform_assets", package_name = "platform_assets"):
    """Fake repository_ctx for `link_path_package` over an in-memory tree.

    Args:
        tree: Nested dict of relpath -> None (file) or dict (directory),
            relative to a fake `/workspace` root.
        path_value: Value for `ctx.attr.path`.
        package_name: Value for `ctx.attr.package_name`.

    Returns:
        struct(ctx, watched, linked): the fake ctx, the watched path
        strings, and the symlinked link names.
    """
    watched = []
    linked = []

    def _make_path(rel):
        full = "/workspace/" + rel if rel else "/workspace"
        node = _tree_node(tree, rel)
        children = sorted(node.keys()) if type(node) == "dict" else []

        def _readdir():
            return [_make_path(rel + "/" + c if rel else c) for c in children]

        def _get_child(*segments):
            child_rel = rel
            for seg in segments:
                child_rel = child_rel + "/" + seg if child_rel else seg
            return _make_path(child_rel)

        return struct(
            path = full,
            basename = rel.split("/")[-1] if rel else "",
            exists = node != "missing",
            is_dir = type(node) == "dict",
            readdir = _readdir,
            get_child = _get_child,
        )

    def _watch(path_obj):
        watched.append(path_obj.path)

    def _symlink(target, link_name):
        linked.append(link_name)

    return struct(
        ctx = struct(
            attr = struct(path = path_value, package_name = package_name),
            workspace_root = _make_path(""),
            watch = _watch,
            symlink = _symlink,
        ),
        watched = watched,
        linked = linked,
    )

# The fixture shape from the defect report: a conditioned asset directory
# holding files, plus a nested directory and an empty one.
_LINK_CONTENTS = {
    "pubspec.yaml": None,
    "assets": {
        "any.txt": None,
        "dir": {
            "one.txt": None,
            "two.txt": None,
        },
        "icons": {},
    },
}

_LINK_WATCHED = [
    "/workspace/platform_assets",
    "/workspace/platform_assets/pubspec.yaml",
    "/workspace/platform_assets/assets",
    "/workspace/platform_assets/assets/any.txt",
    "/workspace/platform_assets/assets/dir",
    "/workspace/platform_assets/assets/dir/one.txt",
    "/workspace/platform_assets/assets/dir/two.txt",
    "/workspace/platform_assets/assets/icons",
]

def _link_watches_the_whole_tree_test_impl(ctx):
    """Adding a file anywhere under the package refetches the spoke.

    Without a watch on each nested node, `assets/dir/two.txt` appearing
    after the first fetch leaves a spoke whose BUILD lists only `one.txt`.
    """
    env = unittest.begin(ctx)
    mock = _make_mock_link_ctx({"platform_assets": _LINK_CONTENTS})
    link_path_package(mock.ctx)
    asserts.equals(env, sorted(_LINK_WATCHED), sorted(mock.watched))
    asserts.equals(env, ["assets", "pubspec.yaml"], sorted(mock.linked))
    return unittest.end(env)

def _lock_path_joins_the_lock_dir_test_impl(ctx):
    """A root-module entry resolves against the lock file's directory."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/hello_world/platform_assets",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "platform_assets",
        ),
    )
    return unittest.end(env)

def _lock_path_stays_inside_the_workspace_test_impl(ctx):
    """`..` segments normalize lexically without leaving the workspace."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "e2e/shared/x",
        workspace_relative_lock_path(
            "deps",
            "platform_assets",
            Label("//e2e/hello_world:pubspec.lock"),
            "../shared/x",
        ),
    )
    return unittest.end(env)

link_watches_the_whole_tree_test = unittest.make(_link_watches_the_whole_tree_test_impl)
lock_path_joins_the_lock_dir_test = unittest.make(_lock_path_joins_the_lock_dir_test_impl)
lock_path_stays_inside_the_workspace_test = unittest.make(_lock_path_stays_inside_the_workspace_test_impl)

def _root_lock_needs_no_refusal_test_impl(ctx):
    """A main-repo lock (empty `workspace_name`) resolves path deps freely."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        foreign_lock_path_error(
            "deps",
            "platform_assets",
            struct(workspace_name = "", package = "e2e/hello_world"),
        ),
    )
    return unittest.end(env)

def _foreign_lock_path_dep_is_refused_test_impl(ctx):
    """A non-root lock's path dep is refused naming hub, package, and lock.

    Resolving it against the consumer workspace would link the wrong
    directory, silently. The message must carry everything the fix needs:
    declare the path dep in the root module's own lock instead.
    """
    env = unittest.begin(ctx)
    message = foreign_lock_path_error(
        "deps",
        "platform_assets",
        struct(workspace_name = "some_dep", package = ""),
    )
    asserts.true(env, message != None, "a foreign lock must be refused")
    asserts.true(env, "deps" in message, "refusal must name the hub")
    asserts.true(env, "platform_assets" in message, "refusal must name the package")
    return unittest.end(env)

root_lock_needs_no_refusal_test = unittest.make(_root_lock_needs_no_refusal_test_impl)
foreign_lock_path_dep_is_refused_test = unittest.make(_foreign_lock_path_dep_is_refused_test_impl)

def path_package_test_suite(name):
    """Declares the path-package spoke hermeticity unit tests.

    Args:
        name: Test suite name.
    """
    unittest.suite(
        name,
        link_watches_the_whole_tree_test,
        lock_path_joins_the_lock_dir_test,
        lock_path_stays_inside_the_workspace_test,
        root_lock_needs_no_refusal_test,
        foreign_lock_path_dep_is_refused_test,
    )
