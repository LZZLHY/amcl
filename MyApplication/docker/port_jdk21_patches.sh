#!/bin/bash
# 旧锚点生成器已退役：它会重置固定源树，并重新生成已证错误的协议补丁。
# 这里保留失败明确的兼容入口；不访问源树、不执行Git修改、不复制旧输出。
# 活动补丁由prebuilt/jdk/<major>/patches/series管理，在已核验的独占源树中
# 使用prepare_jdk_source.py和apply_jdk_patches.py重放，再运行协议守卫。
# 历史实现由Git历史及本轮外置原件保全，不能靠恢复旧生成器创建发布补丁。
set -euo pipefail
cat >&2 <<'MESSAGE'
RETIRED: this destructive patch generator is no longer a supported entry point.
Use the pinned source and the complete maintained series through the standard
AMCL builder. Author new patches in an isolated source tree and review the delta;
verify_jdk25_safepoint.py --major 17|21|25 must pass before building.
MESSAGE
if [[ "${1:-}" == "--help" ]]; then exit 0; fi
exit 2
