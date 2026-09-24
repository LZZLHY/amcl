/*
 * Phases.test.ets — Phase 6.3 6 个 phase 类的契约 sanity 测试
 *
 * 测试目标（小但保命）：
 *   - 每个 phase 类都实现 IDownloadPhase（编译期已经通过 implements 保证，
 *     这里再用运行时 expect 锁住 name / weight 不被无意改动）
 *   - DownloadFlowState 构造行为：派生路径正确（tempDir / tempVersionDir / targetDir）
 *
 * 不在本测试范围内：
 *   - 实际下载行为：McDownloader 内部走 NAPI 引擎 / http.createHttp，
 *     需真实文件系统 + 网络，归到 ohosTest 集成测试或真机回归
 *   - ModLoaderManager.install：依赖 Forge installer 子进程，归真机回归
 *   - VersionJsonMerger.merge：纯文件 IO，已有专门测试或归集成测试
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 6.3
 *
 * 创建日期：2026-05-06
 */

import { describe, it, expect } from '@ohos/hypium';
import { DownloadFlowState } from 'feature_core';
import { PreparePhase } from 'feature_core';
import { ClientPhase } from 'feature_core';
import { LibrariesPhase } from 'feature_core';
import { AssetsPhase } from 'feature_core';
import { ModloaderPhase } from 'feature_core';
import { MergePhase } from 'feature_core';
import { McDownloader } from 'feature_core';
import { ModLoaderManager } from 'feature_core';
import { ModLoaderType } from 'feature_core';

function makeState(loaderType: ModLoaderType | null = null): DownloadFlowState {
  return new DownloadFlowState(
    /*gameVersion*/ '1.20.4',
    /*loaderType*/ loaderType,
    /*loaderVersion*/ loaderType ? '49.0.30' : '',
    /*versionName*/ '1.20.4-test',
    /*mcDir*/ '/data/storage/el2/base/.amcl/.minecraft',
    /*filesDir*/ '/data/storage/el2/base/files',
  );
}

export default function phasesContractTest() {

  // ============================================================
  //  DownloadFlowState 构造路径派生
  // ============================================================
  describe('DownloadFlowState 派生路径', () => {

    it('tempDir = mcDir + "/download-temp"', 0, () => {
      let s = makeState();
      expect(s.tempDir).assertEqual('/data/storage/el2/base/.amcl/.minecraft/download-temp');
    });

    it('tempVersionDir = tempDir + "/versions/" + gameVersion', 0, () => {
      let s = makeState();
      expect(s.tempVersionDir).assertEqual(
        '/data/storage/el2/base/.amcl/.minecraft/download-temp/versions/1.20.4');
    });

    it('targetDir = mcDir + "/versions/" + versionName', 0, () => {
      let s = makeState();
      expect(s.targetDir).assertEqual(
        '/data/storage/el2/base/.amcl/.minecraft/versions/1.20.4-test');
    });

    it('tempJsonPath 默认 = tempVersionDir + "/" + gameVersion + ".json"', 0, () => {
      let s = makeState();
      expect(s.tempJsonPath).assertEqual(
        '/data/storage/el2/base/.amcl/.minecraft/download-temp/versions/1.20.4/1.20.4.json');
    });

    it('初始可变字段：versionInfo=null, loaderJsonPath=null, installSandboxDir=空', 0, () => {
      let s = makeState();
      expect(s.versionInfo).assertNull();
      expect(s.loaderJsonPath).assertNull();
      expect(s.installSandboxDir).assertEqual('');
      expect(s.cancelled).assertFalse();
    });

    it('loaderType 透传', 0, () => {
      let vanilla = makeState(null);
      expect(vanilla.loaderType).assertNull();
      let forge = makeState(ModLoaderType.FORGE);
      expect(forge.loaderType).assertEqual(ModLoaderType.FORGE);
    });
  });

  // ============================================================
  //  Phase 契约：name / weight
  // ============================================================
  describe('Phase 类 IDownloadPhase 契约', () => {

    it('PreparePhase: name=prepare weight=2', 0, () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new PreparePhase(s, mcDl);
      expect(p.name).assertEqual('prepare');
      expect(p.weight).assertEqual(2);
    });

    it('ClientPhase: name=client weight=15', 0, () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new ClientPhase(s, mcDl);
      expect(p.name).assertEqual('client');
      expect(p.weight).assertEqual(15);
    });

    it('LibrariesPhase: name=libraries weight=25', 0, () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new LibrariesPhase(s, mcDl);
      expect(p.name).assertEqual('libraries');
      expect(p.weight).assertEqual(25);
    });

    it('AssetsPhase: name=assets weight=45', 0, () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new AssetsPhase(s, mcDl);
      expect(p.name).assertEqual('assets');
      expect(p.weight).assertEqual(45);
    });

    it('ModloaderPhase: name=modloader weight=10', 0, () => {
      let s = makeState(ModLoaderType.FORGE);
      let mgr = new ModLoaderManager();
      let p = new ModloaderPhase(s, mgr);
      expect(p.name).assertEqual('modloader');
      expect(p.weight).assertEqual(10);
    });

    it('MergePhase: name=merge weight=3', 0, () => {
      let s = makeState();
      let p = new MergePhase(s);
      expect(p.name).assertEqual('merge');
      expect(p.weight).assertEqual(3);
    });

    it('权重总和 (有 modloader): 100 = 2+15+25+45+10+3', 0, () => {
      let total = 2 + 15 + 25 + 45 + 10 + 3;
      expect(total).assertEqual(100);
    });

    it('权重总和 (无 modloader): 90 = 2+15+25+45+3', 0, () => {
      let total = 2 + 15 + 25 + 45 + 3;
      expect(total).assertEqual(90);
    });
  });

  // ============================================================
  //  自定义权重支持（DownloadTask 可以传入老 PHASE_WEIGHTS_MC 数值）
  // ============================================================
  describe('Phase 类自定义 weight', () => {

    it('PreparePhase 接受 weight ctor 参数', 0, () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new PreparePhase(s, mcDl, 7);
      expect(p.weight).assertEqual(7);
    });

    it('MergePhase 接受 weight ctor 参数', 0, () => {
      let s = makeState();
      let p = new MergePhase(s, 99);
      expect(p.weight).assertEqual(99);
    });
  });

  // ============================================================
  //  cancel 提前抛出 '已取消'
  // ============================================================
  describe('Phase 取消语义', () => {

    it('PreparePhase: state.cancelled=true 时 run 抛 "已取消"', 0, async () => {
      let s = makeState();
      s.cancelled = true;
      let mcDl = new McDownloader(s.mcDir);
      let p = new PreparePhase(s, mcDl);
      let threw = false;
      try {
        await p.run({
          taskId: 'x', versionName: 'x', gameVersion: 'x',
          loaderType: 'vanilla', mcDir: '/x', filesDir: '/x',
        }, () => {});
      } catch (e) {
        threw = true;
        expect((e as Error).message).assertEqual('已取消');
      }
      expect(threw).assertTrue();
    });

    it('ClientPhase: versionInfo=null 时 run 抛 "需要先跑 PreparePhase"', 0, async () => {
      let s = makeState();
      let mcDl = new McDownloader(s.mcDir);
      let p = new ClientPhase(s, mcDl);
      let threw = false;
      try {
        await p.run({
          taskId: 'x', versionName: 'x', gameVersion: 'x',
          loaderType: 'vanilla', mcDir: '/x', filesDir: '/x',
        }, () => {});
      } catch (e) {
        threw = true;
        expect((e as Error).message.indexOf('versionInfo 为空') >= 0).assertTrue();
      }
      expect(threw).assertTrue();
    });
  });
}
