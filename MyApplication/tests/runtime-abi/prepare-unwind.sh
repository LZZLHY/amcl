#!/bin/bash
# 输入归档由 host git archive 固定 commit，补丁与来源同时冻结；所有改动只在输出树。
set -euo pipefail
mkdir /output/unwind-source
tar -xf /unwind-input/source.tar -C /output/unwind-source
cd /output/unwind-source
git apply --check /unwind-input/0001-checked-fde-registration.patch
git apply /unwind-input/0001-checked-fde-registration.patch
cp /unwind-input/amcl_unwind_image.h libunwind/src/
cp /unwind-input/amcl_unwind_images.hpp libunwind/src/
sha256sum /unwind-input/* > /output/unwind-inputs.sha256
