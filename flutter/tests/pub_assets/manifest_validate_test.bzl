"""Tests for fail-closed `flutter:` section validation with line numbers.

Covers the flutter_tools 3.47.7 `_validate` parity rules
(`flutter_manifest_validate.bzl`): every shape flutter_tools reports is one
spoke-fetch refusal naming `pubspec.yaml` and the offending line, through
the single `asset_errors` / `check_asset_entry_problems` path. Each refusal
test pins the refusal's line; the control tests pin that accepted shapes
still parse exactly as on main. All fixtures count lines from 1 at the
`name:` line (`\"\"\"\\` keeps the opening line).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_assets.bzl", "asset_entry_problem_error")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

def _assert_refused(env, content, key, detail_fragment, line):
    """Assert `content` yields exactly one `key` refusal at `line`.

    Args:
        env: The unittest environment.
        content: Full pubspec.yaml content with a malformed section.
        key: The expected refusal key.
        detail_fragment: A substring the refusal detail must carry.
        line: The expected 1-based `pubspec.yaml` line.

    Returns:
        The parsed block, so the caller can pin what survived refusal.
    """
    result = parse_flutter_assets_block(content)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, key, problem.key)
    asserts.equals(env, line, problem.line)
    asserts.true(env, detail_fragment in problem.detail, problem.detail)
    message = asset_entry_problem_error("manifest_pkg", problem)
    asserts.true(env, "manifest_pkg" in message, message)
    asserts.true(env, "pubspec.yaml line %d" % line in message, message)
    return result

def _assert_accepted(env, content):
    """Assert `content` parses with no refusals; returns the parsed block."""
    result = parse_flutter_assets_block(content)
    asserts.equals(env, [], result.asset_errors)
    return result

# -- font weight / style --------------------------------------------------------------

_BAD_WEIGHT_PUBSPEC = """\
name: bad_weight
flutter:
  fonts:
    - family: F
      fonts:
        - asset: a.ttf
          weight: 150
"""

def _bad_weight_refused_test_impl(ctx):
    """A font `weight` outside 100..900 fails at the `weight:` line."""
    env = unittest.begin(ctx)
    result = _assert_refused(env, _BAD_WEIGHT_PUBSPEC, "fonts", "for font -> weight", 7)
    asserts.equals(env, "F", result.fonts[0].family)
    asserts.equals(env, "a.ttf", result.fonts[0].fonts[0].asset)
    asserts.equals(env, None, result.fonts[0].fonts[0].weight)
    return unittest.end(env)

_BOOL_WEIGHT_PUBSPEC = """\
name: bool_weight
flutter:
  fonts:
    - family: F
      fonts:
        - asset: a.ttf
          weight: true
"""

def _bool_weight_refused_test_impl(ctx):
    """A non-integer font `weight` fails at the `weight:` line."""
    env = unittest.begin(ctx)
    _assert_refused(env, _BOOL_WEIGHT_PUBSPEC, "fonts", "for font -> weight", 7)
    return unittest.end(env)

_NULL_WEIGHT_PUBSPEC = """\
name: null_weight
flutter:
  fonts:
    - family: F
      fonts:
        - asset: a.ttf
          weight:
"""

def _null_weight_refused_test_impl(ctx):
    """A present-but-empty font `weight` fails at the `weight:` line."""
    env = unittest.begin(ctx)
    _assert_refused(env, _NULL_WEIGHT_PUBSPEC, "fonts", "for font -> weight", 7)
    return unittest.end(env)

_BAD_STYLE_PUBSPEC = """\
name: bad_style
flutter:
  fonts:
    - family: F
      fonts:
        - asset: a.ttf
          style: bold
"""

def _bad_style_refused_test_impl(ctx):
    """A font `style` outside italic/normal fails at the `style:` line."""
    env = unittest.begin(ctx)
    _assert_refused(env, _BAD_STYLE_PUBSPEC, "fonts", "for font -> style", 7)
    return unittest.end(env)

_FONT_EXTRA_KEY_PUBSPEC = """\
name: font_extra_key
flutter:
  fonts:
    - family: F
      fonts:
        - asset: a.ttf
          foo: 5
"""

def _font_extra_key_refused_test_impl(ctx):
    """An unexpected key in a font file entry fails at the key's line."""
    env = unittest.begin(ctx)
    _assert_refused(env, _FONT_EXTRA_KEY_PUBSPEC, "fonts", "Unexpected key foo", 7)
    return unittest.end(env)

_FAMILY_EXTRA_KEY_PUBSPEC = """\
name: family_extra_key
flutter:
  fonts:
    - family: F
      extra: 1
      fonts:
        - asset: a.ttf
"""

def _family_extra_key_refused_test_impl(ctx):
    """An unexpected key in a font family entry fails at the key's line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _FAMILY_EXTRA_KEY_PUBSPEC,
        "fonts",
        "Unexpected child \"extra\" found under \"fonts\".",
        5,
    )
    return unittest.end(env)

# -- uses-material-design / scalar section ----------------------------------------------

_STRING_UMD_PUBSPEC = """\
name: string_umd
flutter:
  uses-material-design: "yes"
"""

def _string_umd_refused_test_impl(ctx):
    """A string `uses-material-design` fails at its line and reads as false."""
    env = unittest.begin(ctx)
    result = _assert_refused(
        env,
        _STRING_UMD_PUBSPEC,
        "uses-material-design",
        "Expected \"uses-material-design\" to be a bool",
        3,
    )
    asserts.false(env, result.uses_material_design)
    return unittest.end(env)

_BARE_UMD_PUBSPEC = """\
name: bare_umd
flutter:
  uses-material-design:
"""

def _bare_umd_refused_test_impl(ctx):
    """An empty `uses-material-design` fails at its line, not silently false."""
    env = unittest.begin(ctx)
    result = _assert_refused(
        env,
        _BARE_UMD_PUBSPEC,
        "uses-material-design",
        "Expected \"uses-material-design\" to be a bool",
        3,
    )
    asserts.false(env, result.uses_material_design)
    return unittest.end(env)

_BOGUS_CHILD_PUBSPEC = """\
name: bogus_child
flutter:
  bogus: 1
"""

def _bogus_child_refused_test_impl(ctx):
    """An unknown `flutter:` child fails at the child's line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BOGUS_CHILD_PUBSPEC,
        "bogus",
        "Unexpected child \"bogus\" found under \"flutter\".",
        3,
    )
    return unittest.end(env)

_SCALAR_FLUTTER_PUBSPEC = """\
name: scalar_flutter
flutter: 1
"""

def _scalar_flutter_refused_test_impl(ctx):
    """A scalar `flutter:` section fails at the `flutter:` line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _SCALAR_FLUTTER_PUBSPEC,
        "flutter",
        "Expected \"flutter\" section to be an object or null",
        2,
    )
    return unittest.end(env)

# -- licenses / default-flavor / moved key -------------------------------------------------

_SCALAR_LICENSES_PUBSPEC = """\
name: scalar_licenses
flutter:
  licenses: a.txt
"""

def _scalar_licenses_refused_test_impl(ctx):
    """A scalar `licenses` value fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _SCALAR_LICENSES_PUBSPEC,
        "licenses",
        "Expected \"licenses\" to be a list of files",
        3,
    )
    return unittest.end(env)

_BAD_LICENSE_ELEMENT_PUBSPEC = """\
name: bad_license_element
flutter:
  licenses:
    - a.txt
    - 5
"""

def _bad_license_element_refused_test_impl(ctx):
    """A non-string `licenses` element fails at the element's line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_LICENSE_ELEMENT_PUBSPEC,
        "licenses",
        "but element at index 1 was a",
        5,
    )
    return unittest.end(env)

_BAD_DEFAULT_FLAVOR_PUBSPEC = """\
name: bad_default_flavor
flutter:
  default-flavor: 1
"""

def _bad_default_flavor_refused_test_impl(ctx):
    """A non-string `default-flavor` fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_DEFAULT_FLAVOR_PUBSPEC,
        "default-flavor",
        "Expected \"default-flavor\" to be a string",
        3,
    )
    return unittest.end(env)

_MOVED_SWIFT_PM_PUBSPEC = """\
name: moved_swift_pm
flutter:
  disable-swift-package-manager: true
"""

def _moved_swift_pm_refused_test_impl(ctx):
    """The moved `disable-swift-package-manager` key fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _MOVED_SWIFT_PM_PUBSPEC,
        "disable-swift-package-manager",
        "The \"disable-swift-package-manager\" configuration has moved.",
        3,
    )
    return unittest.end(env)

# -- module -----------------------------------------------------------------------------

_SCALAR_MODULE_PUBSPEC = """\
name: scalar_module
flutter:
  module: true
"""

def _scalar_module_refused_test_impl(ctx):
    """A scalar `module` value fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _SCALAR_MODULE_PUBSPEC,
        "module",
        "Expected \"module\" to be an object",
        3,
    )
    return unittest.end(env)

_BAD_ANDROID_X_PUBSPEC = """\
name: bad_android_x
flutter:
  module:
    androidX: "yes"
"""

def _bad_android_x_refused_test_impl(ctx):
    """A non-bool `module.androidX` fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_ANDROID_X_PUBSPEC,
        "module",
        "The \"androidX\" value must be a bool if set.",
        4,
    )
    return unittest.end(env)

# -- plugin -------------------------------------------------------------------------------

_NULL_PLUGIN_PUBSPEC = """\
name: null_plugin
flutter:
  plugin:
"""

def _null_plugin_refused_test_impl(ctx):
    """An empty `plugin:` value fails at the `plugin:` line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _NULL_PLUGIN_PUBSPEC,
        "plugin",
        "Expected \"plugin\" to be an object",
        3,
    )
    return unittest.end(env)

_EMPTY_PLUGIN_PUBSPEC = """\
name: empty_plugin
flutter:
  plugin: {}
"""

def _empty_plugin_refused_test_impl(ctx):
    """An empty `plugin:` map fails naming the missing `platforms` key."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _EMPTY_PLUGIN_PUBSPEC,
        "plugin",
        "Cannot find the `flutter.plugin.platforms` key",
        3,
    )
    return unittest.end(env)

_SCALAR_PLATFORMS_PLUGIN_PUBSPEC = """\
name: scalar_platforms_plugin
flutter:
  plugin:
    platforms: android
"""

def _scalar_platforms_plugin_refused_test_impl(ctx):
    """A scalar `plugin.platforms` fails at the `platforms:` line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _SCALAR_PLATFORMS_PLUGIN_PUBSPEC,
        "plugin",
        "flutter.plugin.platforms should be a map",
        4,
    )
    return unittest.end(env)

_EMPTY_ANDROID_PLUGIN_PUBSPEC = """\
name: empty_android_plugin
flutter:
  plugin:
    platforms:
      android:
"""

def _empty_android_plugin_refused_test_impl(ctx):
    """An empty `android:` platform entry fails at the entry's line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _EMPTY_ANDROID_PLUGIN_PUBSPEC,
        "plugin",
        "Invalid \"android\" plugin specification.",
        5,
    )
    return unittest.end(env)

_OLD_NEW_PLUGIN_PUBSPEC = """\
name: old_new_plugin
flutter:
  plugin:
    pluginClass: P
    platforms:
      android:
        package: com.example
        pluginClass: P
"""

def _old_new_plugin_refused_test_impl(ctx):
    """Legacy keys beside `platforms` fail at the `plugin:` line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _OLD_NEW_PLUGIN_PUBSPEC,
        "plugin",
        "cannot be used in combination",
        3,
    )
    return unittest.end(env)

_BAD_LEGACY_PLUGIN_PUBSPEC = """\
name: bad_legacy_plugin
flutter:
  plugin:
    pluginClass: 5
"""

def _bad_legacy_plugin_refused_test_impl(ctx):
    """A non-string legacy `pluginClass` fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_LEGACY_PLUGIN_PUBSPEC,
        "plugin",
        "The \"pluginClass\" must either be null or a string.",
        4,
    )
    return unittest.end(env)

# -- deferred-components ---------------------------------------------------------------------

_SCALAR_DEFERRED_PUBSPEC = """\
name: scalar_deferred
flutter:
  deferred-components: true
"""

def _scalar_deferred_refused_test_impl(ctx):
    """A scalar `deferred-components` value fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _SCALAR_DEFERRED_PUBSPEC,
        "deferred-components",
        "Expected \"deferred-components\" to be a list",
        3,
    )
    return unittest.end(env)

_NAMELESS_DEFERRED_PUBSPEC = """\
name: nameless_deferred
flutter:
  deferred-components:
    - libraries:
        - a
"""

def _nameless_deferred_refused_test_impl(ctx):
    """A deferred element without a string `name` fails at the element."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _NAMELESS_DEFERRED_PUBSPEC,
        "deferred-components",
        "required key \"name\" of type String",
        4,
    )
    return unittest.end(env)

_BAD_LIBRARIES_DEFERRED_PUBSPEC = """\
name: bad_libraries_deferred
flutter:
  deferred-components:
    - name: c
      libraries: a
"""

def _bad_libraries_deferred_refused_test_impl(ctx):
    """A scalar deferred `libraries` value fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_LIBRARIES_DEFERRED_PUBSPEC,
        "deferred-components",
        "\"libraries\" key in the element at index 0",
        5,
    )
    return unittest.end(env)

_BAD_ASSETS_DEFERRED_PUBSPEC = """\
name: bad_assets_deferred
flutter:
  deferred-components:
    - name: c
      assets: a.png
"""

def _bad_assets_deferred_refused_test_impl(ctx):
    """A scalar deferred `assets` value fails at its line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _BAD_ASSETS_DEFERRED_PUBSPEC,
        "assets",
        "Expected \"assets\" to be a list",
        5,
    )
    return unittest.end(env)

# -- flow collections and the spoke message ----------------------------------------------------

_FLOW_FONTS_PUBSPEC = """\
name: flow_fonts
flutter:
  fonts: [1]
"""

def _flow_fonts_refused_test_impl(ctx):
    """A flow `fonts` list of non-maps fails once at the `fonts:` line."""
    env = unittest.begin(ctx)
    _assert_refused(
        env,
        _FLOW_FONTS_PUBSPEC,
        "fonts",
        "Expected \"fonts\" to contain maps",
        3,
    )
    return unittest.end(env)

def _spoke_message_names_line_test_impl(ctx):
    """The spoke failure names the package, pubspec.yaml and the line."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_BAD_WEIGHT_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    message = asset_entry_problem_error("weight_pkg", result.asset_errors[0])
    asserts.true(
        env,
        message.startswith("flutter.pub spoke for \"weight_pkg\": pubspec.yaml line 7: "),
        message,
    )
    asserts.true(env, "asset \"fonts[0]\": Invalid value 150" in message, message)
    return unittest.end(env)

# -- accepted shapes stay byte-identical ---------------------------------------------------------

_ACCEPTED_FONTS_PUBSPEC = """\
name: accepted_fonts
flutter:
  fonts:
    - family: F
      fonts:
        - asset: light.ttf
          weight: 100
        - asset: black.ttf
          weight: 900
          style: italic
"""

def _accepted_font_bounds_load_test_impl(ctx):
    """Boundary weights and italic stay valid and read as on main."""
    env = unittest.begin(ctx)
    result = _assert_accepted(env, _ACCEPTED_FONTS_PUBSPEC)
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, 100, result.fonts[0].fonts[0].weight)
    asserts.equals(env, 900, result.fonts[0].fonts[1].weight)
    asserts.equals(env, "italic", result.fonts[0].fonts[1].style)
    return unittest.end(env)

_ACCEPTED_FLAGS_PUBSPEC = """\
name: accepted_flags
flutter:
  uses-material-design: true
  generate: true
  config:
    enable-swift-package-manager: false
"""

def _accepted_flags_load_test_impl(ctx):
    """`generate` and `config` carry no checks and stay valid."""
    env = unittest.begin(ctx)
    result = _assert_accepted(env, _ACCEPTED_FLAGS_PUBSPEC)
    asserts.true(env, result.uses_material_design)
    return unittest.end(env)

_ANY_GENERATE_PUBSPEC = """\
name: any_generate
flutter:
  generate: 5
"""

def _any_generate_loads_test_impl(ctx):
    """A nonsense `generate` value stays accepted, as flutter_tools accepts it."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _ANY_GENERATE_PUBSPEC)
    return unittest.end(env)

_VALID_PLUGIN_PUBSPEC = """\
name: valid_plugin
flutter:
  plugin:
    platforms:
      android:
        package: com.example.valid
        pluginClass: ValidPlugin
      ios:
        pluginClass: ValidPlugin
"""

def _valid_plugin_loads_test_impl(ctx):
    """A valid multi-platform plugin stays accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _VALID_PLUGIN_PUBSPEC)
    return unittest.end(env)

_VALID_LEGACY_PLUGIN_PUBSPEC = """\
name: valid_legacy_plugin
flutter:
  plugin:
    pluginClass: ValidPlugin
"""

def _valid_legacy_plugin_loads_test_impl(ctx):
    """A valid legacy-format plugin stays accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _VALID_LEGACY_PLUGIN_PUBSPEC)
    return unittest.end(env)

_EMPTY_PLATFORMS_PLUGIN_PUBSPEC = """\
name: empty_platforms_plugin
flutter:
  plugin:
    platforms: {}
"""

def _empty_platforms_plugin_loads_test_impl(ctx):
    """An empty `platforms` map stays accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _EMPTY_PLATFORMS_PLUGIN_PUBSPEC)
    return unittest.end(env)

_UNVALIDATED_PLUGIN_PUBSPEC = """\
name: unvalidated_plugin
flutter:
  plugin:
    platforms:
      ios:
        sharedDarwinSource: true
      web:
        whatever: 1
      qnx:
        pluginClass: Q
"""

def _unvalidated_plugin_loads_test_impl(ctx):
    """`web`, unknown platforms and `default_package` bypasses stay accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _UNVALIDATED_PLUGIN_PUBSPEC)
    return unittest.end(env)

_DEFAULT_PACKAGE_PLUGIN_PUBSPEC = """\
name: default_package_plugin
flutter:
  plugin:
    platforms:
      android:
        default_package: impl
"""

def _default_package_plugin_loads_test_impl(ctx):
    """A `default_package` platform entry stays accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _DEFAULT_PACKAGE_PLUGIN_PUBSPEC)
    return unittest.end(env)

_EMPTY_DEFERRED_PUBSPEC = """\
name: empty_deferred
flutter:
  deferred-components: []
"""

def _empty_deferred_loads_test_impl(ctx):
    """An empty `deferred-components` list stays accepted.

    flutter_tools 3.47.7 crashes reading one (an upstream bug, never a
    reported error), so refusing it would diverge from its errors.
    """
    env = unittest.begin(ctx)
    _assert_accepted(env, _EMPTY_DEFERRED_PUBSPEC)
    return unittest.end(env)

_EMPTY_LICENSES_MODULE_PUBSPEC = """\
name: empty_licenses_module
flutter:
  licenses: []
  module: {}
"""

def _empty_licenses_module_loads_test_impl(ctx):
    """Empty `licenses` and `module` values stay accepted."""
    env = unittest.begin(ctx)
    _assert_accepted(env, _EMPTY_LICENSES_MODULE_PUBSPEC)
    return unittest.end(env)

_NO_FLUTTER_PUBSPEC = """\
name: no_flutter
dependencies:
  foo: 1
"""

def _no_flutter_loads_test_impl(ctx):
    """A pubspec without `flutter:` parses with no refusals."""
    env = unittest.begin(ctx)
    result = _assert_accepted(env, _NO_FLUTTER_PUBSPEC)
    asserts.equals(env, [], result.assets)
    asserts.equals(env, [], result.fonts)
    asserts.equals(env, [], result.shaders)
    asserts.false(env, result.uses_material_design)
    return unittest.end(env)

_m0_test = unittest.make(_bad_weight_refused_test_impl)
_m1_test = unittest.make(_bool_weight_refused_test_impl)
_m2_test = unittest.make(_null_weight_refused_test_impl)
_m3_test = unittest.make(_bad_style_refused_test_impl)
_m4_test = unittest.make(_font_extra_key_refused_test_impl)
_m5_test = unittest.make(_family_extra_key_refused_test_impl)
_m6_test = unittest.make(_string_umd_refused_test_impl)
_m7_test = unittest.make(_bare_umd_refused_test_impl)
_m8_test = unittest.make(_bogus_child_refused_test_impl)
_m9_test = unittest.make(_scalar_flutter_refused_test_impl)
_m10_test = unittest.make(_scalar_licenses_refused_test_impl)
_m11_test = unittest.make(_bad_license_element_refused_test_impl)
_m12_test = unittest.make(_bad_default_flavor_refused_test_impl)
_m13_test = unittest.make(_moved_swift_pm_refused_test_impl)
_m14_test = unittest.make(_scalar_module_refused_test_impl)
_m15_test = unittest.make(_bad_android_x_refused_test_impl)
_m16_test = unittest.make(_null_plugin_refused_test_impl)
_m17_test = unittest.make(_empty_plugin_refused_test_impl)
_m18_test = unittest.make(_scalar_platforms_plugin_refused_test_impl)
_m19_test = unittest.make(_empty_android_plugin_refused_test_impl)
_m20_test = unittest.make(_old_new_plugin_refused_test_impl)
_m21_test = unittest.make(_bad_legacy_plugin_refused_test_impl)
_m22_test = unittest.make(_scalar_deferred_refused_test_impl)
_m23_test = unittest.make(_nameless_deferred_refused_test_impl)
_m24_test = unittest.make(_bad_libraries_deferred_refused_test_impl)
_m25_test = unittest.make(_bad_assets_deferred_refused_test_impl)
_m26_test = unittest.make(_flow_fonts_refused_test_impl)
_m27_test = unittest.make(_spoke_message_names_line_test_impl)
_m28_test = unittest.make(_accepted_font_bounds_load_test_impl)
_m29_test = unittest.make(_accepted_flags_load_test_impl)
_m30_test = unittest.make(_any_generate_loads_test_impl)
_m31_test = unittest.make(_valid_plugin_loads_test_impl)
_m32_test = unittest.make(_valid_legacy_plugin_loads_test_impl)
_m33_test = unittest.make(_empty_platforms_plugin_loads_test_impl)
_m34_test = unittest.make(_unvalidated_plugin_loads_test_impl)
_m35_test = unittest.make(_default_package_plugin_loads_test_impl)
_m36_test = unittest.make(_empty_deferred_loads_test_impl)
_m37_test = unittest.make(_empty_licenses_module_loads_test_impl)
_m38_test = unittest.make(_no_flutter_loads_test_impl)

def manifest_validate_test_suite(name):
    """The `flutter:` section validation test suite."""
    unittest.suite(
        name,
        _m0_test,
        _m1_test,
        _m2_test,
        _m3_test,
        _m4_test,
        _m5_test,
        _m6_test,
        _m7_test,
        _m8_test,
        _m9_test,
        _m10_test,
        _m11_test,
        _m12_test,
        _m13_test,
        _m14_test,
        _m15_test,
        _m16_test,
        _m17_test,
        _m18_test,
        _m19_test,
        _m20_test,
        _m21_test,
        _m22_test,
        _m23_test,
        _m24_test,
        _m25_test,
        _m26_test,
        _m27_test,
        _m28_test,
        _m29_test,
        _m30_test,
        _m31_test,
        _m32_test,
        _m33_test,
        _m34_test,
        _m35_test,
        _m36_test,
        _m37_test,
        _m38_test,
    )
