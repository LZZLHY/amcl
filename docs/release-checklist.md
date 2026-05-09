# AMCL Release Checklist

> 每次准备打 tag / 上架前都跑一遍。任何一项 ❌ 都不能 release。

---

## 0. 自动化预检

```bash
node scripts/preflight.mjs --strict
```

预期：6 项全绿。任意 STALE / OOR / 编译错 / 测试失败 / CRLF 都会阻塞。

```
 OK   line-refs       OOR=0  STALE=0  ...
 OK   java-build      ...
 OK   java-tests      ≥107 passed, 0 failed
 OK   bash-syntax     all OK
 OK   json5-parse     all parsed
 OK   lf-eol          all LF
```

- [ ] preflight 全绿
- [ ] `git status` 干净（无未跟踪 / 未提交 改动）
- [ ] `git log --oneline -n 5` 与预期 release commit 一致

---

## 1. 依赖固定（commit pin）

参见 `@deps.versions` 头部约定。

- [ ] `deps.versions` 中 `MobileGlues_commit = <40-char-hex>` 已填且非注释
- [ ] `deps.versions` 中 `LWJGL_commit = <40-char-hex>` 已填且非注释
- [ ] 本地用 `MG_COMMIT=$(...) LWJGL_COMMIT=$(...) bash setup_deps.sh --force` 重新拉一次
- [ ] 脚本输出的 "pinned commit verification: <hash>" 与 `deps.versions` 中一致
- [ ] OpenAL Soft 是 tag pin（已通过 `OAL_TAG="1.24.3"` 锁定）

---

## 2. JDK 资源包完整性

参见 `@docs/security-signing.md` §6。

- [ ] `@entry/src/main/ets/services/JdkManager.ets` 中 `JDK_VERSIONS['<v>'].sha256` 与 GitHub Release 上的 zip 一致
- [ ] `@docs/security-signing.md` §6.1 的 SHA-256 表已与代码同步
- [ ] 真机首启验证：删 `filesDir/jdk/<v>/` → 重启 → 走 verifyArchiveIntegrity → 进世界 OK

---

## 3. 真机回归（必须，不能跳）

> **设备**：至少一台 HarmonyOS NEXT，建议两台不同芯片（Kirin / 高通 / 麒麟）。

### 3.1 启动烟雾

每个组合启动 → 进世界 → 5 分钟自由探索 → 退出 → log 干净（无 unhandled exception）：

- [ ] **Vanilla 1.20.4** → OK
- [ ] **Vanilla 1.20.4** + Mojang 在线登录 → 主城 / 玩家列表加载 OK
- [ ] **Forge 1.20.4** 无 mod → OK
- [ ] **Forge 1.20.4** + JEI（最常见 mod）→ OK
- [ ] **Fabric 1.20.4** 无 mod → OK
- [ ] **OOM 边界**：xmx=512M 启 Vanilla 不立即 OOM（如 OOM，至少错误信息友好）

### 3.2 已结案的高危场景（防回归）

- [ ] 不在 JVM 启动参数里加 `-Dorg.lwjgl.system.allocator=system`（会黑屏，详见 ROADMAP "踩坑记录"）
- [ ] 不在 `phase_initJvm` 做 `mmap(xmx+256MB) + munmap` xmx 预检（同上踩坑）
- [ ] `org.lwjgl.system.allocator=system` 当前**通过运行时 setProperty** 设置（C+Java 双写），保留至 P2 调查结案
- [ ] 退出后 `mc_output.log` + `mc_error.log` 收尾干净（最后 20 行无 unhandled exception / 无 watchdog dump）

### 3.3 P2 调查（如未结案）

如 `@docs/archive/allocator-investigation-202605.md` 还显示"待真机执行"，**release 前完成实验或明确接受当前冗余设置**。
不能在 release 中悄悄改 allocator 相关代码。

- [ ] allocator 调查状态在 `@docs/ROADMAP.md` 标记为 ✅ 已结论 OR 显式承认本次 release 维持现状

---

## 4. 安全卫生

参见 `@docs/security-signing.md`。

- [ ] `@entry/build-profile.json5` 中 `signingConfigs` 数组已通过模板填充（不是硬编码到 git）
- [ ] `@entry/build-profile.json5` 是 gitignored（`git check-ignore entry/build-profile.json5` 应输出文件名）
- [ ] HAP 内 `cacert.pem` 大小 ~220 KB（非空，是真实 CA bundle）
- [ ] release 模式 `obfuscation.enable: false` 仍是已知状态（如要开启需先满足 `@entry/build-profile.json5` 上方注释列出的所有前置条件）

---

## 5. 文档同步

- [ ] `@docs/ROADMAP.md` P1/P2 状态与代码现实一致（已解决项标 ✅）
- [ ] `@docs/architecture.md` 描述的目录结构、构建方式与现实一致
- [ ] `@docs/self-inspection/` 最近一份评审报告中的 🔴/🟠 已复查（解决了的标 ✅，未解决的有计划）
- [ ] `@CHANGELOG.md`（如有）含本次 release notes
- [ ] `@docs/release-checklist.md` （本文件）任何流程改动已合入

---

## 6. Final go/no-go

- [ ] 上述 0-5 节所有 [ ] 都 ✅
- [ ] 至少一个非作者的同事 review 过本 checklist
- [ ] 准备好 rollback 方案（上一个稳定 tag 的 HAP 备份在 `@releases/`）
- [ ] tag 名称 + 版本号格式正确（`v<major>.<minor>.<patch>`）

签字 release：______________ 日期：______________

---

## 备注：本 checklist 的维护

- 加项目：发现新的真机踩坑场景 → 加到 §3.2
- 删项目：流程改进让某项不再适用 → 在 PR 中说明并记录
- 不要软化：每项都要可验证（比如不要写"代码质量好"，要写"preflight --strict 全绿"）
