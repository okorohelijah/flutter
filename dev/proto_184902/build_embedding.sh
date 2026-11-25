#!/usr/bin/env bash
# Copyright 2014 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Compiles this branch's Android embedding (the Java half of the Flutter engine)
# and puts the result where the demo app in ./app looks for it.
#
# Why this is enough, without building the engine:
#   An Android Flutter app gets the engine as two downloads:
#     1. flutter_embedding_<mode>.jar  - the Java classes (FlutterActivity, FlutterView, ...)
#     2. x86_64_<mode>.jar and friends - the native library libflutter.so
#   This prototype changes only Java, and nothing that the native library calls
#   (no change to FlutterJNI). So it rebuilds download 1 from this branch's
#   sources and keeps download 2 as it is. A full engine build takes hours on
#   this machine; this takes about a minute.
#
# What it does:
#   1. Fetches the jars the embedding is compiled against (the same bundle the
#      engine build uses, at the version written in DEPS).
#   2. For each requested mode (debug, profile, release; default: all three):
#      generates io/flutter/BuildConfig.java with gen_android_buildconfig.py (the
#      checked-in io/flutter/BuildConfig.java sets every mode flag to false for
#      IDE support and would break FlutterLoader), picks the matching
#      debug/ or release/ FlutterEngineFlagsProviderImpl.java per BUILD.gn,
#      compiles every .java file with Java 8 source/target, and writes the jar
#      plus stock .pom into ./embedding_repo laid out as a Maven repository.
#      app/android/build.gradle.kts reads that folder.
#
# Needs: a JDK (JAVA_HOME), the Android SDK (ANDROID_HOME) with a platform of
# API 36 or newer, `cipd` (in depot_tools), and `./bin/flutter` to have run once.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_ROOT="$(cd "$HERE/../.." && pwd)"
EMBEDDING_SRC="$FLUTTER_ROOT/engine/src/flutter/shell/platform/android"
GEN_BUILDCONFIG="$FLUTTER_ROOT/engine/src/flutter/tools/gen_android_buildconfig.py"
WORK="$HERE/.build_embedding"
REPO="$HERE/embedding_repo"

JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-25-openjdk-amd64}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
CIPD="${CIPD:-$(command -v cipd || echo "$HOME/depot_tools/cipd")}"

MODES=("$@")
if [[ ${#MODES[@]} -eq 0 ]]; then
  MODES=(debug profile release)
fi

# The engine version Flutter downloads for this checkout. On a branch it is
# computed from the commit where the branch left master, so the Java edits on
# this branch do not change it.
ENGINE_VERSION="$(cat "$FLUTTER_ROOT/bin/cache/engine.stamp")"
echo "Engine version (stock native library): $ENGINE_VERSION"

# The newest Android platform installed, e.g. .../platforms/android-36/android.jar
ANDROID_JAR="${ANDROID_JAR:-$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar | sort -V | tail -1)}"
LAMBDA_STUBS="$(ls -d "$ANDROID_HOME"/build-tools/*/core-lambda-stubs.jar | sort -V | tail -1)"
echo "Compiling against: $ANDROID_JAR"

mkdir -p "$WORK"

# 1. The jars the embedding is compiled against.
DEPS_VERSION="$(python3 - "$FLUTTER_ROOT/DEPS" << 'EOF'
import re, sys
deps = open(sys.argv[1]).read()
print(re.search(r"'flutter/android/embedding_bundle',\s*'version': '([^']+)'", deps).group(1))
EOF
)"
"$CIPD" install flutter/android/embedding_bundle "$DEPS_VERSION" -root "$WORK/deps" > "$WORK/cipd.log" 2>&1
CLASSPATH="$(ls "$WORK"/deps/lib/*.jar | tr '\n' ':')$LAMBDA_STUBS"

# All embedding sources except the checked-in IDE stub BuildConfig.java.
(cd "$EMBEDDING_SRC" && python3 - > "$WORK/sources_base.txt" << 'EOF'
import os
for directory, _, files in os.walk('io'):
    for name in sorted(files):
        rel = os.path.join(directory, name)
        if name.endswith('.java') and rel != 'io/flutter/BuildConfig.java':
            print(rel)
EOF
)

# 2. Fetch stock jars and compile once per mode so javac inlines the right BuildConfig constants.
STOCK="$WORK/stock/$ENGINE_VERSION"
mkdir -p "$STOCK"
for mode in "${MODES[@]}"; do
  name="flutter_embedding_$mode-1.0.0-$ENGINE_VERSION"
  for ext in jar pom; do
    [[ -s "$STOCK/$name.$ext" ]] || curl --fail --silent --show-error -o "$STOCK/$name.$ext" \
      "https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_$mode/1.0.0-$ENGINE_VERSION/$name.$ext"
  done

  if [[ "$mode" == "release" || "$mode" == "jit_release" ]]; then
    flags_src="release/io/flutter/embedding/engine/flags/FlutterEngineFlagsProviderImpl.java"
  else
    flags_src="debug/io/flutter/embedding/engine/flags/FlutterEngineFlagsProviderImpl.java"
  fi

  gen_dir="$WORK/gen/$mode"
  classes_dir="$WORK/classes/$mode"
  mkdir -p "$gen_dir/io/flutter"
  rm -rf "$classes_dir" && mkdir -p "$classes_dir"
  python3 "$GEN_BUILDCONFIG" --runtime-mode "$mode" --out "$gen_dir/io/flutter/BuildConfig.java"

  echo "[$mode] Compiling $(wc -l < "$WORK/sources_base.txt") + 2 Java files ..."
  (cd "$EMBEDDING_SRC" && "$JAVA_HOME/bin/javac" \
    -source 8 -target 8 -g -nowarn -Xlint:-options \
    -bootclasspath "$ANDROID_JAR" \
    -classpath "$CLASSPATH" \
    -d "$classes_dir" \
    "$gen_dir/io/flutter/BuildConfig.java" "$flags_src" @"$WORK/sources_base.txt")

  out="$REPO/io/flutter/flutter_embedding_$mode/1.0.0-$ENGINE_VERSION"
  mkdir -p "$out"
  cp "$STOCK/$name.jar" "$out/$name.jar"
  cp "$STOCK/$name.pom" "$out/$name.pom"
  "$JAVA_HOME/bin/jar" uf "$out/$name.jar" -C "$classes_dir" .
done

echo "Done: $REPO"
echo "Check: the debug jar must contain the new class."
"$JAVA_HOME/bin/jar" tf "$REPO/io/flutter/flutter_embedding_debug/1.0.0-$ENGINE_VERSION/flutter_embedding_debug-1.0.0-$ENGINE_VERSION.jar" \
  | grep -F 'io/flutter/plugin/editing/SystemContextMenuPlugin.class' || true
