import { describe, it, expect } from '@ohos/hypium';
import { ModDescriptor, ModEnvironment, ModRequirement, matchesModVersion, validateModSet } from 'mods';

function fixtureMod(id: string, version: string): ModDescriptor {
  return { id: id, name: id, version: version, loader: 'fabric', environment: '*', provides: [],
    depends: [], breaks: [], nested: false, file: id + '.jar' };
}

export default function modInstallContractTest(): void {
  describe('ModInstallContract', () => {
    it('Fabric 构建元数据不绕过冲突范围', 0, () => {
      expect(matchesModVersion('1.10.7+mc1.21.11', ['<=1.10.7']).matches).assertTrue();
      expect(matchesModVersion('1.10.7+mc1.21.11', ['<=1.10.5']).matches).assertFalse();
      expect(matchesModVersion('6.7', ['>=6.6.3 <6.7']).matches).assertFalse();
    });
    it('单向依赖满足仍必须检查反向冲突', 0, () => {
      const iris = fixtureMod('iris', '1.10.7');
      const sodium = fixtureMod('sodium', '0.8.14');
      const needs: ModRequirement = { id: 'sodium', ranges: ['0.8.x'], syntax: 'fabric', optional: false };
      const breaks: ModRequirement = { id: 'iris', ranges: ['<=1.10.7'], syntax: 'fabric', optional: false };
      iris.depends.push(needs);
      sodium.breaks.push(breaks);
      const env: ModEnvironment = { loader: 'fabric', loaderVersion: '0.19.5', gameVersion: '1.21.11', javaVersion: '21' };
      expect(validateModSet([iris, sodium], env).length > 0).assertTrue();
      sodium.version = '0.8.7';
      sodium.breaks[0].ranges = ['<=1.10.5'];
      expect(validateModSet([iris, sodium], env).length).assertEqual(0);
    });
    it('无法识别的排序约束不默认为兼容', 0, () => {
      expect(matchesModVersion('opaque', ['>=other']).supported).assertFalse();
    });
  });
}
