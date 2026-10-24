"""Fan-in benchmark fixture (COV-63): bundle analysis cost vs dep count.

`asset_fanin_bundle` builds one weighted base library carrying `p`
generated pub contributions (half font families, half plain assets), `p`
thin libraries that each depend only on the base, and two bundles over
them: `narrow` (one thin dep) and `wide` (300 thin deps). The bundles
exist to measure: analysis cost must be linear in the contributions a
bundle ships, so `wide - narrow` must not grow with `p`. Every target is
`manual`: the pool at `p = 6000` stays out of `//...` builds.
"""

load("//flutter:defs.bzl", "flutter_asset_bundle", "flutter_library")

def _declare_weight(name, count):
    """Declares `count` generated files and returns the base's pub attrs.

    Args:
        name: Prefix for the genrule targets.
        count: Total generated contributions (even counts only).

    Returns:
        A `(font_files, fonts_json, pkg_assets)` triple for the base.
    """
    font_files = {}
    families = []
    pkg_assets = {}
    for i in range(0, count, 2):
        ttf = "%s_%d.ttf" % (name, i)
        txt = "%s_%d.txt" % (name, i)
        native.genrule(
            name = "%s_ttf_%d" % (name, i),
            outs = [ttf],
            cmd = "echo weight > $@",
            tags = ["manual"],
        )
        native.genrule(
            name = "%s_txt_%d" % (name, i),
            outs = [txt],
            cmd = "echo weight > $@",
            tags = ["manual"],
        )
        font_files[":%s_ttf_%d" % (name, i)] = "gen/%s" % ttf
        families.append('{"family":"Fam%d","fonts":[{"asset":"gen/%s"}]}' % (i, ttf))
        pkg_assets[":%s_txt_%d" % (name, i)] = "gen/%s" % txt
    return (font_files, "[" + ",".join(families) + "]", pkg_assets)

def asset_fanin_bundle(name, p = 6000, wide = 300):
    """Declares the fan-in pool, the thin deps and the two bundles.

    Args:
        name: Prefix for every generated target.
        p: Thin deps (and, one per two, generated weight files).
        wide: Thin deps the wide bundle takes.
    """
    font_files, fonts_json, pkg_assets = _declare_weight(name + "_w", p)
    base = name + "_base"
    flutter_library(
        name = base,
        srcs = ["stub.dart"],
        font_files = font_files,
        fonts_json = fonts_json,
        pkg_assets = pkg_assets,
        tags = ["manual"],
    )
    thins = []
    for i in range(p):
        thin = "%s_thin_%d" % (name, i)
        thins.append(thin)
        flutter_library(
            name = thin,
            srcs = ["stub.dart"],
            deps = [":" + base],
            tags = ["manual"],
        )
    flutter_asset_bundle(
        name = name + "_narrow",
        tags = ["manual"],
        deps = [":" + thins[0]] if thins else [":" + base],
    )
    flutter_asset_bundle(
        name = name + "_wide",
        tags = ["manual"],
        deps = [":" + t for t in thins[:wide]] if thins else [":" + base],
    )
