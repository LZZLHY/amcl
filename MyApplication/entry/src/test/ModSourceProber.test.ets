/*
 * ModSourceProber.test.ets — Modrinth 源偏好决策（P1-MODS Phase 1.3）
 *
 * 仅覆盖纯函数 `decideModrinthMode` + 模块级状态 getter 的边界行为。
 * 网络探测（http.createHttp）留给真机集成测试，此处不验证。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  decideModrinthMode,
  getModrinthSourceMode,
  getCachedModRanking,
  clearModrinthRankingCache,
} from 'mods';
import { ModrinthSourceMode } from 'mods';

export default function modSourceProberTest() {

  // ==========================================================
  //  decideModrinthMode（纯函数）
  // ==========================================================
  describe('ModSourceProber.decideModrinthMode', () => {
    it('MCIM 更快 → MCIM_FIRST', 0, () => {
      expect(decideModrinthMode(true, 50, true, 200))
        .assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });

    it('官方更快 → OFFICIAL_FIRST', 0, () => {
      expect(decideModrinthMode(true, 500, true, 100))
        .assertEqual(ModrinthSourceMode.OFFICIAL_FIRST);
    });

    it('RTT 相等 → MCIM_FIRST（国内用户居多）', 0, () => {
      expect(decideModrinthMode(true, 200, true, 200))
        .assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });

    it('只 MCIM 可用 → MCIM_FIRST', 0, () => {
      expect(decideModrinthMode(true, 200, false, -1))
        .assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });

    it('只官方可用 → OFFICIAL_FIRST', 0, () => {
      expect(decideModrinthMode(false, -1, true, 100))
        .assertEqual(ModrinthSourceMode.OFFICIAL_FIRST);
    });

    it('两端都不可用 → MCIM_FIRST（保守默认）', 0, () => {
      expect(decideModrinthMode(false, -1, false, -1))
        .assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });
  });

  // ==========================================================
  //  模块级状态：getter 初值 + clear 语义
  // ==========================================================
  describe('ModSourceProber 模块状态', () => {
    it('未 probe 时 getModrinthSourceMode 返回 MCIM_FIRST', 0, () => {
      clearModrinthRankingCache();
      expect(getModrinthSourceMode()).assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });

    it('未 probe 时 getCachedModRanking 返回 null', 0, () => {
      clearModrinthRankingCache();
      expect(getCachedModRanking()).assertNull();
    });

    it('clearModrinthRankingCache 是幂等的', 0, () => {
      clearModrinthRankingCache();
      clearModrinthRankingCache();
      expect(getModrinthSourceMode()).assertEqual(ModrinthSourceMode.MCIM_FIRST);
    });
  });
}
