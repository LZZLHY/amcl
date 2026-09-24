import { describe, it, expect } from '@ohos/hypium';
import { applyGameCompatibility, gameCompatibilityPath, LoaderGeneration } from 'launch';

export default function runtimeCompatibilityTest(): void {
  describe('RuntimeCompatibility', (): void => {
    it('preserves user mods and injects one immutable artifact', 0, (): void => {
      const before: string[] = ['-Xms1024m', '-Dfabric.addMods=/user/a.jar:/user/b.jar'];
      const actual: string[] = applyGameCompatibility(before, '1.21.11', LoaderGeneration.FabricKnot, '/files');
      expect(actual.join('|')).assertEqual('-Xms1024m|-Dfabric.addMods=/user/a.jar:/user/b.jar:' + gameCompatibilityPath('/files'));
      expect(applyGameCompatibility(actual, '1.21.11', LoaderGeneration.FabricKnot, '/files').join('|')).assertEqual(actual.join('|'));
    });
    it('leaves unrelated versions and loaders unchanged', 0, (): void => {
      const args: string[] = ['-Dfabric.addMods=/user/a.jar'];
      expect(applyGameCompatibility(args, '1.21.10', LoaderGeneration.FabricKnot, '/files').join('|')).assertEqual(args.join('|'));
      expect(applyGameCompatibility(args, '1.21.11', LoaderGeneration.NeoForge, '/files').join('|')).assertEqual(args.join('|'));
      expect(applyGameCompatibility(args, '1.21.11', LoaderGeneration.Vanilla, '/files').join('|')).assertEqual(args.join('|'));
    });
    it('26.2 Fabric 交付按目标类指纹门控的兼容包，其他加载器保持原参数', 0, (): void => {
      const args: string[] = ['-Dfabric.addMods=/user/a.jar'];
      const actual = applyGameCompatibility(args, '26.2', LoaderGeneration.FabricKnot, '/files');
      expect(actual.join('|')).assertEqual('-Dfabric.addMods=/user/a.jar:' + gameCompatibilityPath('/files'));
      expect(applyGameCompatibility(actual, '26.2', LoaderGeneration.FabricKnot, '/files').join('|')).assertEqual(actual.join('|'));
      expect(applyGameCompatibility(args, '26.2', LoaderGeneration.NeoForge, '/files').join('|')).assertEqual(args.join('|'));
    });
  });
}
