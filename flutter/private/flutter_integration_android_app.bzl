"""Android app helpers for the `flutter_integration_test` macro.

Moved out of `flutter_integration_test.bzl` so iOS support can extend that
file without growing it.
"""

load("//flutter:android.bzl", "ANDROID_MIN_SDK_VERSION", "ANDROID_TARGET_SDK_VERSION")

def sanitize_android_package_segment(raw):
    """Sanitizes a string into a valid Java package identifier segment.

    Args:
      raw: The raw string to sanitize.

    Returns:
      The sanitized segment.
    """
    chars = []
    for c in raw.elems():
        if c.isalnum() or c == "_":
            chars.append(c.lower())
        else:
            chars.append("_")
    segment = "".join(chars)
    if not segment or segment[0].isdigit():
        segment = "app_" + segment
    return segment

def make_android_integration_manifest_lines(package_name, app_name):
    """Generates AndroidManifest.xml lines for an Android integration test APK.

    Args:
      package_name: The application package name.
      app_name: The application label.

    Returns:
      The manifest lines.
    """
    return [
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
        "    package=\"%s\">" % package_name,
        "    <uses-permission android:name=\"android.permission.INTERNET\"/>",
        "    <uses-sdk android:minSdkVersion=\"%s\" android:targetSdkVersion=\"%s\"/>" % (
            ANDROID_MIN_SDK_VERSION,
            ANDROID_TARGET_SDK_VERSION,
        ),
        "",
        "    <application",
        "        android:label=\"%s\"" % app_name,
        "        android:name=\"android.app.Application\"",
        "        android:hardwareAccelerated=\"true\">",
        "        <activity",
        "            android:name=\"io.flutter.embedding.android.FlutterActivity\"",
        "            android:exported=\"true\"",
        "            android:launchMode=\"singleTop\"",
        "            android:configChanges=\"orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode\"",
        "            android:hardwareAccelerated=\"true\"",
        "            android:windowSoftInputMode=\"adjustResize\"",
        "            android:theme=\"@android:style/Theme.Light.NoTitleBar\">",
        "            <intent-filter>",
        "                <action android:name=\"android.intent.action.MAIN\"/>",
        "                <category android:name=\"android.intent.category.LAUNCHER\"/>",
        "            </intent-filter>",
        "            <meta-data",
        "                android:name=\"io.flutter.embedding.android.NormalTheme\"",
        "                android:resource=\"@android:style/Theme.Light.NoTitleBar\"/>",
        "        </activity>",
        "",
        "        <meta-data",
        "            android:name=\"io.flutter.embedding.android.EnableImpeller\"",
        "            android:value=\"false\"/>",
        "        <meta-data",
        "            android:name=\"flutterEmbedding\"",
        "            android:value=\"2\"/>",
        "    </application>",
        "</manifest>",
        "",
    ]

ANDROID_APP_KWARG_KEYS = (
    "srcs",
    "main",
    "app_srcs",
    "assets",
    "shaders",
    "shader_includes",
    "require_sksl_shaders",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "profile",
    "language_version",
    "defines",
    "native_deps",
)
