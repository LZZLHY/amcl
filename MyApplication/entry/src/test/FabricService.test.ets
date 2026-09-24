/*
 * FabricService.test.ets — FabricService 静态纯函数单元测试
 *
 * 覆盖范围：
 *   - parseFabricVersionId  版本 ID 字符串 → { loaderVersion, gameVersion }
 *
 * 这是 ModLoaderManager.detectModLoader 的关键依赖，必须严格覆盖
 * 因为任何误判会导致扫描错误的版本为 Fabric。
 *
 * 新增日期：2026-05-04
 */

import { describe, it, expect } from '@ohos/hypium';
import { FabricService } from 'feature_core';

export default function fabricServiceTest() {
  describe('FabricService.parseFabricVersionId', () => {

    it('标准 1.20.x MC 版本解析', 0, () => {
      let info = FabricService.parseFabricVersionId('fabric-loader-0.16.10-1.20.4');
      expect(info !== null).assertTrue();
      if (info !== null) {
        expect(info.loaderVersion).assertEqual('0.16.10');
        expect(info.gameVersion).assertEqual('1.20.4');
      }
    });

    it('老版 1.8.9 MC 版本解析', 0, () => {
      let info = FabricService.parseFabricVersionId('fabric-loader-0.16.10-1.8.9');
      expect(info !== null).assertTrue();
      if (info !== null) {
        expect(info.loaderVersion).assertEqual('0.16.10');
        expect(info.gameVersion).assertEqual('1.8.9');
      }
    });

    it('短版本 1.21 解析', 0, () => {
      let info = FabricService.parseFabricVersionId('fabric-loader-0.16.9-1.21');
      expect(info !== null).assertTrue();
      if (info !== null) {
        expect(info.loaderVersion).assertEqual('0.16.9');
        expect(info.gameVersion).assertEqual('1.21');
      }
    });

    it('非 fabric-loader 前缀返回 null', 0, () => {
      expect(FabricService.parseFabricVersionId('1.20.4-forge-49.0.30') === null).assertTrue();
      expect(FabricService.parseFabricVersionId('1.20.4') === null).assertTrue();
      expect(FabricService.parseFabricVersionId('forge-loader-xx') === null).assertTrue();
    });

    it('空字符串返回 null', 0, () => {
      expect(FabricService.parseFabricVersionId('') === null).assertTrue();
    });

    it('仅 prefix 无内容返回 null', 0, () => {
      expect(FabricService.parseFabricVersionId('fabric-loader-') === null).assertTrue();
    });

    it('loader 版本含多段的版本号', 0, () => {
      // Fabric loader 的完整版本号可能包含 beta / rc
      let info = FabricService.parseFabricVersionId('fabric-loader-0.15.11-1.20.4');
      expect(info !== null).assertTrue();
      if (info !== null) {
        expect(info.loaderVersion).assertEqual('0.15.11');
        expect(info.gameVersion).assertEqual('1.20.4');
      }
    });

    it('旧版 snapshot（24w 格式）fallback 到第一个 dash', 0, () => {
      // 没有 "-1." 模式时应 fallback 到第一个 "-"
      // 输入 "fabric-loader-0.16.10-24w33a"
      // 去掉 prefix 后 rest = "0.16.10-24w33a"
      // 没有 "-1." → 找第一个 "-" → index=7 → loader=0.16.10, game=24w33a
      let info = FabricService.parseFabricVersionId('fabric-loader-0.16.10-24w33a');
      expect(info !== null).assertTrue();
      if (info !== null) {
        expect(info.loaderVersion).assertEqual('0.16.10');
        expect(info.gameVersion).assertEqual('24w33a');
      }
    });
  });
}
