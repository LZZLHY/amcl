/*
 * MavenSpecBuilder.test.ets — Phase 1 (ARCH-1) 纯函数单元测试
 *
 * 直接执行生产 Maven 规格与结果转换函数；网络/文件执行不进入本纯函数套件。
 * 失败路径必须绑定本批输入；未知路径、取消与非法坐标不能产生虚假的成功计数。
 *
 * 覆盖范围（全部为纯函数，零 I/O）：
 *   - buildMavenUrls(coordinate, repoHint?)          BMCLAPI 优先 + 多源 fallback + 去重
 *   - buildSpecForLib(lib, libDir)                   单 lib → DownloadFileSpec
 *   - buildSpecsForLibs(libs, libDir)                批量构造 + 非法坐标分离
 *   - parseDoneEventToBatchResult(view, libs, map)   DownloadTaskView → LibBatchDownloadResult
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 1
 * 进度跟踪：docs/guides/download-implementation-progress.txt
 *
 * 创建日期：2026-05-05
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  buildMavenUrls,
  buildSpecForLib,
  buildSpecsForLibs,
  parseDoneEventToBatchResult,
} from 'feature_core';
import { MavenLibEntry } from 'feature_core';
import { DownloadTaskView, DownloadFailedFile, DownloadFailedFileError } from 'feature_core';

const BMCLAPI_HOST_PREFIX = 'https://bmclapi2.bangbang93.com/maven/';
const FABRIC_REPO = 'https://maven.fabricmc.net/';
// repoHint 专用仓库：**故意选一个既不在 DEFAULT_MAVEN_REPOS、也不是任何加载器自有
// 仓库的地址**。用 FABRIC_REPO 当 hint 是不行的 —— 它本身就在兜底列表里（对
// net.fabricmc 坐标更是该 group 的自有仓库），于是"URL 里出现 fabricmc"这件事
// 无法区分"repoHint 生效了"和"兜底仓库恰好也是它"，断言会恒真。
// 换成这个地址后，候选链里出现该 host 只可能来自 repoHint 这一条路径。
const HINT_ONLY_REPO = 'https://repo.papermc.io/repository/maven-public/';
const KNOWN_HINT_ONLY_REPO = 'https://repo.maven.apache.org/maven2/';
const FORGE_REPO = 'https://maven.minecraftforge.net/';
const NEOFORGE_REPO = 'https://maven.neoforged.net/releases/';
const MOJANG_LIB_REPO = 'https://libraries.minecraft.net/';
const MAVEN_CENTRAL = 'https://repo1.maven.org/maven2/';
const MC_LIB_DIR_T = '/data/storage/el2/base/files/.minecraft/libraries';

// 顶层 helper（ArkTS 严格模式：禁止嵌套函数 arkts-no-nested-funcs）
function makeViewForBatch(success: boolean, failedFiles: DownloadFailedFile[]): DownloadTaskView {
  let view = new DownloadTaskView();
  view.taskId = 1;
  view.success = success;
  view.finished = true;
  view.aborted = false;
  view.state = success ? 'Finished' : 'Failed';
  view.failedFiles = failedFiles;
  return view;
}

function makeFailedFileForBatch(localPath: string, basename: string,
                                errorKind: string, message: string): DownloadFailedFile {
  let err: DownloadFailedFileError = {
    kind: errorKind,
    message: message,
    httpStatus: 0,
    nativeCode: 0,
  };
  let f: DownloadFailedFile = {
    localPath: localPath,
    basename: basename,
    lastError: err,
    triedUrls: [],
  };
  return f;
}

export default function mavenSpecBuilderTest() {

  // ============================================================
  //  buildMavenUrls
  // ============================================================
  describe('MavenSpecBuilder.buildMavenUrls', () => {

    it('BMCLAPI 永远是首个 URL', 0, () => {
      let urls = buildMavenUrls('net.fabricmc:fabric-loader:0.16.10', undefined);
      expect(urls.length > 0).assertTrue();
      expect(urls[0]).assertEqual(BMCLAPI_HOST_PREFIX
        + 'net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
    });

    // 已登记仓库可使用既有镜像关系；用不在通用fallback中的Apache根验证hint
    // 真正被消费，不能以未知私有根来凑“公开镜像等价”的前提。
    it('已登记 repoHint 排在所有 BMCLAPI 之后、通用兜底之前', 0, () => {
      let urls = buildMavenUrls('org.ow2.asm:asm:9.6', KNOWN_HINT_ONLY_REPO);
      let hint = KNOWN_HINT_ONLY_REPO + 'org/ow2/asm/asm/9.6/asm-9.6.jar';
      let hintIndex = urls.indexOf(hint);
      // 该 host 只可能来自 repoHint，所以 hintIndex >= 0 本身就是"透传成功"的证据。
      expect(hintIndex > 0).assertTrue();

      // repoHint 之前必须全是 BMCLAPI，且至少有一条。
      expect(hintIndex >= 1).assertTrue();
      for (let i = 0; i < hintIndex; i++) {
        expect(urls[i].indexOf('bmclapi') > 0).assertTrue();
      }
      // repoHint 之后不允许再出现 BMCLAPI。
      for (let i = hintIndex + 1; i < urls.length; i++) {
        expect(urls[i].indexOf('bmclapi') > 0).assertFalse();
      }
      // repoHint 之后必须还有通用兜底仓库，否则"在兜底之前"这半句没有被验证。
      let fallbackAfterHint = 0;
      for (let i = hintIndex + 1; i < urls.length; i++) {
        if (urls[i].indexOf('maven.aliyun.com') > 0
            || urls[i].indexOf('repo1.maven.org') > 0
            || urls[i].indexOf('libraries.minecraft.net') > 0) {
          fallbackAfterHint++;
        }
      }
      expect(fallbackAfterHint > 0).assertTrue();
    });

    it('未知仓库只使用明确hint，不猜公共镜像或通用fallback', 0, () => {
      const urls = buildMavenUrls('org.ow2.asm:asm:9.6', HINT_ONLY_REPO);
      expect(urls.length).assertEqual(1);
      expect(urls[0]).assertEqual(HINT_ONLY_REPO + 'org/ow2/asm/asm/9.6/asm-9.6.jar');
    });

    it('repoHint 未提供时，该 host 不会出现在候选链里（上一条的负向对照）', 0, () => {
      // 没有这条，上一条的 hintIndex>=0 仍可能因为某天 HINT_ONLY_REPO 被加进兜底
      // 列表而恒真。两条成对，才能证明 host 的出现确实由 repoHint 决定。
      let urls = buildMavenUrls('org.ow2.asm:asm:9.6', undefined);
      for (let url of urls) {
        expect(url.indexOf('repo.papermc.io') > 0).assertFalse();
      }
    });

    it('加载器自有 group 只保留自己的上游仓库作兜底', 0, () => {
      // 2026-07-30：net/fabricmc 是加载器自有 group，阿里云 / Central / Mojang libraries
      // 对它恒 404，不再拼进候选链。剩下 BMCLAPI /maven + BMCLAPI /libraries + fabric maven。
      let urls = buildMavenUrls('net.fabricmc:fabric-loader:0.16.10', undefined);
      expect(urls.length).assertEqual(3);
      let countFabric = 0;
      for (let u of urls) {
        if (u.indexOf('maven.fabricmc.net') >= 0) countFabric++;
      }
      expect(countFabric).assertEqual(1);
    });

    it('repoHint 与兜底仓库重复时只出现一次', 0, () => {
      // FABRIC_REPO 既是 repoHint 又是该 group 的兜底仓库 → 去重后仍是 3 条。
      let urls = buildMavenUrls('net.fabricmc:fabric-loader:0.16.10', FABRIC_REPO);
      expect(urls.length).assertEqual(3);
      // urls[0]/[1] 是两个 BMCLAPI 端点，repoHint 紧随其后
      expect(urls[2]).assertEqual(FABRIC_REPO
        + 'net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
      let countFabric = 0;
      for (let u of urls) {
        if (u.indexOf('maven.fabricmc.net') >= 0) countFabric++;
      }
      expect(countFabric).assertEqual(1);
    });

    it('directUrl 的仓库路径前缀被剥掉后才拼镜像（NeoForge /releases/）', 0, () => {
      // 2026-07-30 回归守卫：NeoForge 的 downloads.artifact.url 带 `/releases/` 路径前缀，
      // 旧实现只剥 host，导致 BMCLAPI 镜像 URL 变成 `/maven/releases/net/neoforged/...` 恒 404，
      // repoHint 还会造出 `/releases/releases/...`。
      const REL = 'net/neoforged/fancymodloader/loader/11.0.13/loader-11.0.13.jar';
      let urls = buildMavenUrls(
        'net.neoforged.fancymodloader:loader:11.0.13', NEOFORGE_REPO, false,
        NEOFORGE_REPO + REL);
      for (let u of urls) {
        expect(u.indexOf('/releases/releases/') < 0).assertTrue();
        expect(u.indexOf('/maven/releases/') < 0).assertTrue();
        expect(u.indexOf('/libraries/releases/') < 0).assertTrue();
      }
      expect(urls[0]).assertEqual(BMCLAPI_HOST_PREFIX + REL);
    });

    it('非法坐标返回空数组', 0, () => {
      let urls = buildMavenUrls('not-a-maven-coord', undefined);
      expect(urls.length).assertEqual(0);
    });

    it('Forge 坐标包含正确的 Forge 仓库 URL', 0, () => {
      let urls = buildMavenUrls('net.minecraftforge:forge:1.20.4-49.0.30:client', undefined);
      let forgeFound = false;
      for (let u of urls) {
        if (u === FORGE_REPO + 'net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30-client.jar') {
          forgeFound = true;
          break;
        }
      }
      expect(forgeFound).assertTrue();
    });

    it('NeoForge 坐标包含 NeoForged 仓库', 0, () => {
      let urls = buildMavenUrls('net.neoforged:forge:1.20.4-20.4.190', undefined);
      let neoFound = false;
      for (let u of urls) {
        if (u.indexOf('maven.neoforged.net') >= 0) {
          neoFound = true;
          break;
        }
      }
      expect(neoFound).assertTrue();
    });

    it('坐标含 classifier 时所有 URL 路径都带 classifier', 0, () => {
      let urls = buildMavenUrls('org.lwjgl:lwjgl:3.3.1:natives-linux', undefined);
      for (let u of urls) {
        expect(u.indexOf('-natives-linux.jar') > 0).assertTrue();
      }
    });

    it('@extension 后缀正确反映在所有 URL', 0, () => {
      let urls = buildMavenUrls('net.minecraftforge:forge:1.20.4-49.0.30@zip', undefined);
      for (let u of urls) {
        expect(u.endsWith('.zip')).assertTrue();
      }
    });
  });

  // ============================================================
  //  buildSpecForLib
  // ============================================================
  describe('MavenSpecBuilder.buildSpecForLib', () => {

    const MC_LIB_DIR = '/data/storage/el2/base/files/.minecraft/libraries';

    it('基础 lib 构造正确的 localPath + urls', 0, () => {
      let lib: MavenLibEntry = { name: 'net.fabricmc:fabric-loader:0.16.10' };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        expect(spec.localPath).assertEqual(MC_LIB_DIR
          + '/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
        expect(spec.urls.length > 0).assertTrue();
        expect(spec.urls[0].indexOf('bmclapi') > 0).assertTrue();
      }
    });

    // 这条只管一件事：buildSpecForLib 是否把 lib.url 当 repoHint 传下去。
    //
    // 曾经的写法用 net.fabricmc 坐标 + FABRIC_REPO 断言"urls 里有 fabricmc"，
    // 那是恒真的：net.fabricmc 是加载器自有 group，兜底仓库本身就是 maven.fabricmc.net，
    // 即使 lib.url 完全没被传下去也照样命中。改用兜底列表之外的 HINT_ONLY_REPO，
    // 再配一条不带 url 的负向对照，断链回归才真能被抓到。
    it('repoHint 透传到 buildMavenUrls', 0, () => {
      let withHint: MavenLibEntry = {
        name: 'org.ow2.asm:asm:9.6',
        url: HINT_ONLY_REPO,
      };
      let spec = buildSpecForLib(withHint, MC_LIB_DIR);
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        expect(spec.urls.indexOf(
          HINT_ONLY_REPO + 'org/ow2/asm/asm/9.6/asm-9.6.jar') >= 0).assertTrue();
      }

      // 负向对照：不给 url 时该 host 绝不该出现，证明上面那条命中来自 lib.url。
      let withoutHint: MavenLibEntry = { name: 'org.ow2.asm:asm:9.6' };
      let bare = buildSpecForLib(withoutHint, MC_LIB_DIR);
      expect(bare !== null).assertTrue();
      if (bare !== null) {
        for (let url of bare.urls) {
          expect(url.indexOf('repo.papermc.io') > 0).assertFalse();
        }
      }
    });

    it('sha1 + size 透传到 check 字段', 0, () => {
      let lib: MavenLibEntry = {
        name: 'net.fabricmc:fabric-loader:0.16.10',
        sha1: 'abcdef0123456789012345678901234567890123',
        size: 1234567,
      };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        expect(spec.check !== undefined).assertTrue();
        if (spec.check !== undefined) {
          expect(spec.check.sha1).assertEqual('abcdef0123456789012345678901234567890123');
          expect(spec.check.size).assertEqual(1234567);
        }
      }
    });

    it('sha1 长度非 40 时不写入 check', 0, () => {
      let lib: MavenLibEntry = {
        name: 'net.fabricmc:fabric-loader:0.16.10',
        sha1: 'too-short',
      };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        // sha1 非法时不应填入 check.sha1（保留 size 如有）
        if (spec.check !== undefined) {
          expect(spec.check.sha1 === undefined).assertTrue();
        }
      }
    });

    it('size <= 0 时不写入 check.size', 0, () => {
      let lib: MavenLibEntry = {
        name: 'net.fabricmc:fabric-loader:0.16.10',
        size: 0,
      };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        if (spec.check !== undefined) {
          expect(spec.check.size === undefined).assertTrue();
        }
      }
    });

    it('非法 Maven 坐标返回 null', 0, () => {
      let lib: MavenLibEntry = { name: 'invalid-coord' };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);
      expect(spec === null).assertTrue();
    });

    it('libDir 末尾无斜杠也能正确拼接', 0, () => {
      let lib: MavenLibEntry = { name: 'net.fabricmc:fabric-loader:0.16.10' };
      let spec = buildSpecForLib(lib, MC_LIB_DIR);  // 无尾斜杠
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        expect(spec.localPath.indexOf('//') < 0).assertTrue();  // 防止双斜杠
      }
    });

    it('libDir 末尾有斜杠也不重复', 0, () => {
      let lib: MavenLibEntry = { name: 'net.fabricmc:fabric-loader:0.16.10' };
      let spec = buildSpecForLib(lib, MC_LIB_DIR + '/');
      expect(spec !== null).assertTrue();
      if (spec !== null) {
        expect(spec.localPath.indexOf('//') < 0).assertTrue();
      }
    });
  });

  // ============================================================
  //  buildSpecsForLibs
  // ============================================================
  describe('MavenSpecBuilder.buildSpecsForLibs', () => {

    const MC_LIB_DIR = '/data/storage/el2/base/files/.minecraft/libraries';

    it('全部合法时返回所有 specs，无 invalidNames', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'net.fabricmc:fabric-api:0.92.0' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
      ];
      let result = buildSpecsForLibs(libs, MC_LIB_DIR);
      expect(result.specs.length).assertEqual(3);
      expect(result.invalidNames.length).assertEqual(0);
      expect(result.pathToName.size).assertEqual(3);
    });

    it('混合非法坐标时分离', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'invalid-coord' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
        { name: 'too:few' },
      ];
      let result = buildSpecsForLibs(libs, MC_LIB_DIR);
      expect(result.specs.length).assertEqual(2);
      expect(result.invalidNames.length).assertEqual(2);
      expect(result.invalidNames.indexOf('invalid-coord') >= 0).assertTrue();
      expect(result.invalidNames.indexOf('too:few') >= 0).assertTrue();
    });

    it('空数组输入 → 空结果', 0, () => {
      let result = buildSpecsForLibs([], MC_LIB_DIR);
      expect(result.specs.length).assertEqual(0);
      expect(result.invalidNames.length).assertEqual(0);
      expect(result.pathToName.size).assertEqual(0);
    });

    it('pathToName 反查映射正确', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
      ];
      let result = buildSpecsForLibs(libs, MC_LIB_DIR);
      expect(result.specs.length).assertEqual(1);
      let path = result.specs[0].localPath;
      let foundName = result.pathToName.get(path);
      expect(foundName !== undefined).assertTrue();
      expect(foundName).assertEqual('net.fabricmc:fabric-loader:0.16.10');
    });

    it('全部非法时返回空 specs', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'bad1' },
        { name: 'bad2' },
      ];
      let result = buildSpecsForLibs(libs, MC_LIB_DIR);
      expect(result.specs.length).assertEqual(0);
      expect(result.invalidNames.length).assertEqual(2);
    });

    it('保留所有 lib 元数据（sha1 / size）', 0, () => {
      let libs: MavenLibEntry[] = [
        {
          name: 'net.fabricmc:fabric-loader:0.16.10',
          sha1: 'abcdef0123456789012345678901234567890123',
          size: 999,
        },
      ];
      let result = buildSpecsForLibs(libs, MC_LIB_DIR);
      expect(result.specs.length).assertEqual(1);
      let spec = result.specs[0];
      expect(spec.check !== undefined).assertTrue();
      if (spec.check !== undefined) {
        expect(spec.check.sha1).assertEqual('abcdef0123456789012345678901234567890123');
        expect(spec.check.size).assertEqual(999);
      }
    });
  });

  // ============================================================
  //  parseDoneEventToBatchResult
  // ============================================================
  describe('MavenSpecBuilder.parseDoneEventToBatchResult', () => {

    it('全部成功：ok=N, failed=0', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
      ];
      let buildResult = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let view = makeViewForBatch(true, []);
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      expect(result.ok).assertEqual(2);
      expect(result.failed).assertEqual(0);
      expect(result.errors.length).assertEqual(0);
      expect(result.failedNames.length).assertEqual(0);
    });

    it('部分失败：把 failedFiles 反查为 lib name', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
      ];
      let buildResult = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let failedPath = buildResult.specs[0].localPath;
      let failedFiles: DownloadFailedFile[] = [
        makeFailedFileForBatch(failedPath, 'fabric-loader-0.16.10.jar', 'NetworkError', 'connection refused'),
      ];
      let view = makeViewForBatch(false, failedFiles);
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      expect(result.ok).assertEqual(1);
      expect(result.failed).assertEqual(1);
      expect(result.failedNames.length).assertEqual(1);
      expect(result.failedNames[0]).assertEqual('net.fabricmc:fabric-loader:0.16.10');
      expect(result.errors.length).assertEqual(1);
      expect(result.errors[0].indexOf('net.fabricmc:fabric-loader:0.16.10') >= 0).assertTrue();
      expect(result.errors[0].indexOf('NetworkError') >= 0).assertTrue();
    });

    it('全部失败：ok=0, failed=N', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
      ];
      let buildResult = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let failedFiles: DownloadFailedFile[] = [
        makeFailedFileForBatch(buildResult.specs[0].localPath, 'a.jar', 'HttpStatus404', 'not found'),
        makeFailedFileForBatch(buildResult.specs[1].localPath, 'b.jar', 'NetworkError', 'timeout'),
      ];
      let view = makeViewForBatch(false, failedFiles);
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      expect(result.ok).assertEqual(0);
      expect(result.failed).assertEqual(2);
    });

    it('未知 failedFile 路径不能把失败任务假报为成功', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
      ];
      let buildResult = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let failedFiles: DownloadFailedFile[] = [
        makeFailedFileForBatch('/some/unknown/path.jar', 'unknown.jar', 'NetworkError', 'orphan'),
      ];
      let view = makeViewForBatch(false, failedFiles);
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      // 无法绑定失败身份就不能确认输入成功；按整个输入保守失败，而不是静默丢行。
      expect(result.ok).assertEqual(0);
      expect(result.failed).assertEqual(1);
      expect(result.failedNames[0]).assertEqual(libs[0].name);
    });

    it('非法坐标与下载失败合并时保持输入计数', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
        { name: 'org.lwjgl:lwjgl:3.3.1' },
        { name: 'invalid-coordinate' },
      ];
      let built = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let view = makeViewForBatch(false, [
        makeFailedFileForBatch(built.specs[0].localPath, 'fabric-loader.jar', 'ProtocolError', 'HTTP 404'),
      ]);
      let result = parseDoneEventToBatchResult(view, libs, built.pathToName, built.invalidNames);
      expect(result.ok).assertEqual(1);
      expect(result.failed).assertEqual(2);
      expect(result.ok + result.failed).assertEqual(libs.length);
      expect(result.failedNames.indexOf('invalid-coordinate') >= 0).assertTrue();
    });

    it('取消及重复非法输入不虚增成功项', 0, () => {
      let libs: MavenLibEntry[] = [{ name: 'bad' }, { name: 'bad' }];
      let built = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let view = makeViewForBatch(false, []);
      view.aborted = true;
      let result = parseDoneEventToBatchResult(view, libs, built.pathToName, built.invalidNames);
      expect(result.ok).assertEqual(0);
      expect(result.failed).assertEqual(2);
      expect(result.failedNames.length).assertEqual(1);
    });

    it('view 无 failedFiles 但 success=false 时降级处理', 0, () => {
      let libs: MavenLibEntry[] = [
        { name: 'net.fabricmc:fabric-loader:0.16.10' },
      ];
      let buildResult = buildSpecsForLibs(libs, MC_LIB_DIR_T);
      let view = makeViewForBatch(false, []);
      view.errorMessage = 'CA bundle not initialized';
      let result = parseDoneEventToBatchResult(view, libs, buildResult.pathToName);
      // 整体失败但无具体文件信息：全部归为 failed
      expect(result.failed).assertEqual(1);
      expect(result.errors.length > 0).assertTrue();
    });

    it('空 libs 输入 → 空结果', 0, () => {
      let view = makeViewForBatch(true, []);
      let result = parseDoneEventToBatchResult(view, [], new Map<string, string>());
      expect(result.ok).assertEqual(0);
      expect(result.failed).assertEqual(0);
    });
  });
}
