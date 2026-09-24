# OpenAL Soft 与 OHAudio 适配

上游 OpenAL Soft 源码由依赖准备放入 entry/src/main/cpp/openal/openal-soft/。setup_deps.sh 从 deps.lock 的 [openal-soft] 节读取 upstream、tag 和 commit，拉取后强制核对 HEAD 与锁定的 40 位提交 SHA 一致。公开准备入口为：

```powershell
node scripts/prepare-public-deps.mjs
node scripts/prepare-public-deps.mjs --check
```

命令在 MyApplication/ 执行。setup_deps.sh 调用 [docker/apply_patches.sh](../../docker/apply_patches.sh)，以本目录的 [patches/](patches/) 为 --patch-dir、上游源码目录为 --target，按 series 应用 0001-register-ohaudio-backend.patch。该流程可重复执行，已经应用的补丁会被识别；无需另外手工修改注册点。

实际 HAP 构建由 [entry/src/main/cpp/openal/CMakeLists.txt](../../entry/src/main/cpp/openal/CMakeLists.txt) 接入上游，并加入同目录的 ohaudio.cpp/ohaudio.h、定义 HAVE_OHAUDIO=1、链接系统 OHAudio，产出 libopenal.so。本目录的 [ohaudio/](ohaudio/) 是保留的适配材料；当前编译源路径以 CMake 为准。

OpenAL Soft 保留上游许可和版权要求；动态链接方式本身不等于完成全部许可义务。具体许可文本应从锁定上游源码及文件头核对，本文件不作许可完整性声明。

完整构建步骤见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)，来源导航见 [CREDITS.md](../../docs/CREDITS.md)。
