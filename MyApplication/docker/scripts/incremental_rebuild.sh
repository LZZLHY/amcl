#!/bin/bash
# 已退役：旧fake C++ ABI/nothrow旁路与split打包不符合当前真实ABI/完整运行时合同。
# 保留路径给旧调用者明确非零失败；历史实现保留在Git，不做构建、拷贝或打包副作用。
set -euo pipefail
cat >&2 <<'MESSAGE'
ERROR: docker/scripts/incremental_rebuild.sh is retired; no build or package was produced.
Use the normal managed AMCL build entry from the project checkout:
  python docker/project.py build --component jdk17
Select jdk8, jdk21 or jdk25 when appropriate. The normal entry reuses only a matching
registered workspace; changed inputs require an explicitly recorded fresh build.
See docs/guides/DOCKER_BUILD_LAYOUT.md. Do not use the retired fake ABI/split-package path.
MESSAGE
exit 2
