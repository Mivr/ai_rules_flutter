#!/usr/bin/env bash
# The Dart build must stay green while the Android path fails closed.
set -euo pipefail

bazel build //:app

set +e
out=$(bazel fetch @deps//android:all_android_plugin_libs 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "expected the Android plugin fetch to fail, but it succeeded"
  echo "$out"
  exit 1
fi

# Analysing the aggregator also needs the Android SDK, so on a host without
# it (or with a partial one) the toolchain refusal can come before the model
# is read. Whenever the aggregator step above did not reach the plugin's own
# refusal, fetch that repository alone: its fetch reads the Gradle model and
# fails on the coordinate without needing the Android SDK at all.
if ! grep -Fq 'com.example:lazy-unmapped' <<<"$out"; then
  set +e
  out=$(bazel fetch @deps-android-lazy_plugin//android:lib 2>&1)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "expected the plugin's Android repository fetch to fail, but it succeeded"
    echo "$out"
    exit 1
  fi
fi

# The reader reports the `group:artifact` key it could not map, so the
# versioned declaration in the fixture surfaces as `com.example:lazy-unmapped`.
if ! grep -Fq 'com.example:lazy-unmapped:1.0' lazy_plugin/android/build.gradle; then
  echo "fixture lost the unmapped coordinate"
  exit 1
fi
for needle in \
  'lazy_plugin' \
  'android/build.gradle' \
  'declares Android dependencies rules_flutter cannot translate to Bazel labels' \
  'com.example:lazy-unmapped'; do
  if ! grep -Fq "$needle" <<<"$out"; then
    echo "Android fetch failed without the expected diagnostic: $needle"
    echo "$out"
    exit 1
  fi
done

echo "ok: Dart build skipped the Gradle model; the Android path refused the unmapped coordinate"
