"""Repository rule for the Flutter web SDK.

Downloads flutter-web-sdk.zip which contains the platform dill files
needed for web builds (dart2wasm_platform.dill, dart2js_platform.dill)
and rewrites web-sdk/libraries.json per exec platform to reference the
shared host Dart SDK repositories via declared labels.
"""

load(":artifact_urls.bzl", "engine_artifact_url", "require_sha256")
load(":toolchains_repo.bzl", "HOST_PLATFORMS")

EXPECTED_WEB_SDK_TARGETS = ("dartdevc", "dart2js", "wasm")
EXPECTED_DART_SDK_INCLUDE = "../dart-sdk/lib/libraries.json"
EXPECTED_WEB_SDK_LIBRARIES = ("ui", "ui_web")

def rewrite_web_sdk_libraries_json(
        raw_json,
        dart_sdk_repo_name,
        source = "web-sdk/libraries.json"):
    """Validate and rewrite `web-sdk/libraries.json` to reference a sibling Dart SDK repo.

    Fails with a named error (`flutter_web_sdk_repo: <error_code>: ...`) when
    `raw_json` is not a valid JSON object, when any expected target entry
    (`dartdevc`, `dart2js`, `wasm`) is missing, when a target's `libraries`
    object or core web libraries (`ui`, `ui_web`) are missing, or when a
    target's `include` list does not contain `../dart-sdk/lib/libraries.json`.

    Args:
        raw_json: Raw JSON string from `web-sdk/libraries.json`.
        dart_sdk_repo_name: Repository directory name under `external/` (from
            a declared `Label`'s `.repo_name`).
        source: Source path description for error messages.

    Returns:
        Rewritten JSON string with trailing newline.
    """
    if not dart_sdk_repo_name or type(dart_sdk_repo_name) != "string":
        fail("flutter_web_sdk_repo: invalid_host_sdk_repo: dart_sdk_repo_name must be a non-empty string")

    if not raw_json or type(raw_json) != "string" or not raw_json.strip().startswith("{"):
        fail("flutter_web_sdk_repo: invalid_libraries_json: %s must be a JSON object" % source)

    parsed = json.decode(raw_json)
    if type(parsed) != "dict":
        fail("flutter_web_sdk_repo: invalid_libraries_json: %s must decode to a top-level JSON object" % source)

    rewritten = dict(parsed)
    replacement_path = "../../%s/dart-sdk/lib/libraries.json" % dart_sdk_repo_name

    for target in EXPECTED_WEB_SDK_TARGETS:
        if target not in parsed or type(parsed[target]) != "dict":
            fail(
                "flutter_web_sdk_repo: missing_target_entry: %s is missing expected target entry %r (expected targets: %s)" % (
                    source,
                    target,
                    ", ".join(EXPECTED_WEB_SDK_TARGETS),
                ),
            )

        target_entry = dict(parsed[target])
        libraries = target_entry.get("libraries")
        if type(libraries) != "dict" or not libraries:
            fail(
                "flutter_web_sdk_repo: missing_libraries_entry: %s target %r is missing expected \"libraries\" object" % (
                    source,
                    target,
                ),
            )
        for lib_name in EXPECTED_WEB_SDK_LIBRARIES:
            lib_spec = libraries.get(lib_name)
            if type(lib_spec) != "dict" or not lib_spec.get("uri"):
                fail(
                    "flutter_web_sdk_repo: missing_library_entry: %s target %r is missing expected library %r" % (
                        source,
                        target,
                        lib_name,
                    ),
                )

        includes = target_entry.get("include")
        if type(includes) != "list" or not includes:
            fail(
                "flutter_web_sdk_repo: missing_include_entry: %s target %r is missing expected \"include\" list" % (
                    source,
                    target,
                ),
            )

        matched_include = False
        new_includes = []
        for inc in includes:
            if type(inc) != "dict":
                fail(
                    "flutter_web_sdk_repo: invalid_include_entry: %s target %r has non-object include entry %r" % (
                        source,
                        target,
                        inc,
                    ),
                )
            inc_copy = dict(inc)
            if inc_copy.get("path") == EXPECTED_DART_SDK_INCLUDE:
                if inc_copy.get("target") != target:
                    fail(
                        "flutter_web_sdk_repo: mismatched_include_target: %s target %r include for %r has target %r (expected %r)" % (
                            source,
                            target,
                            EXPECTED_DART_SDK_INCLUDE,
                            inc_copy.get("target"),
                            target,
                        ),
                    )
                inc_copy["path"] = replacement_path
                matched_include = True
            new_includes.append(inc_copy)

        if not matched_include:
            fail(
                "flutter_web_sdk_repo: missing_dart_sdk_include: %s target %r is missing expected include path %r" % (
                    source,
                    target,
                    EXPECTED_DART_SDK_INCLUDE,
                ),
            )

        target_entry["include"] = new_includes
        rewritten[target] = target_entry

    return json.encode_indent(rewritten, indent = "  ") + "\n"

rewrite_libraries_json = rewrite_web_sdk_libraries_json
edit_libraries_json = rewrite_web_sdk_libraries_json

def resolve_web_sdk_host_repos(host_sdks, user_repository_name = "flutter"):
    """Resolve declared host SDK `Label`s into per-platform repo metadata.

    Locates host SDK repositories from declared `Label` objects (`sdk_label.repo_name`
    and `sdk_label.same_package_label(...)`) rather than canonical-name string
    manipulation.

    Args:
        host_sdks: Dict mapping declared host SDK `Label`s to `HOST_PLATFORMS` keys.
        user_repository_name: Fallback repository base name when `host_sdks` is empty.

    Returns:
        Dict mapping `platform` key to `struct(repo_name, libraries_json_label,
        ddc_module_loader_label, ddc_stack_trace_mapper_label)`.
    """
    label_map = host_sdks
    if not label_map:
        base = user_repository_name or "flutter"
        label_map = {
            Label("@@{}_{}//:dart-sdk/lib/libraries.json".format(base, platform)): platform
            for platform in HOST_PLATFORMS.keys()
        }

    by_platform = {}
    for sdk_label, platform in label_map.items():
        if platform not in HOST_PLATFORMS:
            fail(
                "flutter_web_sdk_repo: unknown_host_platform: unsupported host platform %r (expected one of %s)" % (
                    platform,
                    ", ".join(sorted(HOST_PLATFORMS.keys())),
                ),
            )
        if platform in by_platform:
            fail(
                "flutter_web_sdk_repo: duplicate_host_platform: multiple labels declared for platform %r" % platform,
            )
        repo_name = getattr(sdk_label, "repo_name", None) or getattr(sdk_label, "workspace_name", "")
        if not repo_name:
            fail(
                "flutter_web_sdk_repo: invalid_host_sdk_label: label %r has no repository name" % sdk_label,
            )
        by_platform[platform] = struct(
            repo_name = repo_name,
            libraries_json_label = str(sdk_label.same_package_label("dart-sdk/lib/libraries.json")),
            ddc_module_loader_label = str(sdk_label.same_package_label("dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js")),
            ddc_stack_trace_mapper_label = str(sdk_label.same_package_label("dart-sdk/lib/dev_compiler/web/dart_stack_trace_mapper.js")),
        )

    if not by_platform:
        fail("flutter_web_sdk_repo: missing_host_sdks: at least one host SDK label must be declared")

    ordered = {}
    for platform in HOST_PLATFORMS.keys():
        if platform in by_platform:
            ordered[platform] = by_platform[platform]
    return ordered

def generate_web_sdk_build(host_sdks = {}, user_repository_name = "flutter"):
    """Generate `BUILD.bazel` for `@flutter_web_sdk` selecting the SDK by exec platform.

    Args:
        host_sdks: Dict mapping declared host SDK `Label`s to `HOST_PLATFORMS` keys.
        user_repository_name: Fallback repository base name when `host_sdks` is empty.

    Returns:
        Generated `BUILD.bazel` content string.
    """
    resolved = resolve_web_sdk_host_repos(host_sdks, user_repository_name)

    config_settings = []
    libraries_select_entries = []
    dart_sdk_libraries_select_entries = []
    module_loader_select_entries = []
    stack_mapper_select_entries = []

    for platform, info in resolved.items():
        meta = HOST_PLATFORMS[platform]
        constraints = ",\n        ".join(['"%s"' % c for c in meta.compatible_with])
        config_settings.append("""config_setting(
    name = "{platform}",
    constraint_values = [
        {constraints},
    ],
)""".format(platform = platform, constraints = constraints))
        libraries_select_entries.append(
            '        ":{platform}": ["web-sdk/libraries.{platform}.json"],'.format(platform = platform),
        )
        dart_sdk_libraries_select_entries.append(
            '        ":{platform}": ["{label}"],'.format(platform = platform, label = info.libraries_json_label),
        )
        module_loader_select_entries.append(
            '        ":{platform}": "{label}",'.format(platform = platform, label = info.ddc_module_loader_label),
        )
        stack_mapper_select_entries.append(
            '        ":{platform}": "{label}",'.format(platform = platform, label = info.ddc_stack_trace_mapper_label),
        )

    return """# Generated by flutter_web_sdk_repo.bzl

{config_settings}

filegroup(
    name = "libraries_json",
    srcs = select({{
{libraries_select}
    }}),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dart_sdk_libraries_json",
    srcs = select({{
{dart_sdk_libraries_select}
    }}),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "web_sdk",
    srcs = glob([
        "web-sdk/canvaskit/**",
        "web-sdk/flutter_js/**",
        "web-sdk/libraries.json",
    ]) + [
        ":libraries_json",
        ":dart_sdk_libraries_json",
    ],
    visibility = ["//visibility:public"],
)

alias(
    name = "dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js",
    actual = select({{
{module_loader_select}
    }}),
    visibility = ["//visibility:public"],
)

alias(
    name = "dart-sdk/lib/dev_compiler/web/dart_stack_trace_mapper.js",
    actual = select({{
{stack_mapper_select}
    }}),
    visibility = ["//visibility:public"],
)

exports_files(
    glob(["web-sdk/**"]),
    visibility = ["//visibility:public"],
)
""".format(
        config_settings = "\n\n".join(config_settings),
        libraries_select = "\n".join(libraries_select_entries),
        dart_sdk_libraries_select = "\n".join(dart_sdk_libraries_select_entries),
        module_loader_select = "\n".join(module_loader_select_entries),
        stack_mapper_select = "\n".join(stack_mapper_select_entries),
    )

def _flutter_web_sdk_repo_impl(repository_ctx):
    engine_revision = repository_ctx.attr.engine_revision
    if engine_revision:
        web_url = engine_artifact_url(engine_revision, "flutter-web-sdk.zip")
        repository_ctx.download_and_extract(
            url = web_url,
            sha256 = require_sha256(repository_ctx.attr.sha256, web_url),
            output = "web-sdk",
        )

    libraries_json_attr = getattr(repository_ctx.attr, "libraries_json", None)
    if libraries_json_attr != None:
        libraries_json_path = repository_ctx.path(libraries_json_attr)
        source_name = str(libraries_json_attr)
    else:
        libraries_json_path = repository_ctx.path("web-sdk/libraries.json")
        source_name = "web-sdk/libraries.json"

    if not libraries_json_path.exists:
        fail(
            "flutter_web_sdk_repo: missing_libraries_json: expected %s in repository %r, but file does not exist" % (
                source_name,
                getattr(repository_ctx, "name", "flutter_web_sdk"),
            ),
        )

    raw_libraries_json = repository_ctx.read(libraries_json_path)
    resolved = resolve_web_sdk_host_repos(
        getattr(repository_ctx.attr, "host_sdks", {}),
        getattr(repository_ctx.attr, "user_repository_name", "flutter"),
    )

    default_rewritten = None
    for platform, info in resolved.items():
        rewritten = rewrite_web_sdk_libraries_json(
            raw_libraries_json,
            info.repo_name,
            source = source_name,
        )
        repository_ctx.file("web-sdk/libraries.%s.json" % platform, rewritten)
        if default_rewritten == None or platform == "linux-x64":
            default_rewritten = rewritten

    if default_rewritten != None:
        repository_ctx.file("web-sdk/libraries.json", default_rewritten)

    repository_ctx.file(
        "BUILD.bazel",
        generate_web_sdk_build(
            getattr(repository_ctx.attr, "host_sdks", {}),
            getattr(repository_ctx.attr, "user_repository_name", "flutter"),
        ),
    )

flutter_web_sdk_repo_impl = _flutter_web_sdk_repo_impl

flutter_web_sdk_repo = repository_rule(
    _flutter_web_sdk_repo_impl,
    doc = "Downloads the Flutter web SDK (dart2wasm/dart2js platform dills) and references the exec platform's shared host Dart SDK.",
    attrs = {
        "engine_revision": attr.string(mandatory = True),
        "sha256": attr.string(doc = "Expected SHA-256 of flutter-web-sdk.zip. Required: an empty value fails the fetch."),
        "user_repository_name": attr.string(
            default = "flutter",
            doc = "Base name for Flutter repositories (e.g. `flutter`).",
        ),
        "host_sdks": attr.label_keyed_string_dict(
            doc = "Mapping from declared host SDK repository labels to HOST_PLATFORMS keys.",
        ),
        "libraries_json": attr.label(
            allow_single_file = True,
            doc = "Optional libraries.json file override.",
        ),
    },
)
