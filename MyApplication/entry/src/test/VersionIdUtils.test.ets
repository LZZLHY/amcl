/**
 * VersionIdUtils.test.ets — P0 修复 #2/#7 单元测试
 *
 * 覆盖 detectLoaderFromId + extractGameVersionFromId 在常见目录命名下的行为。
 *
 * 创建日期：2026-05-11（P0 审查修复）
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  detectLoaderFromId,
  extractGameVersionFromId,
  isSnapshotVersion,
  classifyVersion,
} from 'mods';

export default function versionIdUtilsTest() {
  describe('VersionIdUtils.detectLoaderFromId', () => {
    it('原版目录名 → 空字符串', 0, () => {
      expect(detectLoaderFromId('1.20.4')).assertEqual('');
      expect(detectLoaderFromId('1.16.5')).assertEqual('');
      expect(detectLoaderFromId('1.21')).assertEqual('');
    });

    it('HMCL/AMCL 推荐命名（loader 后缀）', 0, () => {
      expect(detectLoaderFromId('1.20.4-fabric-0.16.10')).assertEqual('fabric');
      expect(detectLoaderFromId('1.16.5-forge-36.2.39')).assertEqual('forge');
      expect(detectLoaderFromId('1.20.4-neoforge-20.4.196')).assertEqual('neoforge');
      expect(detectLoaderFromId('1.20.4-quilt-0.27.0')).assertEqual('quilt');
    });

    it('Loader 安装器原始命名（loader 前缀）', 0, () => {
      expect(detectLoaderFromId('fabric-loader-0.16.10-1.20.4')).assertEqual('fabric');
      expect(detectLoaderFromId('forge-1.20.4-49.0.30')).assertEqual('forge');
      expect(detectLoaderFromId('quilt-loader-0.27.0-1.20.4')).assertEqual('quilt');
    });

    it('NeoForge 优先于 Forge（避免 neoforge 命中 forge 子串）', 0, () => {
      expect(detectLoaderFromId('1.20.4-neoforge-20.4.196')).assertEqual('neoforge');
      expect(detectLoaderFromId('neoforge-1.20.4-20.4.196')).assertEqual('neoforge');
      expect(detectLoaderFromId('1.20.4-neo-forge-20.4')).assertEqual('neoforge');
    });

    it('大小写不敏感', 0, () => {
      expect(detectLoaderFromId('1.20.4-FABRIC-0.16')).assertEqual('fabric');
      expect(detectLoaderFromId('1.16.5-Forge-36.2.39')).assertEqual('forge');
    });

    it('空字符串 → 空字符串', 0, () => {
      expect(detectLoaderFromId('')).assertEqual('');
    });

    it('快照版本（无 loader）→ 空字符串', 0, () => {
      expect(detectLoaderFromId('24w14a')).assertEqual('');
      expect(detectLoaderFromId('23w13a_or_b')).assertEqual('');
    });
  });

  describe('VersionIdUtils.extractGameVersionFromId', () => {
    it('原版目录名直接返回', 0, () => {
      expect(extractGameVersionFromId('1.20.4')).assertEqual('1.20.4');
      expect(extractGameVersionFromId('1.16.5')).assertEqual('1.16.5');
      expect(extractGameVersionFromId('1.21')).assertEqual('1.21');
    });

    it('HMCL 推荐命名（MC-loader-LOADER）取头部', 0, () => {
      expect(extractGameVersionFromId('1.20.4-fabric-0.16.10')).assertEqual('1.20.4');
      expect(extractGameVersionFromId('1.16.5-forge-36.2.39')).assertEqual('1.16.5');
      expect(extractGameVersionFromId('1.20.4-neoforge-20.4.196')).assertEqual('1.20.4');
      expect(extractGameVersionFromId('1.20.4-quilt-0.27.0')).assertEqual('1.20.4');
    });

    it('Loader 原始命名（forge-MC-...）取头部数字', 0, () => {
      // "forge-1.20.4-49.0.30" → 第 1 个数字版本号 = MC
      expect(extractGameVersionFromId('forge-1.20.4-49.0.30')).assertEqual('1.20.4');
      expect(extractGameVersionFromId('neoforge-1.20.4-20.4.196')).assertEqual('1.20.4');
    });

    it('fabric-loader-LOADER-MC 取尾部 MC', 0, () => {
      // 这是 Fabric 安装器原始格式，MC 版本号在尾部
      expect(extractGameVersionFromId('fabric-loader-0.16.10-1.20.4')).assertEqual('1.20.4');
      expect(extractGameVersionFromId('quilt-loader-0.27.0-1.20.4')).assertEqual('1.20.4');
    });

    it('纪元感知消歧：fabric-<loaderVer>-<mcVer> 取真实 MC 版本（修复 0.19.3 误判 bug）', 0, () => {
      // fabric-0.19.3-26.1.1：0.19.3=UNKNOWN 纪元、26.1.1=YEARLY → 唯一被识别 → 26.1.1
      expect(extractGameVersionFromId('fabric-0.19.3-26.1.1')).assertEqual('26.1.1');
      // 旧纪元同理：0.16.10=UNKNOWN、1.20.4=CLASSIC → 1.20.4
      expect(extractGameVersionFromId('fabric-0.16.10-1.20.4')).assertEqual('1.20.4');
    });

    it('Forge 主版本号与 YEARLY 撞车时按惯例取 MC（forge-<MC>-<LOADER>）', 0, () => {
      // 49.0.30 首段 49 ≥ 纪元年阈值会被判成 YEARLY，与真实 MC 撞车 → 退回惯例取首个
      expect(extractGameVersionFromId('forge-1.20.4-49.0.30')).assertEqual('1.20.4');
      // YEARLY MC + Forge 62.x：26.1 与 62.0.9 都像 YEARLY → 惯例取首个 = 26.1
      expect(extractGameVersionFromId('forge-26.1-62.0.9')).assertEqual('26.1');
    });

    it('快照版本整体保留', 0, () => {
      expect(extractGameVersionFromId('24w14a')).assertEqual('24w14a');
      expect(extractGameVersionFromId('23w13a_or_b')).assertEqual('23w13a_or_b');
    });

    it('Pre-release / Release Candidate 取 MC 主版本号', 0, () => {
      // "1.21-rc1" 头匹配的就是 "1.21"
      expect(extractGameVersionFromId('1.21-rc1')).assertEqual('1.21');
      expect(extractGameVersionFromId('1.20-pre1')).assertEqual('1.20');
    });

    it('空字符串 → 空字符串', 0, () => {
      expect(extractGameVersionFromId('')).assertEqual('');
    });
  });

  describe('VersionIdUtils.isSnapshotVersion', () => {
    it('release 版本 → false', 0, () => {
      expect(isSnapshotVersion('1.20.4')).assertFalse();
      expect(isSnapshotVersion('1.20.4-fabric-0.16.10')).assertFalse();
    });

    it('快照 → true', 0, () => {
      expect(isSnapshotVersion('24w14a')).assertTrue();
      expect(isSnapshotVersion('23w13a_or_b')).assertTrue();
    });

    it('pre-release / rc → true', 0, () => {
      expect(isSnapshotVersion('1.21-rc1')).assertTrue();
      expect(isSnapshotVersion('1.20-pre1')).assertTrue();
    });

    // 2026-05-23 修：'26.2-snapshot-8' 之前因 'snapshot' 关键字未被识别
    // 而走到 release 分支，导致版本图标显示为草方块。
    it('裸 snapshot 关键字 → true', 0, () => {
      expect(isSnapshotVersion('26.2-snapshot-8')).assertTrue();
      expect(isSnapshotVersion('1.21-snapshot-1')).assertTrue();
      expect(isSnapshotVersion('27.0-snapshot1')).assertTrue();
    });

    it('空字符串 → false', 0, () => {
      expect(isSnapshotVersion('')).assertFalse();
    });
  });

  describe('VersionIdUtils.classifyVersion', () => {
    it('正式版 → release', 0, () => {
      expect(classifyVersion('1.20.4') as string).assertEqual('release');
      expect(classifyVersion('1.21') as string).assertEqual('release');
    });

    it('周快照 → snapshot', 0, () => {
      expect(classifyVersion('24w14a') as string).assertEqual('snapshot');
      expect(classifyVersion('23w45c') as string).assertEqual('snapshot');
    });

    it('pre / rc / experimental → snapshot', 0, () => {
      expect(classifyVersion('1.20-pre1') as string).assertEqual('snapshot');
      expect(classifyVersion('1.21-rc1') as string).assertEqual('snapshot');
      expect(classifyVersion('1.21-experimental1') as string).assertEqual('snapshot');
    });

    // ★ 核心回归用例：修复版本管理 sheet / 主页 / 任务卡 / 版本详情
    //   把 '26.2-snapshot-8' 显示为草方块（release 图标）的 bug。
    //   修好后 getMediaForVersion → block_command，命令方块图标。
    it('裸 snapshot 关键字 → snapshot（修复 26.2-snapshot-8 误判 release 的 bug）', 0, () => {
      expect(classifyVersion('26.2-snapshot-8') as string).assertEqual('snapshot');
      expect(classifyVersion('1.21-snapshot-1') as string).assertEqual('snapshot');
      expect(classifyVersion('27.0-snapshot1') as string).assertEqual('snapshot');
    });

    it('loader 优先级高于 snapshot 关键字', 0, () => {
      expect(classifyVersion('1.20.4-fabric-0.16.10') as string).assertEqual('fabric');
      expect(classifyVersion('1.16.5-forge-36.2.39') as string).assertEqual('forge');
      expect(classifyVersion('1.20.4-neoforge-20.4.196') as string).assertEqual('neoforge');
      expect(classifyVersion('1.20.4-quilt-0.27.0') as string).assertEqual('quilt');
    });

    it('愚人节版精确匹配优先于 snapshot 推断', 0, () => {
      expect(classifyVersion('24w14potato') as string).assertEqual('aprilfools');
      expect(classifyVersion('23w13a_or_b') as string).assertEqual('aprilfools');
      expect(classifyVersion('25w14craftmine') as string).assertEqual('aprilfools');
    });

    it('远古版前缀 → old', 0, () => {
      expect(classifyVersion('b1.7.3') as string).assertEqual('old');
      expect(classifyVersion('a1.2.6') as string).assertEqual('old');
      expect(classifyVersion('c0.0.23a') as string).assertEqual('old');
    });

    it('1.0 ~ 1.5 旧 release 算 old', 0, () => {
      expect(classifyVersion('1.5.2') as string).assertEqual('old');
      expect(classifyVersion('1.0') as string).assertEqual('old');
    });

    it('空字符串 → release（兜底）', 0, () => {
      expect(classifyVersion('') as string).assertEqual('release');
    });
  });
}
