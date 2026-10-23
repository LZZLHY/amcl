# 生产 gl4es 的宿主语义/像素验收使用软件 GLES；镜像只包含工具，源码由固定 qa 服务只读挂载。
FROM amcl-qa-native:latest
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build git \
    libegl1-mesa-dev libgles2-mesa-dev libgl1-mesa-dri mesa-utils python3 \
    && rm -rf /var/lib/apt/lists/*
