#!/bin/bash
# sync_prebuilt.sh — 从 prebuilt/ 同步产物到 entry/ 部署位置
#
# 用法：cd MyApplication && ./scripts/sync_prebuilt.sh
#
# 同步规则（2026-05-15 P0/P0.3/P4 后）：
#   prebuilt/jna/*.so               → entry/libs/arm64-v8a/         （死冻）
#   prebuilt/stubs/*.so             → entry/libs/arm64-v8a/         （死冻）
#   prebuilt/lwjgl3/jars/*.jar      → entry/src/main/resources/rawfile/lwjgl/   （上游 jar 由 setup_deps.sh 拉，本步只是把它们 sync 到 rawfile）
#   prebuilt/stubs/*.jar            → entry/src/main/resources/rawfile/         （死冻）
#
# ⚠️ 不再同步以下产物（已 .gitignore，由 amcl-prebuilts Release 或 hvigor preBuild 提供）：
#   prebuilt/lwjgl3/natives/*.so    → entry/libs/arm64-v8a/         （P7 后从 amcl-prebuilts Release 拉）
#   prebuilt/jdk/17/natives/*.so    → entry/libs/arm64-v8a/         （JDK 走 mc-ohos-resources Release，用户运行时下载到 filesDir）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PREBUILT="$ROOT_DIR/prebuilt"
LIBS_DIR="$ROOT_DIR/entry/libs/arm64-v8a"
RAWFILE_LWJGL="$ROOT_DIR/entry/src/main/resources/rawfile/lwjgl"
RAWFILE_ROOT="$ROOT_DIR/entry/src/main/resources/rawfile"

echo "=== sync_prebuilt.sh ==="
echo "Source:  $PREBUILT"
echo "Target:  $LIBS_DIR (so) / $RAWFILE_LWJGL (jar)"
echo ""

mkdir -p "$LIBS_DIR" "$RAWFILE_LWJGL" "$RAWFILE_ROOT" "$RAWFILE_ROOT/lwjgl-3.2.3"

copied=0
skipped=0

sync_files() {
    local src_dir="$1"
    local dst_dir="$2"
    local ext="$3"
    local label="$4"

    [ -d "$src_dir" ] || return 0

    for f in "$src_dir"/*."$ext"; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f")
        local dst="$dst_dir/$name"
        if [ "$f" -nt "$dst" ] 2>/dev/null || [ ! -f "$dst" ]; then
            cp "$f" "$dst"
            echo "  [$label] $name"
            copied=$((copied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
}

# .so 文件（死冻类）
sync_files "$PREBUILT/jna"             "$LIBS_DIR" "so" "JNA"
sync_files "$PREBUILT/stubs"           "$LIBS_DIR" "so" "STUBS"

# .jar 文件
sync_files "$PREBUILT/lwjgl3/jars"     "$RAWFILE_LWJGL" "jar" "LWJGL3-JAR"
# LWJGL 322 套（3.2.3，方案 C 多版本）：MC 1.13–1.18.2 用。jar 已在 prebuilt 阶段改名+注入桥接
# （见 docker/build_lwjgl322_jars.sh），这里只同步到独立 rawfile 目录 lwjgl-3.2.3/。
sync_files "$PREBUILT/lwjgl3/3.2.3/jars" "$RAWFILE_ROOT/lwjgl-3.2.3" "jar" "LWJGL322-JAR"
sync_files "$PREBUILT/stubs"           "$RAWFILE_ROOT"   "jar" "STUBS-JAR"

# LWJGL jar 根 module-info 补丁（幂等）。
#   docker 构建的 LWJGL 3.4.1 jar 是 multi-release，module-info 只在
#   META-INF/versions/11|25/。旧 Forge（1.20.x 及更早）的 cpw BootstrapLauncher +
#   securejarhandler 2.1.x 读不到 → org.lwjgl 模块命名失败 → 闪退。
#   这里给每个 jar 补一个根 module-info.class（已有则跳过）。
#   详见 docs/reports/forge-lwjgl-root-module-info-202606.md
if command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Patching LWJGL jars: ensure root module-info.class (old-Forge module resolution) ==="
  python3 "$ROOT_DIR/scripts/patch-lwjgl-module-info.py" "$RAWFILE_LWJGL" "$PREBUILT/lwjgl3/jars" "$RAWFILE_ROOT/lwjgl-3.2.3" "$PREBUILT/lwjgl3/3.2.3/jars" || \
    echo "  WARN: patch-lwjgl-module-info.py failed; old Forge (1.20.x) may crash with 'Module org.lwjgl not found'"

  # LWJGL ModulePackages 补丁（幂等）。
  #   LWJGL 3.4.1 的 versions/25/module-info【没有 ModulePackages 属性】，隐藏包
  #   org.lwjgl.system.ffm.mapping（仅在 versions/25，未导出）因此不属于模块。NeoForge 的
  #   cpw securejarhandler 不像标准 JDK 那样扫描 jar 补全隐藏包 → 在 JDK 25 上跑现代 MC 时
  #   org.lwjgl.system.JNI.<clinit> → FFM.<clinit> → NoClassDefFoundError: ffm/mapping/Mapping
  #   → 渲染线程闪退（Fabric 走 classpath 不校验包归属，故仅 NeoForge/Forge 受影响）。
  #   这里给 core lwjgl.jar 的每个 module-info 补一个【完整 ModulePackages】（缺啥补啥）。
  #   详见 docs/reports/lwjgl-ffm-modulepackages-202606.md
  echo ""
  echo "=== Patching LWJGL core jar: complete ModulePackages (NeoForge FFM on JDK 25) ==="
  python3 "$ROOT_DIR/scripts/patch-lwjgl-modulepackages.py" "$RAWFILE_LWJGL/lwjgl.jar" "$PREBUILT/lwjgl3/jars/lwjgl.jar" || \
    echo "  WARN: patch-lwjgl-modulepackages.py failed; NeoForge/Forge on JDK 25 may crash with NoClassDefFoundError: ffm/mapping/Mapping"
else
  echo "  WARN: python3 not found; skipped LWJGL module-info patches (old Forge 1.20.x / NeoForge-on-JDK25 may crash)."
fi

# LWJGL *Stack 回填（幂等）。
#   MC 1.13–1.19.x 字节码调 GLFWImage.mallocStack 等（3.3.1 后被 LWJGL 移除）；我们 341 套是
#   3.4.1，缺这些方法 → NoSuchMethodError 启动崩（典型 ATM8 / MC 1.19.2 Window.setIcon）。
#   给每个带现代 stack 分配器的 Struct 类字节码注入回 *Stack 委托方法（已有则跳过）。
#   详见 scripts/lwjgl-stack-backfill/README.md。注：只回填 341 套（rawfile/lwjgl + prebuilt/lwjgl3/jars）；
#   322 套本身是 3.2.3，自带 *Stack，无需处理。
if command -v node >/dev/null 2>&1; then
  echo ""
  echo "=== Backfilling LWJGL *Stack methods (mallocStack/callocStack for MC 1.13-1.19) ==="
  node "$ROOT_DIR/scripts/lwjgl-stack-backfill/apply.mjs" "$RAWFILE_LWJGL" "$PREBUILT/lwjgl3/jars" || \
    echo "  WARN: lwjgl-stack-backfill failed; MC 1.13-1.19 may crash with NoSuchMethodError: *.mallocStack"
else
  echo "  WARN: node not found; skipped LWJGL *Stack backfill (MC 1.13-1.19 may crash on mallocStack)."
fi

echo ""
echo "=== Done: $copied copied, $skipped up-to-date ==="
echo ""
echo "Notes:"
echo "  • LWJGL natives / curl / fontconfig are NOT synced here anymore (see header)."
echo "  • If liblwjgl*.so / libcurl.so are missing in $LIBS_DIR after a fresh clone,"
echo "    run 'bash setup_deps.sh' (P7 阶段后会从 amcl-prebuilts Release 自动拉)."
