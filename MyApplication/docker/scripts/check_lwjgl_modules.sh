#!/bin/bash
for mod in core opengl stb tinyfd glfw jemalloc openal; do
    echo "=== $mod ==="
    mc=$(find /build/lwjgl3-official/modules/lwjgl/$mod/src/main/c -name '*.c' 2>/dev/null | grep -v windows | grep -v macos | wc -l)
    gc=$(find /build/lwjgl3-official/modules/lwjgl/$mod/src/generated/c -name '*.c' 2>/dev/null | grep -v windows | grep -v macos | wc -l)
    mj=$(find /build/lwjgl3-official/modules/lwjgl/$mod/src/main/java -name '*.java' 2>/dev/null | wc -l)
    gj=$(find /build/lwjgl3-official/modules/lwjgl/$mod/src/generated/java -name '*.java' 2>/dev/null | wc -l)
    echo "  C: main=$mc gen=$gc  Java: main=$mj gen=$gj"
done
