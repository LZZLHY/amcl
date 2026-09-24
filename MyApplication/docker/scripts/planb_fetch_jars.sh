#!/bin/bash
# planb_fetch_jars.sh — fetch LWJGL 3.4.1 upstream jars + compute sha256
# Runs inside ohos-debug container (has network + JDK).
# Output: /build/planb/jars/*.jar  + prints deps.lock-ready sha256 lines.
set -euo pipefail

VER="${1:-3.4.1}"
BASE=https://repo1.maven.org/maven2/org/lwjgl
OUT=/build/planb/jars
mkdir -p "$OUT"

# 9 runtime classpath modules (order matches deps.lock [lwjgl-jars].modules)
MODULES=(lwjgl lwjgl-opengl lwjgl-stb lwjgl-tinyfd lwjgl-jemalloc lwjgl-openal lwjgl-vulkan lwjgl-egl lwjgl-opengles)

echo "=== Fetching LWJGL $VER jars to $OUT ==="
for m in "${MODULES[@]}"; do
  url="$BASE/$m/$VER/$m-$VER.jar"
  dst="$OUT/$m.jar"
  curl -fsSL -m 120 -o "$dst" "$url"
  echo "  fetched $m-$VER.jar ($(stat -c%s "$dst") bytes)"
done

# Plan B also needs the CLEAN upstream glfw jar (original GLFW.class) as baseline.
curl -fsSL -m 120 -o "$OUT/lwjgl-glfw.jar" "$BASE/lwjgl-glfw/$VER/lwjgl-glfw-$VER.jar"
echo "  fetched lwjgl-glfw-$VER.jar (clean baseline) ($(stat -c%s "$OUT/lwjgl-glfw.jar") bytes)"

echo ""
echo "=== deps.lock [lwjgl-jars] sha256 lines (copy into deps.lock) ==="
sha_line() { printf '%-22s = %s\n' "$1" "$(sha256sum "$2" | cut -d' ' -f1)"; }
sha_line "lwjgl_sha256"          "$OUT/lwjgl.jar"
sha_line "lwjgl-opengl_sha256"   "$OUT/lwjgl-opengl.jar"
sha_line "lwjgl-stb_sha256"      "$OUT/lwjgl-stb.jar"
sha_line "lwjgl-tinyfd_sha256"   "$OUT/lwjgl-tinyfd.jar"
sha_line "lwjgl-jemalloc_sha256" "$OUT/lwjgl-jemalloc.jar"
sha_line "lwjgl-openal_sha256"   "$OUT/lwjgl-openal.jar"
sha_line "lwjgl-vulkan_sha256"   "$OUT/lwjgl-vulkan.jar"
sha_line "lwjgl-egl_sha256"      "$OUT/lwjgl-egl.jar"
sha_line "lwjgl-opengles_sha256" "$OUT/lwjgl-opengles.jar"
echo ""
echo "=== core jar manifest version (sanity) ==="
unzip -p "$OUT/lwjgl.jar" META-INF/MANIFEST.MF | grep -iE 'Specification-Version|Implementation-Version' || true
