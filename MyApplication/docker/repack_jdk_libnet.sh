#!/bin/bash
# ============================================================
#  repack_jdk_libnet.sh — 把一个已发布的 JDK zip「只替换 libnet.so」重打成新资产
#
#  用途：IPv6 沙箱回落 patch（prebuilt/jdk/<v>/patches/0010）只改 libnet 一个编译单元，
#  没必要重传整份 JDK 的构建产物。本脚本把「最小替换」这条纪律机器化，并把
#  2026-08-29 现场踩到的两个坑固化成判据（见下面 ⛔ 两段）。
#
#  用法（容器内，工作目录任选）：
#    bash repack_jdk_libnet.sh <ver> <origZip> <newZip> <patchedLibnet> <nParts>
#  例：
#    bash repack_jdk_libnet.sh 8 jdk8-ohos-full.zip jdk8-ohos-full-v4.zip \
#         /out/jdk8/libnet.so.new 2
#
#  会做七件事（任何一步不符即非零退出）：
#    1) 解压原包 → 树 A
#    2) 复制成树 B，只把 libnet.so 换成 patched 那份
#    3) 逐条比对 A vs B：文件清单必须完全一致，且**除 libnet.so 外**每个文件 sha256 相同
#    4) 由 B 重新打包 → 再解压 → 树 C，逐条比对 B vs C（证明打包过程没改内容）
#    5) zip 中央目录级核对：条目名清单 / 目录条目数 / 符号链接数
#    6) 切 nParts 个等大分卷（Gitee 单文件 ≤100MB 且不支持 Range）
#    7) 分卷按序拼回，与整包 sha256 比对（模拟 JdkInstaller.concatParts）
#
#  最后打印要**逐字填进四处 SoT** 的数字：
#    launch/src/main/ets/JdkManager.ets 的 JDK_VERSIONS[<v>]（tag/dataFile/sha256/sizeBytes/
#      giteeParts/giteePartSizes）、commons/.../Constants.ets 的 *_RELEASE_TAG/ASSET（若该版本有）、
#      deps.lock 的 [mc-ohos-resources-<v>]、prebuilt/jdk/<v>/README.md
#    填完跑 `node scripts/check-jdk-release-pin.mjs` 兜一遍。
# ============================================================
set -e

VER="$1"; ORIG="$2"; NEW="$3"; LIBNET="$4"; NPARTS="${5:-0}"
if [ -z "$VER" ] || [ -z "$ORIG" ] || [ -z "$NEW" ] || [ -z "$LIBNET" ]; then
  echo "usage: repack_jdk_libnet.sh <ver> <origZip> <newZip> <patchedLibnet> [nParts]"; exit 2
fi
[ -f "$ORIG" ] || { echo "❌ 原包不存在: $ORIG"; exit 1; }
[ -f "$LIBNET" ] || { echo "❌ patched libnet 不存在: $LIBNET"; exit 1; }

ORIG=$(readlink -f "$ORIG")
LIBNET=$(readlink -f "$LIBNET")
WORKROOT=${WORKROOT:-$(dirname "$ORIG")}
NEWPATH="$WORKROOT/$(basename "$NEW")"
W="$WORKROOT/w$VER"
rm -rf "$W"; mkdir -p "$W/a" "$W/b" "$W/c"

echo "=== [1] 解压原包 ==="
unzip -q "$ORIG" -d "$W/a"
echo "  文件数 $(find "$W/a" -type f | wc -l)"
# libnet.so 的位置：模块化布局（9+）在 lib/，经典布局（8）在 jre/lib/aarch64/
REL=lib/libnet.so
[ -f "$W/a/$REL" ] || REL=jre/lib/aarch64/libnet.so
[ -f "$W/a/$REL" ] || { echo "❌ 原包里找不到 libnet.so"; exit 1; }
echo "  libnet 位置 $REL  $(stat -c %s "$W/a/$REL") bytes"

echo "=== [2] 复制并替换 ==="
cp -a "$W/a/." "$W/b/"
cp "$LIBNET" "$W/b/$REL"
# ⛔ 坑四（确定性的真正来源）：`cp` 会把新文件的 mtime 设成"现在"，且写入动作还会把
#   **父目录**的 mtime 改成"现在"。zip 把 mtime 存进条目头 ⇒ 每次重打这两处时间戳都不同
#   ⇒ 整包 sha256 每次都不同（size 一样，就差这几个字节）。把两处 mtime 还原成原包里的值：
#   既让重打包可复现，也让「除内容外什么都没变」这句话字面成立。
touch -r "$W/a/$REL" "$W/b/$REL"
touch -r "$W/a/$(dirname "$REL")" "$W/b/$(dirname "$REL")"
echo "  新 libnet $(stat -c %s "$W/b/$REL") bytes（mtime 已对齐原包）"

echo "=== [3] 逐条比对 A vs B（除 libnet.so 外必须全同）==="
( cd "$W/a" && find . -type f | sort ) > "$W/list.a"
( cd "$W/b" && find . -type f | sort ) > "$W/list.b"
diff -q "$W/list.a" "$W/list.b" > /dev/null \
  || { echo "❌ 文件清单不一致:"; diff "$W/list.a" "$W/list.b" | head -10; exit 1; }
echo "  文件清单一致（$(wc -l < "$W/list.a") 个）"
( cd "$W/a" && xargs -a "$W/list.a" -d '\n' sha256sum ) | sort -k2 > "$W/sum.a"
( cd "$W/b" && xargs -a "$W/list.b" -d '\n' sha256sum ) | sort -k2 > "$W/sum.b"
DIFFS=$(diff "$W/sum.a" "$W/sum.b" | grep '^[<>]' | awk '{print $3}' | sort -u)
[ "$DIFFS" = "./$REL" ] \
  || { echo "❌ 差异不止 libnet.so:"; echo "$DIFFS" | head -10; exit 1; }
echo "  ⇒ 唯一差异就是 $REL ✅"

echo "=== [4] 重新打包 ==="
rm -f "$NEWPATH"
# ⛔ 坑一：目录条目策略必须**照抄原包**，而判据只能看**条目名是否以 / 结尾**。
#   zip 规范里目录条目的唯一可靠标志就是尾随斜杠；`unzip -Z` 权限列的首字符 `d` 取决于打包工具
#   写了什么 external attributes。实测：17/21/25 的原包是 `3.0 unx`（目录显示 drwxr-xr-x，`^d` 能命中），
#   而 **JDK 8 的原包是 `2.0 fat`（DOS 属性），连目录条目也显示 `-rw----`** ⇒ 按 `^d` 数出来是 0
#   ⇒ 误判"原包无目录条目"→ 错加 -D → 新包凭空少 17 个目录条目。
#   （17 的原包确实一个目录条目都没有，72 条全是文件，所以 -D 这条分支是真需要的。）
#   ⇒ AGENTS.md §二.8：判定"产物里有没有某样东西"的工具，先在已知含有它的样本上验证过。
ORIG_DIRS=$(unzip -Z1 "$ORIG" | grep -c '/$' || true)
# ⛔ 坑三：`zip -r <dir>` 的条目顺序跟着 readdir 走，**同一份内容重打两次会得到不同字节**
#   （实测：size 完全相同、每个条目内容相同，但整包 sha256 不同 ⇒ 差异只是条目排列）。
#   后果不是"包坏了"，而是"这个包没法被第三方复现"——而 libnet.so 本身是位级可复现的，
#   没道理让外层 zip 把这个性质丢掉。⇒ 显式给出**LC_ALL=C 排序**的条目清单，用 `-@` 从
#   stdin 喂给 zip，顺序就定死了。`-@` 下 zip 不会自作主张加目录条目，所以目录条目
#   （若原包有）要自己列进清单，`-D` 也就不需要了。
if [ "$ORIG_DIRS" = "0" ]; then
  echo "  原包无目录条目 ⇒ 清单只列文件"
  ( cd "$W/b" && find . -mindepth 1 -type f -print )        | LC_ALL=C sort > "$W/ziplist"
else
  echo "  原包有 $ORIG_DIRS 个目录条目 ⇒ 清单含目录条目"
  ( cd "$W/b" && find . -mindepth 1 -type d -printf '%p/\n' -o -type f -print ) \
                                                            | LC_ALL=C sort > "$W/ziplist"
fi
echo "  打包清单 $(wc -l < "$W/ziplist") 条（已按 LC_ALL=C 排序，顺序确定）"
# -X 不存 uid/gid/时间的扩展字段；-9 与原包压缩级别未必相同，
# 但下一步会证明**解压内容**逐字节一致 —— 那才是要保的东西。
( cd "$W/b" && zip -q -X -9 -@ "$NEWPATH" < "$W/ziplist" )
echo "  $(basename "$NEWPATH") $(stat -c %s "$NEWPATH") bytes"

echo "  解压新包 → 树 C，逐条比对 B vs C"
unzip -q "$NEWPATH" -d "$W/c"
( cd "$W/c" && find . -type f | sort ) > "$W/list.c"
diff -q "$W/list.b" "$W/list.c" > /dev/null \
  || { echo "❌ 新包清单与 B 不一致:"; diff "$W/list.b" "$W/list.c" | head -10; exit 1; }
( cd "$W/c" && xargs -a "$W/list.c" -d '\n' sha256sum ) | sort -k2 > "$W/sum.c"
diff -q "$W/sum.b" "$W/sum.c" > /dev/null \
  || { echo "❌ 新包内容与 B 不一致:"; diff "$W/sum.b" "$W/sum.c" | head -10; exit 1; }
echo "  ⇒ 新包解压内容与 B 逐条相同 ✅"

echo "=== [5] zip 中央目录级核对（补 find -type f 漏掉的符号链接与空目录）==="
# ⛔ 坑二：这一步以前只打一行 ⚠️ 然后返回 0 ⇒ JDK 8 少 17 个目录条目一路跑到切分卷都没被拦住。
#   一个只会 warn 的门禁比没有门禁更糟。这里一律以非零退出。
unzip -Z1 "$ORIG"    | sort > "$W/e.orig"
unzip -Z1 "$NEWPATH" | sort > "$W/e.new"
if diff -q "$W/e.orig" "$W/e.new" > /dev/null; then
  echo "  条目名清单完全一致（$(wc -l < "$W/e.orig") 条）✅"
else
  echo "  ❌ 条目名有差异（< 只在原包，> 只在新包）:"; diff "$W/e.orig" "$W/e.new" | head -20; exit 1
fi
ND=$(unzip -Z1 "$NEWPATH" | grep -c '/$' || true)
[ "$ORIG_DIRS" = "$ND" ] || { echo "  ❌ 目录条目数 $ORIG_DIRS → $ND"; exit 1; }
OL=$(unzip -Z "$ORIG"    | grep -c '^l' || true)
NL=$(unzip -Z "$NEWPATH" | grep -c '^l' || true)
[ "$OL" = "$NL" ] || { echo "  ❌ 符号链接数 $OL → $NL"; exit 1; }
echo "  目录条目 $ORIG_DIRS 一致 / 符号链接 $OL 一致 ✅"

NEW_SHA=$(sha256sum "$NEWPATH" | cut -d' ' -f1)
NEW_SIZE=$(stat -c %s "$NEWPATH")

if [ "$NPARTS" -gt 1 ] 2>/dev/null; then
  echo "=== [6] 切 $NPARTS 个等大分卷 ==="
  rm -f "$NEWPATH".part*
  # GNU split -n 按字节均分成 N 份（最后一份吸收余数），与既有分卷形状一致
  split -n "$NPARTS" -d --numeric-suffixes=1 "$NEWPATH" "$NEWPATH.__p"
  i=1; SUM=0; SIZES=""
  MM=$(printf '%02d' "$NPARTS")
  for f in "$NEWPATH".__p*; do
    NN=$(printf '%02d' "$i")
    DEST="$NEWPATH.part${NN}of${MM}"
    mv "$f" "$DEST"
    S=$(stat -c %s "$DEST")
    SUM=$((SUM + S)); SIZES="$SIZES $S,"
    printf '  %s  %s bytes\n' "$(basename "$DEST")" "$S"
    i=$((i + 1))
  done
  [ "$SUM" = "$NEW_SIZE" ] || { echo "  ❌ 各卷之和 $SUM ≠ 整包 $NEW_SIZE"; exit 1; }
  echo "  各卷之和 = 整包 $NEW_SIZE ✅"

  echo "=== [7] 分卷按序拼回，与整包 sha256 比对 ==="
  cat "$NEWPATH".part*of${MM} > "$W/recombined"
  RC_SHA=$(sha256sum "$W/recombined" | cut -d' ' -f1)
  rm -f "$W/recombined"
  [ "$RC_SHA" = "$NEW_SHA" ] || { echo "  ❌ 拼回 sha=$RC_SHA ≠ 整包 sha=$NEW_SHA"; exit 1; }
  echo "  拼回结果与整包逐字节一致 ✅"
  PARTS_LINE="  giteeParts     = [$(cd "$WORKROOT" && ls "$(basename "$NEWPATH")".part*of${MM} | sed "s/.*/'&'/" | paste -sd, - )]"
  SIZES_LINE="  giteePartSizes = [$(echo "$SIZES" | sed 's/,$//' | sed 's/^ //')]"
else
  echo "=== [6/7] 未要求分卷（nParts=$NPARTS），跳过 ==="
  PARTS_LINE="  giteeParts     = （未切分卷）"
  SIZES_LINE=""
fi

rm -rf "$W/a" "$W/c"
echo ""
echo "=== 要逐字填进四处 SoT 的数字 ==="
echo "  asset          = $(basename "$NEWPATH")"
echo "  sizeBytes      = $NEW_SIZE"
echo "  sha256         = $NEW_SHA"
echo "$PARTS_LINE"
[ -n "$SIZES_LINE" ] && echo "$SIZES_LINE"
echo ""
echo "填完务必跑：node scripts/check-jdk-release-pin.mjs"
echo "发布顺序：**先** JDK Release（新 tag，旧 tag 与附件一个都不动）**再** 发 HAP。"
