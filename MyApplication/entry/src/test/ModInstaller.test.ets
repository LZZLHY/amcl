/*
 * ModInstaller.test.ets — 模组安装器纯函数单元测试（P1-MODS Phase 1.5）
 *
 * 覆盖：
 *   - isDisabledFilename / disableFilename / enableFilename / toggleEnabledFilename
 *   - buildDownloadSpec / buildDownloadSpecs：RemoteFile → DownloadFileSpec
 *   - buildTaskName：任务名拼装
 *
 * 不覆盖（依赖 fileIo / DownloadManager）：installBatch / setEnabled / delete / ensureDir
 * 这些留给真机集成测试或 ohosTest。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  isDisabledFilename,
  disableFilename,
  enableFilename,
  toggleEnabledFilename,
  buildDownloadSpec,
  buildDownloadSpecs,
  buildTaskName,
} from 'mods';
import { ResourceKind, RemoteFile } from 'mods';

function makeFile(
  filename: string, url: string, size: number, sha1?: string,
  mirrors: string[] = [],
): RemoteFile {
  let rf: RemoteFile = { url, mirrors, filename, size, isPrimary: true };
  if (sha1 !== undefined) rf.sha1 = sha1;
  return rf;
}

export default function modInstallerTest() {

  // ==========================================================
  //  文件名启用/禁用切换
  // ==========================================================
  describe('ModInstaller 启用禁用后缀', () => {
    it('isDisabledFilename：识别 .disabled 后缀', 0, () => {
      expect(isDisabledFilename('sodium.jar')).assertFalse();
      expect(isDisabledFilename('sodium.jar.disabled')).assertTrue();
      expect(isDisabledFilename('Faithful.zip.disabled')).assertTrue();
      expect(isDisabledFilename('')).assertFalse();
    });

    it('disableFilename：已启用 → 追加 .disabled', 0, () => {
      expect(disableFilename('sodium.jar')).assertEqual('sodium.jar.disabled');
      expect(disableFilename('Faithful.zip')).assertEqual('Faithful.zip.disabled');
    });

    it('disableFilename：已禁用原样返回', 0, () => {
      expect(disableFilename('sodium.jar.disabled')).assertEqual('sodium.jar.disabled');
    });

    it('enableFilename：已禁用 → 去 .disabled', 0, () => {
      expect(enableFilename('sodium.jar.disabled')).assertEqual('sodium.jar');
      expect(enableFilename('Faithful.zip.disabled')).assertEqual('Faithful.zip');
    });

    it('enableFilename：未禁用原样返回', 0, () => {
      expect(enableFilename('sodium.jar')).assertEqual('sodium.jar');
    });

    it('toggleEnabledFilename：期望态驱动', 0, () => {
      expect(toggleEnabledFilename('sodium.jar', true)).assertEqual('sodium.jar');
      expect(toggleEnabledFilename('sodium.jar', false)).assertEqual('sodium.jar.disabled');
      expect(toggleEnabledFilename('sodium.jar.disabled', true)).assertEqual('sodium.jar');
      expect(toggleEnabledFilename('sodium.jar.disabled', false)).assertEqual('sodium.jar.disabled');
    });

    it('toggleEnabledFilename 幂等：连续调用同态不变', 0, () => {
      let a = toggleEnabledFilename('sodium.jar', false);
      let b = toggleEnabledFilename(a, false);
      expect(a).assertEqual(b);
    });
  });

  // ==========================================================
  //  buildDownloadSpec / buildDownloadSpecs
  // ==========================================================
  describe('ModInstaller.buildDownloadSpec', () => {
    it('含 sha1 → check 含 sha1 + size', 0, () => {
      let f = makeFile('sodium.jar', 'https://a/b.jar', 1024, 'deadbeef');
      let spec = buildDownloadSpec(f, '/mods');
      expect(spec.localPath).assertEqual('/mods/sodium.jar');
      expect(spec.urls.length).assertEqual(1);
      expect(spec.urls[0]).assertEqual('https://a/b.jar');
      expect(spec.check !== undefined).assertTrue();
      if (spec.check) {
        expect(spec.check.sha1).assertEqual('deadbeef');
        expect(spec.check.size).assertEqual(1024);
      }
    });

    it('无 sha1 但 size>0 → 弱 size 校验', 0, () => {
      let f = makeFile('x.jar', 'https://a/x.jar', 2048);
      let spec = buildDownloadSpec(f, '/mods');
      expect(spec.check !== undefined).assertTrue();
      if (spec.check) {
        expect(spec.check.sha1 === undefined).assertTrue();
        expect(spec.check.size).assertEqual(2048);
      }
    });

    it('size=0 且无 sha1 → 无 check', 0, () => {
      let f = makeFile('y.jar', 'https://a/y.jar', 0);
      let spec = buildDownloadSpec(f, '/mods');
      expect(spec.check === undefined).assertTrue();
    });

    it('mirrors 合并到 urls 尾部', 0, () => {
      let f = makeFile('a.jar', 'https://p/a.jar', 10, 'aa', ['https://m1/a.jar', 'https://m2/a.jar']);
      let spec = buildDownloadSpec(f, '/mods');
      expect(spec.urls.length).assertEqual(3);
      expect(spec.urls[0]).assertEqual('https://p/a.jar');
      expect(spec.urls[1]).assertEqual('https://m1/a.jar');
      expect(spec.urls[2]).assertEqual('https://m2/a.jar');
    });

    it('targetDir 尾部不加斜杠时路径正确', 0, () => {
      let f = makeFile('a.jar', 'https://p/a.jar', 10);
      let spec = buildDownloadSpec(f, '/mods');
      expect(spec.localPath).assertEqual('/mods/a.jar');
    });

    it('targetDir 已带尾斜杠时不重复（当前实现允许 // 出现）', 0, () => {
      // 设计约定：调用方传"不带尾斜杠"的 targetDir（与 resourceKindToInstallDir 约定一致）
      let f = makeFile('a.jar', 'https://p/a.jar', 10);
      let spec = buildDownloadSpec(f, '/mods/');
      expect(spec.localPath).assertEqual('/mods//a.jar');
    });
  });

  describe('ModInstaller.buildDownloadSpecs', () => {
    it('按输入顺序映射', 0, () => {
      let files: RemoteFile[] = [
        makeFile('a.jar', 'https://a', 100, 'aa'),
        makeFile('b.jar', 'https://b', 200, 'bb'),
      ];
      let specs = buildDownloadSpecs(files, '/mods');
      expect(specs.length).assertEqual(2);
      expect(specs[0].localPath).assertEqual('/mods/a.jar');
      expect(specs[1].localPath).assertEqual('/mods/b.jar');
    });

    it('空数组 → 空结果', 0, () => {
      expect(buildDownloadSpecs([], '/mods').length).assertEqual(0);
    });
  });

  // ==========================================================
  //  buildTaskName
  // ==========================================================
  describe('ModInstaller.buildTaskName', () => {
    it('MOD 单文件', 0, () => {
      expect(buildTaskName(ResourceKind.MOD, 'sodium.jar', 0))
        .assertEqual('mod: sodium.jar');
    });

    it('MOD 带 1 个依赖', 0, () => {
      expect(buildTaskName(ResourceKind.MOD, 'sodium.jar', 1))
        .assertEqual('mod: sodium.jar + 1 deps');
    });

    it('MOD 带多个依赖', 0, () => {
      expect(buildTaskName(ResourceKind.MOD, 'sodium.jar', 3))
        .assertEqual('mod: sodium.jar + 3 deps');
    });

    it('RESOURCE_PACK', 0, () => {
      expect(buildTaskName(ResourceKind.RESOURCE_PACK, 'Faithful.zip', 0))
        .assertEqual('resourcepack: Faithful.zip');
    });

    it('SHADER', 0, () => {
      expect(buildTaskName(ResourceKind.SHADER, 'Complementary.zip', 0))
        .assertEqual('shader: Complementary.zip');
    });

    it('DATAPACK / MODPACK 也有映射', 0, () => {
      expect(buildTaskName(ResourceKind.DATAPACK, 'x.zip', 0)).assertEqual('datapack: x.zip');
      expect(buildTaskName(ResourceKind.MODPACK, 'y.mrpack', 10)).assertEqual('modpack: y.mrpack + 10 deps');
    });

    it('负数 extraCount 视为 0', 0, () => {
      expect(buildTaskName(ResourceKind.MOD, 'a.jar', -1)).assertEqual('mod: a.jar');
    });
  });
}
