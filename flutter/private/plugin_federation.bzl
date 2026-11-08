"""Federated plugin resolution for platform registrants.

Resolves federated plugin implementations according to Flutter's
resolvePlatformImplementation rules per target platform.
"""

def _dart_plugin_entry(plugin, info):
    """Builds the registrant entry for one plugin's Dart class info.

    Args:
        plugin: Plugin struct.
        info: Platform info dict.

    Returns:
        A struct with package, dart_plugin_class, and dart_file_name.
    """
    return struct(
        package = plugin.name,
        dart_plugin_class = info.get("dartPluginClass", ""),
        dart_file_name = info.get("fileName", info.get("dartFileName", plugin.name + ".dart")),
    )

def collect_platform_dart_plugins(plugins, target_platform):
    """Collects `dartPluginClass` entries for one platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.

    Returns:
        List of dart plugin entry structs.
    """
    dart_plugins = []
    for plugin in plugins:
        info = plugin.platforms.get(target_platform, {})
        if not info:
            continue
        entry = _dart_plugin_entry(plugin, info)
        if entry.dart_plugin_class:
            dart_plugins.append(entry)
    return dart_plugins

def collect_legacy_dart_plugins(plugins):
    """Collects entries by first platform with a `dartPluginClass`.

    Args:
        plugins: List of plugin structs.

    Returns:
        List of dart plugin entry structs.
    """
    dart_plugins = []
    for plugin in plugins:
        for _platform, info in plugin.platforms.items():
            entry = _dart_plugin_entry(plugin, info)
            if entry.dart_plugin_class:
                dart_plugins.append(entry)
                break
    return dart_plugins

def _platform_info(plugin, platform):
    """Return the platform dict for plugin on platform, or {}.

    Args:
        plugin: Plugin struct.
        platform: Target platform string.

    Returns:
        Platform dict or empty dict.
    """
    platforms = getattr(plugin, "platforms", None)
    if type(platforms) != "dict":
        return {}
    info = platforms.get(platform, {})
    return info if type(info) == "dict" else {}

def _collect_non_default_implementations(plugins, target_platform, umbrella_name, default_pkg):
    """Collect non-default implementations of umbrella_name for target_platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.
        umbrella_name: The umbrella package name being implemented.
        default_pkg: The default implementation package name.

    Returns:
        List of candidate plugin structs that implement umbrella_name.
    """
    candidates = []
    for p in plugins:
        if p.name == default_pkg:
            continue
        if getattr(p, "implements", "") != umbrella_name:
            continue
        if bool(_platform_info(p, target_platform)):
            candidates.append(p)
    return candidates

def _resolve_one_umbrella(plugin, plugins, target_platform):
    """Resolves any non-default implementation for a single umbrella plugin.

    Args:
        plugin: Umbrella plugin candidate struct.
        plugins: List of all plugin structs.
        target_platform: Target platform string.

    Returns:
        A struct(chosen, default_pkg) if a single non-default implementation exists, or None.
    """
    info = _platform_info(plugin, target_platform)
    default_pkg = info.get("default_package", "")
    if not default_pkg:
        return None

    non_default = _collect_non_default_implementations(
        plugins,
        target_platform,
        plugin.name,
        default_pkg,
    )
    if len(non_default) >= 2:
        names = ", ".join(sorted([c.name for c in non_default]))
        msg = 'flutter plugin registrant: "%s" has more than one implementation for %s (%s). Depend on one, or on the default "%s" only.' % (
            plugin.name,
            target_platform,
            names,
            default_pkg,
        )
        fail(msg)
    if len(non_default) == 1:
        return struct(chosen = non_default[0], default_pkg = default_pkg)
    return None

def _find_federated_resolution(plugins, target_platform):
    """Finds replacements and dropped defaults for federated plugins on target_platform.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform string.

    Returns:
        A struct with replacements, dropped_defaults, and chosen_names dicts.
    """
    replacements = {}
    dropped_defaults = {}
    chosen_names = {}

    for p in plugins:
        match = _resolve_one_umbrella(p, plugins, target_platform)
        if match:
            replacements[p.name] = match.chosen
            dropped_defaults[match.default_pkg] = True
            chosen_names[match.chosen.name] = True

    return struct(
        replacements = replacements,
        dropped_defaults = dropped_defaults,
        chosen_names = chosen_names,
    )

def _filter_resolved_plugins(plugins, replacements, dropped_defaults, chosen_names):
    """Applies federated replacements and drops to the plugin list.

    Args:
        plugins: List of plugin structs.
        replacements: Dict mapping umbrella plugin name to chosen replacement struct.
        dropped_defaults: Dict of default package names to drop.
        chosen_names: Dict of chosen package names.

    Returns:
        List of resolved plugin structs.
    """
    result = []
    seen_chosen = {}

    for p in plugins:
        if p.name in dropped_defaults:
            continue
        target = replacements.get(p.name, p)
        if target.name in chosen_names:
            if target.name not in seen_chosen:
                seen_chosen[target.name] = True
                result.append(target)
            continue
        result.append(p)

    return result

def resolve_federated_plugins(plugins, target_platform):
    """Resolve federated plugin implementations for the given platform.

    An umbrella plugin declaring a `default_package` for `target_platform`
    is replaced by an app-chosen implementation when one is present in
    `plugins`. If two or more non-default implementations are present for
    the same umbrella, fails closed. With no non-default implementation,
    the default implementation stays.

    Args:
        plugins: List of plugin structs.
        target_platform: Target platform name (e.g. 'android', 'ios').

    Returns:
        The resolved list of plugins with defaults replaced or dropped.
    """
    if not plugins or not target_platform:
        return plugins

    resolution = _find_federated_resolution(plugins, target_platform)
    if not resolution.replacements and not resolution.dropped_defaults:
        return plugins

    return _filter_resolved_plugins(
        plugins,
        resolution.replacements,
        resolution.dropped_defaults,
        resolution.chosen_names,
    )
