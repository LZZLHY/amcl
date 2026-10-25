# MobileGL 固定宿主 CPU 合同

本入口只校验实际源码/工具链/cache/object身份后调用 MobileGL fork 中的
`tools/cts/scripts/run_fp64_cpu_contract.py`；IR、缓存、current/异步合同及两类生产
反控均属于fork正式源，不复制其算法，不修改产品准入。CTS13/OpenRA仍独立显式运行。

调用前必须具有正常Linux AMD64 Ninja host构建与独立实取的`host-cache-proof.json`，
其中 source commit/tree、clean、固定image、container source/cache路径、生成GIT头、
库以及每个真实链接object/archive摘要相互一致。OHOS arm64跨编译cache和旧dirty宿主
制品不可借用。源clean由宿主原生Git核对，避免容器缺Windows LFS全局配置把合法载荷
误称dirty；实际CPU输入依旧逐字节检查。未知输入为NOT_RUN，不因缺资料标PASS。

从主工程现有`docker/project.py test --suite mobilegl-cpu-host`进入固定`amcl/qa`，
显式提供源码、期望commit、实际host cache、proof文件、proof SHA与已验证qa image。
每次输出是独立仓外目录（本机使用D），固定OS锁防止与其它qa抢用。fork工具只读原cache/object，在
独立输出中编译合同TU/epoch5与TF指针反控。参数和退出事实记入现有Compose收据；
CPU成功不能晋升真机、完整GL4、FP64 vertex input或pipeline/compute资格。

```powershell
python docker/project.py test --suite mobilegl-cpu-host `
  --mobilegl-source <clean-MobileGL-checkout> --mobilegl-expected-source <full-commit> `
  --mobilegl-host-cache <actual-Linux-Ninja-cache> `
  --mobilegl-host-proof <actual-host-cache-proof.json> --mobilegl-host-proof-sha <independent-sha256> `
  --mobilegl-qa-image <verified-image-or-image-id>
```

证明文件必须来自对应实际完成的host构建/收取过程；它记录库、生成头、Ninja文件与
全部直接链接对象/静态库，不能手填一个目录或把编译输入清单当已完成对象。缺这种
实际身份时先完成正常host构建，保持NOT_RUN，昂贵构建不偷偷塞进普通四产品门。

薄层通过实际`ninja -t commands MobileGL`文本摘要与最后链接argv独立核对完整
`.o/.a`集合；少一个仍非空或多一个真实但未参与链接的对象都拒绝。fork正常退出后
还要求本次CPU收据的当前合同摘要、八条必需命令和新输出argv成立；19项正控与精确
旧epoch阴性判据由钉版fork工具验证，薄层不另造第二套IR/缓存语义算法。
# 收取新host proof

`capture-host-proof.py` 收取已完成的实际 Linux cache 来源，属于输入捕获，不能给 CPU、GPU 或 OHOS 正确性 PASS。它读取实际 `ninja -t commands MobileGL` 的最后链接 argv，用 `shlex` 收取完整 `.o/.a` 集合，逐文件记录 SHA/字节数，并保存四项 cache 文件、生成 GIT 头、AMD64 ELF、所属 fork CPU runner/contract 和工具身份。与执行合同的旧入口相比，新捕获不需要预先已有 proof。

固定 QA 增加 `mobilegl-cpu-proof` 薄入口，沿原 `project.py` 的真实宿主 Git、image 解引用、OS 锁和同一 `amcl/qa` 服务，源码/cache/生产收据只读、输出独占。独立公开 CI 可以使用正常原生 Git 与同一固定入口，传入自己的源/缓存/仓外输出根；不依赖维护者 D 盘布局。源码须是已完成的 clean commit，cache 须来自该源码和该不可变 QA image，OHOS crosscache 会拒绝。

调用者独立选取实际正常 host 构建的 `build-manifest.json`，实算其摘要及同次 `compose.json`、`build.log` 摘要。收取先核该生产收据的正常完成、时间、clean source、真实 source/cache mount、镜像和 `out/artifacts` 四项快照，再核当前 cache 的同字节身份。宿主原生解析 `manifest.parent/out` 必须等于收据中的实际 output；容器按显式发布的宿主 producer 目录核同一关系，不能在另一目录复制同字节收据/快照继承来源。没有已有 proof 的前置条件；缺少正常生产收据则保持未收取。`imageId` 只取已验证 producer，`captureImageId` 独立记录 reader，reader 与 producer 不同镜像直接拒绝。编译器来源写原生产日志和 producer CMake path，本次 `c++ --version` 仅列为 `captureToolCompilerVersion`；增量复用对象的边界继续保留，不能把全部对象说成本次从零编译。

```sh
# 在主工程仓库根执行。先用正常现役 host 配方构建完整 Linux cache；本命令不构建。
AMCL_WORKSPACE_ROOT="$EXTERNAL_OUTPUT_ROOT" python3 -B docker/project.py test \
  --suite mobilegl-cpu-proof --mobilegl-source "$MOBILEGL_SOURCE" \
  --mobilegl-expected-source "$FULL_FORK_COMMIT" --mobilegl-host-cache "$LINUX_CACHE" \
  --mobilegl-qa-image "$QA_IMAGE" \
  --mobilegl-producer-manifest "$NORMAL_BUILD_MANIFEST" \
  --mobilegl-producer-sha "$INDEPENDENT_MANIFEST_SHA256" \
  --mobilegl-producer-compose-sha "$INDEPENDENT_COMPOSE_SHA256" \
  --mobilegl-producer-log-sha "$INDEPENDENT_BUILD_LOG_SHA256"
# 从本次 build-manifest 对应 out/host-cache-proof.json 实算SHA，独立选取后使用既有
# mobilegl-cpu-host --mobilegl-host-proof/--mobilegl-host-proof-sha；不能借旧 result.json。
```

`test-proof-inputs.py` 只读实际 Ninja/cache 和独立旧 proof，用于校准完整输入集合与原件未变。它不执行 CPU 合同，也不会把缺对象的缓存记为 PASS。CPU 合同仍只调用 fork `tools/cts/scripts/run_fp64_cpu_contract.py`，19 项与 epoch/TF 阴性算法归属 fork。昂贵 CTS/replay 维持显式执行。
