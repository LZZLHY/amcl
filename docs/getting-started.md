# AMCL 快速上手（开发者视角）

> 新手第一次拉到本仓库，想要看到 MC 跑起来，应该做这 7 步。
> 如果你是普通用户，只想玩游戏，等 HAP 签名包分发后看 `README.md` 即可。

## 前置要求

- **硬件**：HarmonyOS NEXT 设备，arm64-v8a，API 20+（Mate 70 / Pura 70 Ultra 等）
- **开发环境**：Windows / macOS / Linux + DevEco Studio 5.0.3+
- **账号**：HarmonyOS 开发者账号（签 HAP 用）
- **磁盘**：至少 20 GB 空闲（Docker 镜像 + JDK 源码 + 构建产物）
- **网络**：能访问 GitHub、Maven Central、Mojang libraries（国内需代理）

---

## 第 1 步：申请 ALLOW_WRITABLE_CODE_MEMORY ACL

HotSpot JIT 需要可写+可执行内存，默认沙箱禁止。必须申请这个 ACL 权限，否则 JVM 一启动就 crash。

在 `entry/src/main/module.json5` 的 `requestPermissions` 里确认有：

```json5
{
  "name": "ohos.permission.ALLOW_WRITABLE_CODE_MEMORY",
  "reason": "$string:EntryAbility_desc",
  "usedScene": {
    "abilities": ["EntryAbility"],
    "when": "always"
  }
}
```

> 这个权限需要**特殊签名**。个人开发者拿不到官方签名，只能用自签名在自己设备上跑。

---

## 第 2 步：拉取外部依赖源码

```bash
bash setup_deps.sh
```

会克隆：
- `entry/src/main/cpp/mobileglues/MobileGlues-cpp/`（GL→GLES 翻译层）
- `entry/src/main/cpp/openal/openal-soft/`（OpenAL Soft 源码）
- 以及各自的 submodule（glslang / SPIRV-Cross / glm / xxhash）

---

## 第 3 步：获取预编译的 JDK / LWJGL 产物

**两种选择，选一种：**

### 选项 A（推荐）：下载别人编译好的 prebuilt

从 GitHub Release 下载 prebuilt 包解压到 `prebuilt/`，然后同步到部署位置：

```bash
bash scripts/sync_prebuilt.sh
```

预期结果：
- `entry/libs/arm64-v8a/` 下有 6 个 .so（`liblwjgl*.so` + `libjnidispatch.so`）
- `entry/src/main/resources/rawfile/lwjgl/` 下有 10 个 jar

### 选项 B：自己用 Docker 交叉编译（第一次跑 2-4 小时）

```bash
cd docker
docker build -f Dockerfile.openjdk-ohos -t openjdk-ohos-builder .

# 编 JDK 17
docker run --rm \
  -v "D:/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot:/ohos-sysroot:ro" \
  -v "$PWD/../output:/output" \
  openjdk-ohos-builder /build/build_jdk17_ohos.sh

# 编 LWJGL
docker run --rm \
  -v "D:/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot:/ohos-sysroot:ro" \
  -v "$PWD/../output:/output" \
  openjdk-ohos-builder /build/build_lwjgl_ohos.sh

# 然后把 output 按 prebuilt/ 布局放好，再跑 sync
```

详细参数见 `@docs/BUILD_INSTRUCTIONS.md`。

---

## 第 4 步：编译并打包 HAP

**三种方式任选**（都会自动编 JavaApp → 打成 `amcl-launcher.jar`）：

```powershell
# 方式 A：DevEco Studio 里按 Run ▶️ —— 推荐日常开发使用
# （hvigor 的 buildAmclLauncher task 会自动触发）

# 方式 B：命令行 hvigor —— 推荐 CI
& "D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" clean assembleHap --mode module -p product=default --no-daemon

# 方式 C：一键脚本（预热 + hvigor，Windows 开发者常用）
pwsh build-hap.ps1
```

> 2026-04-19 起 `JavaApp/` 已经挂进 hvigor 构建图（`entry/hvigorfile.ts` 里的
> `buildAmclLauncher` task），DevEco Run 也会正确编到 `AmclLauncher.java` 的改动。
> 实际 javac + jar 由 `scripts/build-amcl-launcher.mjs` 完成，带增量，上次没改就跳过。

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

---

## 第 5 步：装到设备

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

装好后，**先不要直接启动 MC** —— 还没 JDK 和游戏文件。

---

## 第 6 步：准备 JDK 数据包

HAP 里没有 JDK 本体，需要下载到 filesDir：

1. 打开 app → "JDK 管理" Tab
2. 点击 "下载 JDK 17"
3. 等待从 GitHub Release 下载 `jdk17-ohos-data.zip`（约 50 MB）
4. 解压校验 `lib/modules`（约 128 MB）

> 国内下载慢：可在设置里配镜像源，或手动下载 `jdk17-ohos-data.zip`，用 `hdc file send` 推到 `/data/app/el2/100/base/com.example.myapp/haps/entry/files/jdk17-ohos-data.zip`，再重启 app 让它识别。

---

## 第 7 步：下载 MC 并启动

1. 打开 app → "下载" Tab
2. 选 MC 版本（推荐 1.20.4）
3. 可选：在"版本配置面板"选 Fabric / Forge + 起个版本名
4. 点"开始下载安装"，等下载 client.jar + libraries + assets 完成
5. 回首页选择版本 → "启动"

第一次进主菜单后：
- 检查 `filesDir/<version>/mc_output.log` 确认没报错
- 触摸移动视角 / 点击 / 使用虚拟按键

---

## 常见问题

### Q: 装完 HAP 点启动就闪退
可能是 ALLOW_WRITABLE_CODE_MEMORY 没生效。用 `hdc shell` 抓日志：
```bash
hdc shell hilog -r
hdc shell hilog -x | Select-String "JVM_LAUNCHER|AMCL"
```
详见 `@docs/testing/debug-testing-guide.md`。

### Q: 改完 `AmclLauncher.java` 行为没变化
1. 确认 hvigor 确实跑了 `buildAmclLauncher` task（构建日志里应有 `[hvigor buildAmclLauncher] running: ...`）
2. 看下 jar 的 mtime：`ls -la entry/src/main/resources/rawfile/amcl-launcher.jar`，如果比源文件旧，说明 hvigor task 没触发，手动跑 `node scripts/build-amcl-launcher.mjs` 对比
3. 增量检查是按 mtime 判断 —— 极少情况（git checkout 改 mtime 等）会错判，`rm entry/src/main/resources/rawfile/amcl-launcher.jar` 强制重编

### Q: 只有部分日志输出到 hilog
JVM 的 stdout/stderr 重定向到了 `gameDir/mc_output.log`，不在 hilog 里。用 `hdc file recv` 拉下来看：
```bash
hdc file recv /data/app/el2/100/base/com.example.myapp/haps/entry/files/.minecraft/versions/1.20.4/mc_output.log
```

### Q: Forge 可以启动但没声音
OpenAL Soft + OHAudio 后端是否正确编译 —— 检查 `libopenal.so` 是否在 HAP 里（见 5.3.1 节的 6 个 .so 清单中不应有它，它应该是**运行时编译**的）。

### Q: 我想测 JDK 21
**JDK 21 当前未上线、未做真机回归**。`Constants.SUPPORTED_JDK_VERSION = '17'`、`JdkManager.listVersions()` 仅暴露 17、`autoSelectVersion()` 永远返回 17、UI 各处对非 17 自动覆盖回退。如要解锁需按 `docs/ROADMAP.md` P2-NEW 完成 5 步前置（真机回归 / Forge 兼容矩阵 / SSOT 解锁 / UI / 下载源）。`prebuilt/jdk/21/` 与 `docker/build_jdk21_ohos.sh` 为研究产物。

### Q: 我要加一个新的 JVM 参数（`--add-opens` 之类的）
**SSOT 在 C 层**：只改 `entry/src/main/cpp/jvm/jvm_common_args.cpp` 的 `getCommonJvmArgs()` 返回清单即可。
主进程（`jvm_launcher.cpp`）、Forge installer 子进程（`fork_run_java.cpp`）、ArkTS 的 version.json 去重（`LaunchProfileBuilder.filterJvmArgs`）三处会自动同步。
**注意**：只放"和版本/classpath/用户设置无关"的 OHOS 兼容性修复参数。运行时生成的路径（`-Djava.home=...`）、`-Xmx`、Cacio 条件参数不放这里。详见 `jvm_common_args.h` 顶部注释。

---

## 参考文档

- `@docs/architecture.md` — 整体架构（必读）
- `@docs/JDK_ADAPTATION_GUIDE.md` — JDK 适配细节（改 C 层前必读）
- `@docs/elf_loader_notes.md` — ELF loader 踩坑（改 `elf_loader.cpp` 前必读）
- `@docs/ROADMAP.md` — 当前待办和优先级
- `@docs/testing/debug-testing-guide.md` — 调试 / 日志抓取
- `@docs/guides/download-system-redesign-v2.md` — 下载系统设计
- `entry/src/main/cpp/jvm/jvm_common_args.h` — JVM 参数 SSOT 说明（改 JVM 参数前必读）
