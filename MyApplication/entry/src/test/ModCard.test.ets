/*
 * ModCard.test.ets — ModCard 组件的纯函数工具单测（P1-MODS Phase 1.6）
 *
 * 仅测试纯函数：formatDownloadCount / kindEmoji / sourceLabel。
 * UI 渲染部分由真机验证（Phase 1.8）。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import { formatDownloadCount, kindEmoji, sourceLabel } from '../main/ets/components/ModCard';
import { ResourceKind, ModSource } from 'mods';

export default function modCardTest() {

  describe('ModCard.formatDownloadCount', () => {
    it('< 1000 → 原值', 0, () => {
      expect(formatDownloadCount(0)).assertEqual('0');
      expect(formatDownloadCount(1)).assertEqual('1');
      expect(formatDownloadCount(999)).assertEqual('999');
    });

    it('1k - 1M → N.Nk', 0, () => {
      expect(formatDownloadCount(1000)).assertEqual('1.0k');
      expect(formatDownloadCount(12345)).assertEqual('12.3k');
      expect(formatDownloadCount(999999)).assertEqual('1000.0k');
    });

    it('1M - 1B → N.NM', 0, () => {
      expect(formatDownloadCount(1_000_000)).assertEqual('1.0M');
      expect(formatDownloadCount(50_000_000)).assertEqual('50.0M');
    });

    it('≥ 1B → N.NB', 0, () => {
      expect(formatDownloadCount(1_000_000_000)).assertEqual('1.0B');
    });

    it('负数 → "-"', 0, () => {
      expect(formatDownloadCount(-1)).assertEqual('-');
    });
  });

  describe('ModCard.kindEmoji', () => {
    it('每种类别都有 emoji', 0, () => {
      expect(kindEmoji(ResourceKind.MOD).length > 0).assertTrue();
      expect(kindEmoji(ResourceKind.RESOURCE_PACK).length > 0).assertTrue();
      expect(kindEmoji(ResourceKind.SHADER).length > 0).assertTrue();
      expect(kindEmoji(ResourceKind.DATAPACK).length > 0).assertTrue();
      expect(kindEmoji(ResourceKind.MODPACK).length > 0).assertTrue();
    });

    it('不同类别使用不同 emoji', 0, () => {
      let seen: Set<string> = new Set<string>();
      seen.add(kindEmoji(ResourceKind.MOD));
      seen.add(kindEmoji(ResourceKind.RESOURCE_PACK));
      seen.add(kindEmoji(ResourceKind.SHADER));
      seen.add(kindEmoji(ResourceKind.DATAPACK));
      seen.add(kindEmoji(ResourceKind.MODPACK));
      expect(seen.size).assertEqual(5);
    });
  });

  describe('ModCard.sourceLabel', () => {
    it('modrinth → Modrinth', 0, () => {
      expect(sourceLabel(ModSource.MODRINTH)).assertEqual('Modrinth');
    });

    it('curseforge → CurseForge', 0, () => {
      expect(sourceLabel(ModSource.CURSEFORGE)).assertEqual('CurseForge');
    });
  });
}
