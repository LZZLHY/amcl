#!/bin/bash
# planb_fetch_extra_jars.sh — fetch the MC 26.2 newly-required LWJGL module jars
# (freetype + shaderc + spvc + vma) + compute sha256 for deps.lock.
set -euo pipefail
VER="${1:-3.4.1}"
BASE=https://repo1.maven.org/maven2/org/lwjgl
OUT=/build/planb/jars
mkdir -p "$OUT"
MODULES=(lwjgl-freetype lwjgl-shaderc lwjgl-spvc lwjgl-vma)
echo "=== Fetching LWJGL $VER extra module jars ==="
for m in "${MODULES[@]}"; do
  curl -fsSL -m 120 -o "$OUT/$m.jar" "$BASE/$m/$VER/$m-$VER.jar"
  echo "  fetched $m-$VER.jar ($(stat -c%s "$OUT/$m.jar") bytes)"
done
echo ""
echo "=== deps.lock sha256 lines ==="
for m in "${MODULES[@]}"; do
  printf '%-22s = %s\n' "${m}_sha256" "$(sha256sum "$OUT/$m.jar" | cut -d' ' -f1)"
done
