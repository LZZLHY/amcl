# 仅用于 AArch64 用户态回归；执行生产 loader，不替代 OHOS 系统 namespace 验收。
FROM amcl-qa-native:latest
RUN apt-get update && apt-get install -y --no-install-recommends qemu-user g++-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
