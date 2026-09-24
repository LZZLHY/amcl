/*
 * VersionParser.test.ets — VersionParser 纯函数单元测试
 *
 * 覆盖范围：
 *   - mavenNameToPath     Maven 坐标 → 相对路径（version.json 内的 library 无 downloads 时用）
 *   - checkLibraryRules   library rules 过滤逻辑（allow/disallow + os.name 匹配）
 *
 * 不测：parse() / parseData() —— 需读文件或 mock 大对象，放到 integration 层更合适。
 *
 * 关键假设：
 *   - HarmonyOS NEXT 在 rules 判定里被伪装成 "linux"（项目约定）
 *
 * 新增日期：2026-05-04
 */

import { describe, it, expect } from '@ohos/hypium';
import { VersionParser } from 'feature_core';
import { mavenToRelativePath } from 'feature_core';

interface LibRuleOs { name?: string }
interface LibRule { action: string; os?: LibRuleOs }

export default function versionParserTest() {
  describe('VersionParser', () => {

    // ============================================================
    //  mavenNameToPath
    // ============================================================

    it('mavenNameToPath: 基础 g:a:v', 0, () => {
      expect(mavenToRelativePath('org.lwjgl:lwjgl:3.3.1'))
        .assertEqual('org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1.jar');
    });

    it('mavenNameToPath: 带 classifier', 0, () => {
      expect(mavenToRelativePath('org.lwjgl:lwjgl:3.3.1:natives-linux'))
        .assertEqual('org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1-natives-linux.jar');
    });

    it('mavenNameToPath: 带 @extension', 0, () => {
      expect(mavenToRelativePath('net.minecraftforge:forge:1.20.4-49.0.30@zip'))
        .assertEqual('net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30.zip');
    });

    it('mavenNameToPath: classifier + @extension 组合', 0, () => {
      expect(mavenToRelativePath('net.minecraftforge:forge:1.20.4-49.0.30:client@jar'))
        .assertEqual('net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30-client.jar');
    });

    it('mavenNameToPath: Forge 实际场景（带长版本号）', 0, () => {
      expect(mavenToRelativePath('net.minecraftforge:forge:1.20.4-49.0.30:client'))
        .assertEqual('net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30-client.jar');
    });

    it('mavenNameToPath: 尾随冒号（空 classifier）是非法坐标，返回空串', 0, () => {
      // "g:a:v:" 会 split 出一个空段。parseMavenName 的加固校验对每一段都要求
      // safeBaseName 非空，因此整条坐标被拒。
      //
      // 这是有意的 fail-closed，不是"跳过空 classifier"：本函数的输出直接用来拼
      // 本地文件路径，宁可拒绝一个畸形坐标，也不要靠猜测把它规整成看似合理的路径。
      // 早期版本确实是"忽略空 classifier"，加固后改为拒绝；本用例记录的是加固后的契约。
      expect(mavenToRelativePath('org.lwjgl:lwjgl:3.3.1:')).assertEqual('');
    });

    it('mavenNameToPath: 非空 classifier 正常追加（与上一条对照）', 0, () => {
      // 与上一条成对：证明拒绝的是"空段"，而不是把 4 段坐标整体判为非法。
      //
      // MavenUtils.test.ets 也覆盖了 mavenToRelativePath 的同一组坐标。重复是有意保留的：
      // 这里的两条是"尾随冒号被拒"的正负对照，删掉任一条另一条就失去意义；而
      // MavenUtils.test.ets 那组是该函数自身的完整用法矩阵。两处职责不同，不合并。
      expect(mavenToRelativePath('org.lwjgl:lwjgl:3.3.1:natives-linux'))
        .assertEqual('org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1-natives-linux.jar');
    });

    it('mavenNameToPath: 非法坐标返回空串', 0, () => {
      expect(mavenToRelativePath('')).assertEqual('');
      expect(mavenToRelativePath('only:two')).assertEqual('');
    });

    // ============================================================
    //  checkLibraryRules
    // ============================================================

    it('checkLibraryRules: 无 rules → 默认包含', 0, () => {
      expect(VersionParser.checkLibraryRules(undefined)).assertTrue();
      expect(VersionParser.checkLibraryRules([])).assertTrue();
    });

    it('checkLibraryRules: allow 无 os → 包含', 0, () => {
      let rules: LibRule[] = [{ action: 'allow' }];
      expect(VersionParser.checkLibraryRules(rules)).assertTrue();
    });

    it('checkLibraryRules: allow os=linux → 包含（项目假装 linux）', 0, () => {
      let rules: LibRule[] = [{ action: 'allow', os: { name: 'linux' } }];
      expect(VersionParser.checkLibraryRules(rules)).assertTrue();
    });

    it('checkLibraryRules: allow os=windows → 不包含', 0, () => {
      let rules: LibRule[] = [{ action: 'allow', os: { name: 'windows' } }];
      expect(VersionParser.checkLibraryRules(rules)).assertFalse();
    });

    it('checkLibraryRules: allow os=osx → 不包含', 0, () => {
      let rules: LibRule[] = [{ action: 'allow', os: { name: 'osx' } }];
      expect(VersionParser.checkLibraryRules(rules)).assertFalse();
    });

    it('checkLibraryRules: disallow os=windows → 包含（当前 OS 不是 Windows）', 0, () => {
      let rules: LibRule[] = [{ action: 'disallow', os: { name: 'windows' } }];
      // disallow windows 时，linux 仍应被包含
      expect(VersionParser.checkLibraryRules(rules)).assertTrue();
    });

    it('checkLibraryRules: disallow os=linux → 不包含', 0, () => {
      let rules: LibRule[] = [{ action: 'disallow', os: { name: 'linux' } }];
      expect(VersionParser.checkLibraryRules(rules)).assertFalse();
    });

    it('checkLibraryRules: allow all + disallow linux → 不包含（最终 disallow 命中）', 0, () => {
      let rules: LibRule[] = [
        { action: 'allow' },
        { action: 'disallow', os: { name: 'linux' } },
      ];
      expect(VersionParser.checkLibraryRules(rules)).assertFalse();
    });

    it('checkLibraryRules: 仅 allow osx → 不包含（未命中任何 allow）', 0, () => {
      let rules: LibRule[] = [{ action: 'allow', os: { name: 'osx' } }];
      expect(VersionParser.checkLibraryRules(rules)).assertFalse();
    });

    it('checkLibraryRules: 真实 MC 1.20.4 案例 — lwjgl-glfw osx 排除', 0, () => {
      // MC 版本 JSON 里常见的 rules 形式，要求排除 osx 的 natives
      let rules: LibRule[] = [
        { action: 'allow' },
        { action: 'disallow', os: { name: 'osx' } },
      ];
      // 项目在 linux 上应该包含这个 library
      expect(VersionParser.checkLibraryRules(rules)).assertTrue();
    });
  });
}
