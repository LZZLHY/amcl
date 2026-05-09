# AMCL 调试与测试指南

> 面向开发者的实机测试流程、日志获取方法、常见问题排查手册。

---

## 一、环境准备

### 1.1 设备连接

```bash
# 检查设备是否连接
hdc list targets

# 预期输出类似：
# 1234567890ABCDEF
```

如果无输出，检查：
- USB 调试是否开启（设置 → 系统 → 开发者选项 → USB 调试）
- 数据线是否支持数据传输（非纯充电线）

### 1.2 hdc 工具路径

hdc 位于 DevEco Studio SDK 目录下：

```
D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe
```

建议加入 PATH 或使用完整路径。以下命令均假设 hdc 已在 PATH 中。

### 1.3 安装 HAP

```bash
# 编译
# 在 MyApplication 目录下执行：
$env:NODE_HOME = "D:\Huawei\DevEco Studio\tools\node"
$env:PATH = "$env:NODE_HOME;$env:PATH"
& "D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p module=entry@default assembleHap --no-daemon

# 安装到设备（签名后的 HAP）
hdc install entry\build\default\outputs\default\entry-default-signed.hap

# 或通过 DevEco Studio 直接 Run
```

---

## 二、日志获取

### 2.1 实时查看全部日志

```bash
# 实时输出所有日志（信息量大，建议配合过滤）
hdc hilog
```

### 2.2 过滤 AMCL 相关日志

AMCL 各模块使用的 hilog TAG：

| TAG | 模块 | 说明 |
|-----|------|------|
| `INDEX` | Index.ets | 主页面生命周期、偏好加载 |
| `McVersionService` | McVersionService.ets | MC 版本列表获取 |
| `McDownloader` | McDownloader.ets | MC 文件下载引擎 |
| `DownloadTask` | DownloadTask.ets | 下载任务编排 |
| `JdkManager` | JdkManager.ets | JDK 下载/安装/检测 |
| `VersionParser` | VersionParser.ets | version.json 解析 |
| `VersionJsonMerger` | VersionJsonMerger.ets | JSON 合并 |
| `LaunchProfileBuilder` | LaunchProfileBuilder.ets | 启动配置构建 |
| `RuntimeDeployer` | RuntimeDeployer.ets | LWJGL/stub 部署 |
| `FabricService` | FabricService.ets | Fabric 安装 |
| `ForgeService` | ForgeService.ets | Forge 安装 |
| `MavenUtils` | MavenUtils.ets | Maven 库下载 |
| `MC_GAME` | McGamePage.ets | 游戏页面/JVM 启动 |
| `PreferenceManager` | PreferenceManager.ets | 偏好读写 |
| `testTag` | EntryAbility.ets | Ability 生命周期 |

```bash
# 过滤 AMCL 核心日志（推荐日常使用）
hdc hilog | findstr /i "INDEX JdkManager McDownloader DownloadTask MC_GAME LaunchProfileBuilder"

# 只看错误和警告
hdc hilog | findstr /i "ERROR WARN" | findstr /i "INDEX JdkManager McDownloader"

# 过滤特定模块（如 JDK 下载）
hdc hilog | findstr "JdkManager"

# 过滤特定模块（如 MC 启动）
hdc hilog | findstr "MC_GAME LaunchProfileBuilder"
```

### 2.3 保存日志到文件

```bash
# 保存实时日志到文件（Ctrl+C 停止）
hdc hilog > amcl_log_%date:~0,10%.txt

# 导出设备上的 hilog 缓冲区（历史日志）
hdc hilog -r   # 先清空缓冲区
# ... 执行测试操作 ...
hdc hilog -d > test_session.txt   # 导出缓冲区
```

### 2.4 查看 AMCL 内部日志文件

AMCL 有自己的日志系统（amcl_log），写入设备沙箱：

```bash
# 查看 AMCL 日志目录
hdc shell ls -la /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/logs/

# 拉取最新日志文件
hdc file recv /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/logs/ ./device_logs/

# 查看 MC 游戏日志（latest.log）
hdc shell cat /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/logs/latest.log
```

### 2.5 查看崩溃日志

```bash
# 查看应用崩溃日志
hdc shell ls /data/log/faultlog/faultlogger/ | findstr "amcl"

# 拉取崩溃日志
hdc file recv /data/log/faultlog/faultlogger/ ./crash_logs/
```

---

## 三、分模块测试流程

### 3.1 应用启动测试

**目标**：验证应用正常启动，三个 Tab 可切换。

```bash
# 清空日志缓冲区
hdc hilog -r

# 启动应用
hdc shell aa start -a EntryAbility -b com.amcl.launcher

# 查看启动日志
hdc hilog | findstr "testTag INDEX"
```

**预期日志**：
```
Ability onCreate
AMCL Log system initialized: /data/.../files/logs
Ability onWindowStageCreate
Succeeded in loading the content.
```

**检查项**：
- [ ] 应用正常启动，无白屏
- [ ] 三个 Tab（首页/下载/设置）可左右滑动切换
- [ ] 底部 Tab 栏图标点击切换正常
- [ ] 横竖屏旋转不崩溃
- [ ] 深色模式切换正常


### 3.2 JDK 下载与安装测试

**目标**：验证 JDK 17 下载、解压、安装完整流程。

```bash
hdc hilog -r
# 在应用中：下载页 → JDK 管理 → 点击"下载"
hdc hilog | findstr "JdkManager"
```

**预期日志流程**：
```
Cleaned old JDK 17 data and cache
Trying 镜像1: https://ghfast.top/...
Downloaded XX.X MB to .../jdk17-data.zip
解压中...
lib/modules verified: XXXXX bytes
JDK 17 extracted to .../jdk/17
JDK 17 安装完成 ✅
```

**检查项**：
- [ ] 下载进度百分比和速度正常显示
- [ ] 镜像切换日志（如果第一个镜像失败）
- [ ] 解压完成后首页状态变为绿色"就绪"
- [ ] 删除 JDK 后状态变回黄色

**异常排查**：
```bash
# 检查 JDK 安装目录
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/jdk/17/

# 检查关键文件
hdc shell ls -la /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/jdk/17/release
hdc shell ls -la /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/jdk/17/lib/server/libjvm.so
hdc shell ls -la /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/jdk/17/lib/modules
```

### 3.3 MC 版本下载测试

**目标**：验证 MC 版本列表获取、client.jar/libraries/assets 下载、版本合并。

```bash
hdc hilog -r
# 在应用中：下载页 → 新建版本 → 选择 1.20.4 → 原版 → 开始下载
hdc hilog | findstr "McDownloader DownloadTask VersionJsonMerger"
```

**预期日志流程**：
```
Fetched version info: 1.20.4 (libs=XX)
Downloading client.jar (XX.X MB)...
client.jar 100% XX.X/XX.X MB
Downloading XX libraries (staggered launch)...
libraries: XX 新下载, XX 已存在, 0 失败
Assets: XX exist, XX to download
Downloading XX assets...
MergeJson: mc=... loader=(none) output=1.20.4
Written merged JSON: ... (XXXX bytes)
Download complete: 1.20.4
```

**检查项**：
- [ ] 版本列表正常加载（正式版/快照/旧版本筛选）
- [ ] 搜索过滤正常
- [ ] 浮动进度条显示各阶段状态
- [ ] 下载完成后首页版本选择器更新
- [ ] 取消下载后临时目录清理

**异常排查**：
```bash
# 检查已下载版本
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/versions/

# 检查版本文件完整性
hdc shell ls -la /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/versions/1.20.4/
# 应包含：1.20.4.json, 1.20.4.jar

# 检查 libraries 目录
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/libraries/ | head -20

# 检查 assets
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/assets/indexes/
```

### 3.4 Fabric 安装测试

```bash
hdc hilog -r
# 在应用中：下载页 → 选择版本 → 选择 Fabric → 开始
hdc hilog | findstr "FabricService MavenUtils DownloadTask"
```

**预期日志**：
```
Installing fabric ... for MC 1.20.4
Fetching Fabric profile...
Downloading XX Fabric libraries...
Fabric installed: versionId=fabric-loader-X.XX.XX-1.20.4
ModLoader installed: ...
MergeJson: mc=... loader=... output=...
```

### 3.5 Forge 安装测试

```bash
hdc hilog -r
# 在应用中：下载页 → 选择版本 → 选择 Forge → 开始
hdc hilog | findstr "ForgeService ForgeInstallerUtils MavenUtils DownloadTask"
```

**预期日志**：
```
Installing forge ... for MC 1.20.4
Downloading Forge installer jar...
Extracting installer jar...
Pre-downloading XX libraries...
Running Forge installer (JLI_Launch)...
Forge installer exit code: 0
Post-check: verifying processor artifacts...
```

**Forge 特有排查**：
```bash
# 检查 Forge installer 产物
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/libraries/net/minecraftforge/forge/

# 检查 processor 产物（client-extra, client-srg 等）
hdc shell find /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/libraries/net/minecraft/ -name "*.jar" -type f
```

### 3.6 游戏启动测试

```bash
hdc hilog -r
# 在应用中：首页 → 启动游戏
hdc hilog | findstr "MC_GAME LaunchProfileBuilder mc_launcher jvm_launcher"
```

**预期日志流程**：
```
# ArkTS 层
LaunchProfile built: ver=1.20.4 main=net.minecraft.client.main.Main lwjgl=3 libs=XX args=XX

# C++ 层
[MC] Phase: validate
[MC] Phase: initJvm
[JVM] Loading libjvm.so...
[JVM] JNI_CreateJavaVM succeeded
[MC] Phase: registerNatives
[MC] Phase: setProperties
[MC] Phase: launchMain
[MC] Calling main class: net.minecraft.client.main.Main
```

**检查项**：
- [ ] McGamePage 正常跳转（或新窗口启动）
- [ ] XComponent 渲染面创建成功
- [ ] JVM 初始化成功
- [ ] MC 主类加载成功
- [ ] 触摸输入正常传递
- [ ] 退出游戏后正常返回启动器

**启动失败排查**：
```bash
# 查看完整的 MC 启动日志
hdc shell cat /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/logs/latest.log

# 查看崩溃报告
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/crash-reports/

# 查看 JVM 崩溃日志（hs_err）
hdc shell find /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/ -name "hs_err*" -type f

# 检查 classpath 中的 jar 是否存在
# （从 LaunchProfileBuilder 日志中获取 classpath，逐个检查）
```


---

## 四、设置与偏好测试

```bash
hdc hilog -r
# 在应用中修改各项设置
hdc hilog | findstr "PreferenceManager INDEX"
```

**检查项**：
- [ ] 内存滑块拖动后数值更新
- [ ] 主题切换（浅色/深色/系统）立即生效
- [ ] 版本隔离开关切换
- [ ] 新窗口模式开关切换
- [ ] 关闭应用重新打开后设置保持

**偏好文件直接检查**：
```bash
# 查看偏好存储文件
hdc shell find /data/app/el2/100/base/com.amcl.launcher/ -name "amcl_settings*" -type f
```

---

## 五、版本管理测试

```bash
hdc hilog -r
# 在应用中：首页 → 管理 → 删除版本
hdc hilog | findstr "INDEX"
```

**检查项**：
- [ ] 版本管理面板正常弹出
- [ ] 版本列表正确显示
- [ ] 选择版本后首页更新
- [ ] 删除版本后文件系统清理干净

**验证删除是否干净**：
```bash
# 删除前
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/versions/

# 删除后（确认目录已消失）
hdc shell ls /data/app/el2/100/base/com.amcl.launcher/haps/entry/files/.minecraft/versions/
```

---

## 六、Sheet 弹窗测试（重构重点验证）

本次重构将三个 `bindSheet` 分散到不同组件上，需要逐一验证：

| Sheet | 触发方式 | 绑定位置 |
|-------|---------|---------|
| 版本配置面板 | 下载页点击版本 | Stack 内不可见 Column 锚点 |
| 版本管理面板 | 首页点击"管理" | Stack 内不可见 Column 锚点 |
| 日志面板 | 设置页点击"查看启动器日志" | 根 Stack 组件 |

**测试步骤**：
1. 下载页 → 点击任意版本 → 版本配置面板应弹出 → 关闭
2. 首页 → 点击"管理" → 版本管理面板应弹出 → 关闭
3. 设置页 → 点击"查看启动器日志" → 日志面板应弹出 → 关闭
4. 快速连续触发不同 Sheet → 不应崩溃或卡死
5. Sheet 弹出时旋转屏幕 → 不应崩溃

---

## 七、沙箱目录结构参考

```
/data/app/el2/100/base/com.amcl.launcher/haps/entry/files/
├── logs/                          # AMCL 日志
│   └── amcl.log
├── jdk/
│   └── 17/                        # JDK 17 安装目录
│       ├── release                # 安装标记文件
│       ├── lib/
│       │   ├── server/libjvm.so   # JVM 核心
│       │   ├── modules            # Java 标准库
│       │   ├── libjava.so
│       │   └── ...
│       └── conf/
├── .minecraft/
│   ├── versions/
│   │   └── 1.20.4/
│   │       ├── 1.20.4.json       # 合并后的版本 JSON
│   │       └── 1.20.4.jar        # client.jar
│   ├── libraries/                 # 共享库目录
│   ├── assets/
│   │   ├── indexes/               # asset index JSON
│   │   └── objects/               # asset 文件（按 hash 前缀分目录）
│   ├── lwjgl-ohos/                # OHOS 版 LWJGL jar
│   ├── logs/
│   │   └── latest.log             # MC 游戏日志
│   ├── crash-reports/             # MC 崩溃报告
│   └── config/
│       └── fml.toml               # Forge EarlyDisplay 配置
└── fonts.conf                     # fontconfig 配置
```

---

## 八、常用排查命令速查

```bash
# === 设备连接 ===
hdc list targets                    # 列出已连接设备
hdc shell                           # 进入设备 shell

# === 日志 ===
hdc hilog                           # 实时日志
hdc hilog -r                        # 清空日志缓冲区
hdc hilog | findstr "关键词"         # 过滤日志

# === 文件操作 ===
hdc shell ls <路径>                  # 列出目录
hdc shell cat <文件>                 # 查看文件内容
hdc file recv <设备路径> <本地路径>    # 从设备拉取文件
hdc file send <本地路径> <设备路径>    # 推送文件到设备

# === 应用管理 ===
hdc shell aa start -a EntryAbility -b com.amcl.launcher    # 启动应用
hdc shell aa force-stop com.amcl.launcher                  # 强制停止
hdc install <hap路径>                                       # 安装 HAP
hdc uninstall com.amcl.launcher                            # 卸载应用

# === 存储空间 ===
hdc shell df -h                     # 查看磁盘空间
hdc shell du -sh /data/app/el2/100/base/com.amcl.launcher/   # 应用占用空间

# === 进程 ===
hdc shell ps -ef | findstr "amcl"   # 查看应用进程
hdc shell kill -9 <pid>             # 杀死进程
```

---

## 九、测试结果记录模板

每次测试建议按以下格式记录：

```
日期：2026-04-18
设备：[型号] / HarmonyOS [版本]
HAP 版本：[git commit hash]
测试人：[姓名]

| 测试项 | 结果 | 备注 |
|--------|------|------|
| 应用启动 | ✅/❌ | |
| Tab 切换 | ✅/❌ | |
| JDK 下载 | ✅/❌ | |
| MC 版本下载 | ✅/❌ | |
| Fabric 安装 | ✅/❌ | |
| Forge 安装 | ✅/❌ | |
| 原版启动 | ✅/❌ | |
| Forge 启动 | ✅/❌ | |
| Fabric 启动 | ✅/❌ | |
| 版本配置面板弹出 | ✅/❌ | |
| 版本管理面板弹出 | ✅/❌ | |
| 日志面板弹出 | ✅/❌ | |
| 设置保存/恢复 | ✅/❌ | |
| 版本删除 | ✅/❌ | |
| 深色模式 | ✅/❌ | |
| 横竖屏旋转 | ✅/❌ | |

附件：[日志文件名]
```
