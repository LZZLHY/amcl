# HarmonyOS 签名凭据管理指南

**文档版本**: 2026-05-04
**适用范围**: AMCL 项目所有贡献者

---

## 为什么要写这份文档

2026-05-04 项目全面评审后,采取防御性措施避免 HarmonyOS 签名凭据住进 git 仓库。

背景：`build-profile.json5` 的 `signingConfigs.material` 字段一旦被填入真实值,会包含明文签名密钥(如 `keyPassword` / `storePassword` / `certpath`)。即使是调试 key,也属于敏感凭据——攻击者可以用它对伪造的 HAP 包重新签名并冒充本项目发布。

**本项目当前状态**（1）`build-profile.json5` 已加入 `.gitignore`；（2）git 历史所有提交里这个文件都不含 `signingConfigs` 字段（仓库从未泄露过密钥）。本指南作为**预防性文档**限定下述场景的标准操作。

本指南说明:
1. 新开发者如何**正确配置** 签名(不泄露密钥)
2. 万一将来误提交了密码,如何从 git history 中**清除**

---

## 一、新开发者首次配置

### 步骤 1:复制模板

```powershell
# Windows PowerShell
Copy-Item build-profile.json5.template build-profile.json5
```

```bash
# Linux / macOS / WSL
cp build-profile.json5.template build-profile.json5
```

`build-profile.json5` 已在 `.gitignore` 中,不会被再次提交。

### 步骤 2:在 DevEco Studio 内导入证书

1. 打开项目,菜单 `File → Project Structure → Project → Signing Configs`
2. 点击 `+` 添加 `default`
3. 导入本机 `.p12` / `.p7b` / `.cer`(通常在 `~/.ohos/config/` 下)
4. 输入 key / store 密码
5. DevEco Studio 会自动回填 `material` 字段到你本地的 `build-profile.json5`

### 步骤 3:验证密码未被 git 追踪

```powershell
git check-ignore -v build-profile.json5
# 应输出: .gitignore:20:/build-profile.json5  build-profile.json5
```

---

## 二、老仓库的历史清除(紧急预案)

> 本项目当前不需要这步。仅作为**万一未来误提交后的标准处置流程**保留在这里。

**如果你的 fork / 克隆仓库仍有历史中的明文密码,需要主动清除**。

### 方案 A:BFG Repo-Cleaner(推荐,简单)

```bash
# 1. 下载 BFG: https://rtyley.github.io/bfg-repo-cleaner/
# 2. 克隆一个裸仓库
git clone --mirror <repo-url> amcl-cleanup.git

# 3. 用 BFG 清除 build-profile.json5 的历史
java -jar bfg.jar --delete-files build-profile.json5 amcl-cleanup.git

# 4. 物理清理
cd amcl-cleanup.git
git reflog expire --expire=now --all && git gc --prune=now --aggressive

# 5. 强制推送(会重写所有历史 — 所有人必须重新 clone)
git push --force
```

### 方案 B:git filter-repo(更灵活,Python)

```bash
pip install git-filter-repo
git filter-repo --path build-profile.json5 --invert-paths --force
git push --force
```

### 方案 C:仅重置密码(不清历史,风险保留但成本最低)

如果团队成员不愿接受 force push:

1. 在 DevEco Studio 里**重新生成** 签名证书(新的 .p12 + 新密码)
2. 旧 `build-profile.json5` 里的密码虽然仍在 git history 中,但对应的证书已废弃
3. 记录到 `docs/ROADMAP.md`:"签名凭据已于 YYYY-MM-DD 轮换,历史中的 password 均已失效"

⚠️ 方案 C 的问题:旧证书如果仍能签名 **已发布的 HAP 包**,攻击者仍可伪造更新包。所以方案 A/B 加**撤销旧证书** 才是完整解法。

---

## 三、团队协作约定

### 3.1 禁止

- ❌ 在 PR 中把 `build-profile.json5` 加回 git(需要 review 卡控)
- ❌ 把 `.p12` / `.p7b` / `.cer` 提交到仓库
- ❌ 在 CI / CD 日志中 echo 签名密码

### 3.2 推荐

- ✅ 本地签名配置由 DevEco Studio GUI 管理(自动填 `build-profile.json5`)
- ✅ CI 签名密码通过环境变量注入(如 `HOS_SIGN_KEY_PASSWORD`),不写入文件
- ✅ 新成员入职时走一遍"一、新开发者首次配置"流程
- ✅ 证书有效期 / 轮换策略写入 `ROADMAP.md`

### 3.3 CI 环境签名(未来)

当项目引入 CI 自动化构建时,建议:

```yaml
# GitHub Actions 示例
- name: Import signing config
  env:
    KEY_PASSWORD: ${{ secrets.HOS_SIGN_KEY_PASSWORD }}
    STORE_PASSWORD: ${{ secrets.HOS_SIGN_STORE_PASSWORD }}
  run: |
    # 从模板生成真实配置
    cp build-profile.json5.template build-profile.json5
    # 用 jq 或 sed 注入 material 字段
    # ... (具体由 CI 脚本处理)
```

---

## 四、常见问题

### Q1:为什么不把 `build-profile.json5` 保留在 git 里,只用占位符替换密码?

答:HarmonyOS hvigor 会严格校验 `material` 字段格式,写占位符会导致构建失败;同时 DevEco Studio 每次打开都会提示"签名配置不完整"。整个文件 gitignore 的方案最干净。

### Q2:`build-profile.json5.template` 里 `signingConfigs` 是空数组,会影响构建吗?

答:首次 `hvigorw assembleHap` 会因为找不到 signing config 报错;这是**预期行为**——提示开发者必须先在 DevEco 里导入本机证书。

### Q3:DevEco Studio 会不会自动生成 `build-profile.json5`?

答:会。首次 `File → Project Structure → Signing Configs → Auto Generate` 时,DevEco 会调用 `hdc` 生成调试证书并写入 `build-profile.json5`。这正是我们需要的:**本地生成,不进 git**。

---

## 五、关联文件

- `build-profile.json5.template` — 本地配置起点(tracked)
- `build-profile.json5` — 实际配置(**gitignored**,本地生成)
- `.gitignore` — `/build-profile.json5` 规则
- `docs/self-inspection/2026-05-04_AMCL_项目全面评审报告.md` — 原始扣分项

---

## 六、外部依赖完整性校验

项目从 GitHub Releases 下载的二进制资源（JDK 包、依赖 zip 等）都会经过 ghfast / gh-proxy 等镜像。为防止镜像被劫持注入恶意中间产物，所有关键包都提供 SHA-256 公开校验和。

### 6.1 JDK 17

| 字段 | 值 |
|------|------|
| **GitHub Release Tag** | `v17.0.13-ohos-4` |
| **Asset 名** | `jdk17-ohos-full-v4.zip` |
| **仓库** | https://github.com/LZZLHY/mc-ohos-resources |
| **文件大小** | `114006672` bytes (108.73 MB) |
| **SHA-256** | `822bf2c75042d46c0190bf184f364768874fb39610062c469bd43d40ea78966f` |
| **启用位置** | `entry/src/main/ets/services/JdkManager.ets` `JDK_VERSIONS['17'].sha256` |
| **生效时间** | 2026-05-04 |

**校验方式**（开发者手动复现）：

```powershell
# Windows PowerShell
Get-FileHash -Algorithm SHA256 'D:\path\to\jdk17-ohos-full-v4.zip'
```

```bash
# Linux / macOS / WSL
sha256sum jdk17-ohos-full-v4.zip
```

```powershell
# 不落盘、从镜像流式算（项目提供脚本）
.\tools\compute_jdk_sha256.ps1                # 默认 ghfast 镜像
.\tools\compute_jdk_sha256.ps1 -Mirror direct # GitHub 直连
```

### 6.2 校验失败了怎么办

1. **确认你下的文件大小是否是上表中的 `114006672` bytes**
   - 如果不是：下载不完整，重试
   - 如果是但 hash 不匹配：镜像恢复中途产物已被修改，**必须拒用**
2. **换个镜像重试**，最后走 GitHub 直连兜底
3. **如果多个镜像都不匹配**：可能是远程仓库本身被推了不同 version。此时：
   - 到源仓 `LZZLHY/mc-ohos-resources` 看 release notes 是否变动了
   - 联系项目维护者确认
   - 更新本文档 + `JdkManager.ets` 中的 sha256 字段

### 6.3 新增依赖时的流程

开发者发布新版 JDK / native 依赖 zip 时：

1. 在本地用以上命令计算 SHA-256
2. 更新本文档的 6.1 表格
3. 同步更新对应的代码字段（如 `JDK_VERSIONS['<v>'].sha256`）
4. 同一个 commit 提交 docs + 代码

---

## 七、ELF Loader 与代码签名合规边界

本项目包含自定义 ELF 加载器（`@entry/src/main/cpp/jvm/elf_loader.cpp`，1230 行），通过匿名 `mmap` + `pread` + `mprotect(PROT_EXEC)` 从 `filesDir/jdk/<ver>/` 加载 OpenJDK .so，**绕过 HarmonyOS 内核 MAP_XPM 代码签名验证**。需要 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` ACL 权限。这是一个需要特别说明合规边界的设计决策。

### 7.1 为什么需要绕过 MAP_XPM

**技术约束**：HarmonyOS 的 `dlopen` 只信任 HAP 包内 `libs/arm64-v8a/` 的已签名 .so。但 OpenJDK 完整发行版 ~40 个 .so、总 100+ MB，**全塞进 HAP 会导致**：

- HAP 体积膨胀至 200 MB+，远超 HarmonyOS 应用商店 50 MB 常规限制；
- 无法做 JDK 多版本并存（17 / 21）与按需下载；
- 用户每次 JDK 升级需重新下载整个 HAP。

**解决方案**：JDK .so 放在 `filesDir/jdk/<ver>/lib/`（首启从可信 GitHub Release 下载 + 解压），自实现 ELF loader 接管加载，**不经过系统 `dlopen`**。

### 7.2 合规边界声明（⚠️ 重要）

本项目的 ELF loader **仅用于**以下严格受控的场景：

| 用途 | 是否允许 | 说明 |
|------|---------|------|
| 加载项目从 GitHub Release 下载的 OpenJDK `.so` | ✅ **允许** | 下载源受 SHA-256 校验（见本文档 6.1），篡改立即中止 |
| 加载项目预编译的 LWJGL / JNA / OpenAL Soft `.so`（HAP 内） | ✅ **允许** | 实际上这些直接走系统 `dlopen`（在 HAP 内），不经过 ELF loader |
| 加载用户运行时从网络下载的任意 `.so` | ❌ **禁止** | 本项目不提供任何运行时代码下载 API |
| 加载用户 MC mod 提供的 native library | ❌ **禁止** | Forge / Fabric 模组的 native 库走 LWJGL / JNA 的 `System.load`，仍经系统 `dlopen`，受 HAP ACL 约束 |
| 执行 MC 沙箱外的任意代码 / 提权 | ❌ **禁止** | ELF loader 加载的 .so 与 HAP 进程共享权限，不访问任何额外系统 API |

### 7.3 降低滥用风险的工程措施

- **SHA-256 硬校验**：`@entry/src/main/ets/services/JdkManager.ets:514-575` `verifyArchiveIntegrity` 在解压 JDK zip 之前强制比对哈希，不通过则中止并删除文件。
- **CA bundle 自带**：`@entry/src/main/ets/services/DownloadManager.ets:216-236` 从 rawfile 抽 `cacert.pem` 交给 libcurl，不走"关闭证书校验"的偷懒方案。
- **`AllowWritableCodeMemory` ACL 受限**：该权限只在 `@entry/src/main/module.json5` 声明且受 HarmonyOS AppGallery 审核，普通 HAP 无法申请。
- **`NEEDED` 符号白名单**：ELF loader 只解析 JDK 所需符号，不暴露任意 `dlsym()` 入口给业务代码。
- **进程内隔离**：ELF loader 加载的 JDK 与主进程共享地址空间（必须如此，否则 JNI 无法互通）；此设计假设 **JDK .so 本身可信**（经 Docker 容器内 Reproducible Build + 本文档 SHA-256 校验锁定）。

### 7.4 与主流 iOS JB launcher 的对比

| 项目 | 机制 | 是否需要越狱 | 风险级别 |
|------|------|------------|---------|
| PojavLauncher (Android) | Android 原生 `dlopen`（Android 不强制签名） | 否 | 低 |
| Amethyst-iOS | 修改 dyld 拦截 mmap/fcntl | **需越狱** | 高 |
| **AMCL (HarmonyOS NEXT)** | **自实现 ELF loader，不修改系统组件** | **不需要越狱** | **中**（仅加载白名单内的受校验 JDK .so） |

### 7.5 审计与披露

本项目的 ELF loader 实现：
- **源代码全部公开**：`@entry/src/main/cpp/jvm/elf_loader.cpp` + 12 条踩坑记录 `@docs/elf_loader_notes.md`。
- **无后门**：不含"从任意 URL 下载并 load"的 API，不含 `exec()` / `fork() + exec()` 任意二进制的路径。
- **供应链透明**：唯一外部下载源是 `github.com/LZZLHY/mc-ohos-resources` 的 OpenJDK zip，由项目维护者在 Docker 容器内编译（`@docker/build_jdk17_ohos.sh`）。

**若你是 HarmonyOS / 华为终端安全审计方**：本项目欢迎审计，请通过 GitHub Issues 对接。代码签名绕过仅服务于"在非越狱设备上跑合法购买的 Minecraft Java Edition"这一目标，不涉及：
- ❌ 绕过 Mojang 账号鉴权
- ❌ 绕过应用市场支付验证
- ❌ 加载任何形式的用户自备 .so 或网络下载 .so（除项目维护者签发的 JDK 资源包）
