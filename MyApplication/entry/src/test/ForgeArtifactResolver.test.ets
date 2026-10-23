/**
 * Forge 发布身份回归：整合包清单只给 Forge build 时，必须保留仓库实际发布的分支。
 * 本套只执行生产纯解析函数，不连接网络、不创建实例；ForgeService 对网络、缓存和
 * 新旧安装器的真实接线由 scripts/test-forge-coordinate.mjs 补充验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { resolveForgeArtifact, hasExplicitForgeBranch } from 'feature_core';

/** 判断不可信请求或歧义是否被解析器拒绝；不能把空返回当成已经正确抛错。 */
function forgeResolutionFails(gameVersion: string, loaderVersion: string, versions: string[]): boolean {
  try {
    resolveForgeArtifact(gameVersion, loaderVersion, versions);
    return false;
  } catch (e) {
    return true;
  }
}

/** 将短版本、显式发布身份和错误输入分别固定为可复跑用例，防止后缀再次在消费链丢失。 */
export default function forgeArtifactResolverTest() {
  describe('ForgeArtifactResolverTest', () => {
    it('1.7.10 整合包短版本选择真实带分支工件', 0, () => {
      let identity = resolveForgeArtifact('1.7.10', '10.13.4.1614', ['1.7.10-10.13.4.1614-1.7.10']);
      expect(identity.artifactVersion).assertEqual('1.7.10-10.13.4.1614-1.7.10');
      expect(identity.loaderVersion).assertEqual('10.13.4.1614-1.7.10');
      expect(identity.versionId).assertEqual('1.7.10-forge-10.13.4.1614-1.7.10');
      expect(identity.metadataMatched).assertTrue();
    });

    it('1.8.9 短版本同样保留真实发布分支', 0, () => {
      let identity = resolveForgeArtifact('1.8.9', '11.15.1.2318', ['1.8.9-11.15.1.2318-1.8.9']);
      expect(identity.artifactVersion).assertEqual('1.8.9-11.15.1.2318-1.8.9');
    });

    it('mc172 分支来自 metadata 而非追加游戏版本', 0, () => {
      let identity = resolveForgeArtifact('1.7.2', '10.12.2.1161', ['1.7.2-10.12.2.1161-mc172']);
      expect(identity.artifactVersion).assertEqual('1.7.2-10.12.2.1161-mc172');
      expect(identity.loaderVersion).assertEqual('10.12.2.1161-mc172');
    });

    it('已有完整 tail 不重复附加分支', 0, () => {
      let identity = resolveForgeArtifact('1.7.10', '10.13.4.1614-1.7.10', ['1.7.10-10.13.4.1614-1.7.10']);
      expect(identity.artifactVersion).assertEqual('1.7.10-10.13.4.1614-1.7.10');
      expect(identity.loaderVersion).assertEqual('10.13.4.1614-1.7.10');
    });

    it('完整 artifact 输入剥除且只剥除同一游戏前缀', 0, () => {
      let identity = resolveForgeArtifact('1.7.2', '1.7.2-10.12.2.1161-mc172', []);
      expect(identity.artifactVersion).assertEqual('1.7.2-10.12.2.1161-mc172');
      expect(identity.loaderVersion).assertEqual('10.12.2.1161-mc172');
      expect(identity.versionId).assertEqual('1.7.2-forge-10.12.2.1161-mc172');
    });

    it('完整现代 artifact 归一化为 loader 而非误判旧 Forge', 0, () => {
      let identity = resolveForgeArtifact('1.20.1', '1.20.1-47.4.26', ['1.20.1-47.4.26']);
      expect(identity.loaderVersion).assertEqual('47.4.26');
      expect(identity.artifactVersion).assertEqual('1.20.1-47.4.26');
    });

    it('当前预发布游戏的完整 artifact 精确剥前缀并保留现代 loader 身份', 0, () => {
      let identity = resolveForgeArtifact('1.20.2-pre4', '1.20.2-pre4-48.0.0', ['1.20.2-pre4-48.0.0']);
      expect(identity.artifactVersion).assertEqual('1.20.2-pre4-48.0.0');
      expect(identity.loaderVersion).assertEqual('48.0.0');
      expect(identity.versionId).assertEqual('1.20.2-pre4-forge-48.0.0');
      expect(identity.metadataMatched).assertTrue();
      expect(hasExplicitForgeBranch('1.20.2-pre4', '1.20.2-pre4-48.0.0')).assertFalse();
    });

    it('显式分支未被落后 metadata 列出仍保留请求身份', 0, () => {
      let identity = resolveForgeArtifact('1.7.2', '10.12.2.1161-mc172', []);
      expect(identity.artifactVersion).assertEqual('1.7.2-10.12.2.1161-mc172');
      expect(identity.metadataMatched).assertFalse();
    });

    it('显式分支不会被另一个同 build 分支替换', 0, () => {
      let identity = resolveForgeArtifact('1.7.2', '10.12.2.1161-mc172', ['1.7.2-10.12.2.1161-other']);
      expect(identity.artifactVersion).assertEqual('1.7.2-10.12.2.1161-mc172');
      expect(identity.metadataMatched).assertFalse();
    });

    it('现代无分支版本保留原有仓库布局', 0, () => {
      let identity = resolveForgeArtifact('1.20.1', '47.4.26', ['1.20.1-47.4.26']);
      expect(identity.artifactVersion).assertEqual('1.20.1-47.4.26');
      expect(identity.versionId).assertEqual('1.20.1-forge-47.4.26');
      expect(identity.metadataMatched).assertTrue();
    });

    it('旧 Forge 无分支版本不添加多余后缀', 0, () => {
      let identity = resolveForgeArtifact('1.12.2', '14.23.5.2864', ['1.12.2-14.23.5.2864']);
      expect(identity.artifactVersion).assertEqual('1.12.2-14.23.5.2864');
      expect(identity.loaderVersion).assertEqual('14.23.5.2864');
    });

    it('确切无分支发布项优先于同 build 的分支项', 0, () => {
      let identity = resolveForgeArtifact('1.7.2', '10.12.2.1161', [
        '1.7.2-10.12.2.1161-mc172', '1.7.2-10.12.2.1161', '1.7.2-10.12.2.1161-other'
      ]);
      expect(identity.artifactVersion).assertEqual('1.7.2-10.12.2.1161');
      expect(identity.metadataMatched).assertTrue();
    });

    it('镜像重复同一分支不构成歧义', 0, () => {
      let identity = resolveForgeArtifact('1.7.10', '10.13.4.1614', [
        '1.7.10-10.13.4.1614-1.7.10', '1.7.10-10.13.4.1614-1.7.10'
      ]);
      expect(identity.artifactVersion).assertEqual('1.7.10-10.13.4.1614-1.7.10');
    });

    it('两个真实分支且无确切无分支项时拒绝猜测', 0, () => {
      expect(forgeResolutionFails('1.7.2', '10.12.2.1161', [
        '1.7.2-10.12.2.1161-mc172', '1.7.2-10.12.2.1161-other'
      ])).assertTrue();
    });

    it('相邻 build 的前缀不能替代明确请求的 build', 0, () => {
      let identity = resolveForgeArtifact('1.7.10', '10.13.4.1614', ['1.7.10-10.13.4.16140-1.7.10']);
      expect(identity.artifactVersion).assertEqual('1.7.10-10.13.4.1614');
      expect(identity.metadataMatched).assertFalse();
    });

    it('相邻游戏版本的前缀不能跨游戏匹配', 0, () => {
      let identity = resolveForgeArtifact('1.7.1', '10.13.4.1614', ['1.7.10-10.13.4.1614-1.7.10']);
      expect(identity.artifactVersion).assertEqual('1.7.1-10.13.4.1614');
      expect(identity.metadataMatched).assertFalse();
    });

    it('metadata 缺项只回退到精确请求不虚构分支', 0, () => {
      let identity = resolveForgeArtifact('1.20.1', '47.4.26', []);
      expect(identity.artifactVersion).assertEqual('1.20.1-47.4.26');
      expect(identity.metadataMatched).assertFalse();
    });

    it('分支判定对短版本及可选游戏前缀使用同一语义', 0, () => {
      expect(hasExplicitForgeBranch('1.7.2', '10.12.2.1161-mc172')).assertTrue();
      expect(hasExplicitForgeBranch('1.7.2', '1.7.2-10.12.2.1161-mc172')).assertTrue();
      expect(hasExplicitForgeBranch('1.20.1', '47.4.26')).assertFalse();
      expect(hasExplicitForgeBranch('1.20.1', '1.20.1-47.4.26')).assertFalse();
    });

    it('不同游戏前缀的完整工件请求必须拒绝', 0, () => {
      expect(forgeResolutionFails('1.7.10', '1.8.9-11.15.1.2318-1.8.9', [])).assertTrue();
    });

    it('不同游戏预发布完整前缀不能被当成 Forge 显式分支', 0, () => {
      // 这些输入第一段看似三段 Forge build；其后还包含 Minecraft 预发布标签及真实
      // Forge build，必须识别为另一游戏的完整 artifact，避免跳过查询后安装错误版本。
      let foreignArtifacts: string[] = ['1.20.2-pre4-48.0.0', '1.20.2-rc1-48.0.0',
        '1.20.2-snapshot-48.0.0'];
      for (let artifact of foreignArtifacts) {
        expect(forgeResolutionFails('1.20.1', artifact, [])).assertTrue();
      }
    });

    it('不可信请求不能进入 Maven URL 或实例路径', 0, () => {
      let invalid: string[] = ['', '../10.13.4.1614', '10.13.4.1614/branch', '10.13.4.1614\\branch',
        '10.13.4.1614?query', '10.13.4.1614#fragment', '10.13.4.1614\u0000', ' 10.13.4.1614',
        '10.13.4.1614%2fbranch', '10.13.4.1614-'];
      for (let value of invalid) {
        expect(forgeResolutionFails('1.7.10', value, [])).assertTrue();
      }
      expect(forgeResolutionFails('../1.7.10', '10.13.4.1614', [])).assertTrue();
    });

    it('不安全 metadata 不能污染合法分支的唯一性', 0, () => {
      let identity = resolveForgeArtifact('1.7.10', '10.13.4.1614', [
        '1.7.10-10.13.4.1614-../../outside', '1.7.10-10.13.4.1614-1.7.10'
      ]);
      expect(identity.artifactVersion).assertEqual('1.7.10-10.13.4.1614-1.7.10');
      expect(identity.metadataMatched).assertTrue();
    });
  });
}
