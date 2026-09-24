# OpenAL Soft — OHAudio 后端

本目录包含 OpenAL Soft 的构建配置和 OHOS OHAudio 后端实现。

## 文件说明

- **ohaudio.cpp / ohaudio.h** — OHAudio 后端实现（我们的代码，tracked in git）
- **CMakeLists.txt** — 构建配置（禁用所有无关后端，注入 OHAudio）
- **openal-soft/** — OpenAL Soft 源码（gitignored，通过 setup_deps.sh 克隆）
- **patches/** — 补丁说明文档

## 工作原理

1. `setup_deps.sh` 克隆 OpenAL Soft 源码到 `openal-soft/`
2. 脚本自动补丁 `alc/alc.cpp`，注入 OHAudio 后端注册代码
3. CMake 构建时通过 `add_subdirectory` 编译 OpenAL Soft
4. 我们的 `ohaudio.cpp` 被添加到 OpenAL Soft 目标中
5. 最终生成 `libopenal.so`，替代原来的 stub 空实现

## 更新 OpenAL Soft

```bash
bash setup_deps.sh --force
```
