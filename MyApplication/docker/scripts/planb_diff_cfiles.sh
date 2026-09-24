#!/bin/bash
# Compare generated C file sets between two LWJGL clones (catch glob breakage).
set -u
R333=/build/lwjgl3/modules/lwjgl
R341=/build/lwjgl3-341/modules/lwjgl
for mod in core/src/main/c core/src/generated/c core/src/generated/c/linux opengl/src/generated/c stb/src/generated/c tinyfd/src/generated/c; do
  echo "=== diff $mod ==="
  a=$(cd "$R333/$mod" 2>/dev/null && ls *.c 2>/dev/null | sort)
  b=$(cd "$R341/$mod" 2>/dev/null && ls *.c 2>/dev/null | sort)
  if diff <(echo "$a") <(echo "$b") >/tmp/d.txt; then
    echo "  (identical: $(echo "$b" | grep -c . ) files)"
  else
    echo "  CHANGED (< = only in 3.3.3, > = only in 3.4.1):"
    cat /tmp/d.txt
  fi
done
