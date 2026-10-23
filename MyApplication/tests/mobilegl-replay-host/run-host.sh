#!/usr/bin/env bash
# 固定qa明确套件：源/实际旧制品/ICD readonly，结果写本次唯一仓外output。
set -euo pipefail
args=(--source /mobilegl-source --output /output/mobilegl-replay --expected-source "${AMCL_MOBILEGL_SOURCE_COMMIT:?}")
if test -d /mobilegl-artifacts; then args+=(--artifacts /mobilegl-artifacts --artifact-proof-sha "${AMCL_MOBILEGL_ARTIFACT_PROOF_SHA:?}"); fi
if test -d /mobilegl-icd; then args+=(--icd /mobilegl-icd/lvp-runtime.json --icd-source /mobilegl-icd/libvulkan_lvp.so); fi
exec python3 -B /workspace/tests/mobilegl-replay-host/run-host.py "${args[@]}" "$@"
