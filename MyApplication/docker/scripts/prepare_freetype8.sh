#!/bin/bash
# JDK8 的头文件和运行库来自同一个固定 FreeType 源码；不用旧容器中的预编译副本。
# 源码身份变化拒绝复用，失败保留独占工作卷供定位；输出由完整 JDK 打包器再验依赖。
set -euo pipefail
root=/build/freetype-2.13.3
readarray -t inputs < <(python3 -c 'import json; x=json.load(open("/prebuilt/jdk/build-inputs.json"))["runtimes"]["8"]["freetype"]; print(x["repository"]); print(x["commit"])')
if [ ! -e "$root" ]; then
    mkdir "$root"; git -C "$root" init
    git -C "$root" remote add origin "${inputs[0]}"
    git -C "$root" fetch --depth=1 origin "${inputs[1]}"
    git -C "$root" checkout --detach FETCH_HEAD
fi
[ "$(git -C "$root" remote get-url origin)" = "${inputs[0]}" ]
[ "$(git -C "$root" rev-parse HEAD)" = "${inputs[1]}" ]
# autogen 的产物被 Git 忽略；正式输入的本地改动禁止混入增量构建。
git -C "$root" diff --exit-code HEAD
cd "$root"
./autogen.sh
CC=/ohos-toolchain/aarch64-linux-ohos-gcc \
  bash ./configure --host=aarch64-linux-musl --prefix=/usr --enable-shared --disable-static \
    --without-harfbuzz --without-png --without-brotli --without-bzip2 --without-zlib --with-old-mac-fonts=no
make -j"${JOBS:-4}"
test -s objs/.libs/libfreetype.so
python3 - <<'PY'
# 收据记录真实提交和最终库，不以版本字符串替代输入/输出身份。
import hashlib, json, subprocess
from pathlib import Path
p = Path('/build/freetype-2.13.3')
result = {'head': subprocess.check_output(['git','-C',str(p),'rev-parse','HEAD'],text=True).strip(),
          'librarySha256': hashlib.sha256((p/'objs/.libs/libfreetype.so').read_bytes()).hexdigest()}
Path('/build/freetype-build-identity.json').write_text(json.dumps(result,indent=2)+'\n')
PY
