"""Selected module versions for the floor proof.

A repository rule reads the `MODULE.bazel` of every module in the checked-in
floor table and writes the version each resolved external repo actually
carries. The git-overridden `ai_rules_dart` has no version of its own in its
source `MODULE.bazel` (the release workflow patches it in), so its version
comes from the root module's `bazel_dep` declaration. The resulting
`versions.json` is what `//:dependency_floors_test` compares with the floors
and their documented lifts.
"""

def _version_from_module(text, module):
    """The first literal `version = "..."` in [text], failing when absent."""
    marker = 'version = "'
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        index = stripped.find(marker)
        if index < 0:
            continue
        rest = stripped[index + len(marker):]
        end = rest.find('"')
        if end >= 0:
            return rest[:end]
    fail("no module version in @%s//:MODULE.bazel" % module)

def _version_from_bazel_dep(text, module):
    """The root `bazel_dep` version declared for [module], failing when absent."""
    name = 'name = "%s"' % module
    marker = 'version = "'
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("bazel_dep(") or name not in stripped:
            continue
        index = stripped.find(marker)
        if index < 0:
            continue
        rest = stripped[index + len(marker):]
        end = rest.find('"')
        if end >= 0:
            return rest[:end]
    fail("no bazel_dep version for %s in the root MODULE.bazel" % module)

def _selected_version(rctx, root_source, module):
    """The version [module] resolves to in this workspace."""
    if module == "ai_rules_dart":
        return _version_from_bazel_dep(root_source, module)
    # Canonical repo names are independent of the root's apparent-name mapping:
    # a workspace that does not declare every module directly (the pre-fix
    # fixture does not) still has the selected module repo under `<name>+`.
    # `platforms` is the exception: Bazel keeps its canonical name unversioned.
    if module == "platforms":
        label = Label("@platforms//:MODULE.bazel")
    else:
        label = Label("@@%s+//:MODULE.bazel" % module)
    return _version_from_module(rctx.read(rctx.path(label)), module)

def _resolved_module_versions_impl(rctx):
    """Write every selected module version named by the floor table."""
    floors = json.decode(rctx.read(rctx.path(rctx.attr.floors)))
    root_source = rctx.read(rctx.path(rctx.attr.root_module))
    versions = {}
    for module in floors:
        versions[module] = _selected_version(rctx, root_source, module)
    rctx.file("MODULE.bazel", 'module(name = "resolved_module_versions")\n')
    rctx.file(
        "BUILD.bazel",
        'exports_files(["versions.json"], visibility = ["//visibility:public"])\n',
    )
    rctx.file("versions.json", json.encode(versions) + "\n")

resolved_module_versions = repository_rule(
    implementation = _resolved_module_versions_impl,
    attrs = {
        "floors": attr.label(
            allow_single_file = True,
            doc = "The checked-in dependency floor table that names the modules to read.",
        ),
        "root_module": attr.label(
            allow_single_file = True,
            default = "//:MODULE.bazel",
            doc = "The root MODULE.bazel, read for the git-overridden ai_rules_dart pin.",
        ),
    },
    doc = "Writes the selected version of every module in the floor table.",
)
