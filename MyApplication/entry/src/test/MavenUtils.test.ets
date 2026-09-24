/*
 * MavenUtils.test.ets — MavenUtils 纯函数单元测试
 *
 * 覆盖范围：
 *   - parseMavenName   坐标字符串 → MavenCoordinate 的各种格式
 *   - mavenToRelativePath  坐标 → 相对路径
 *   - mavenToUrl       坐标 + 仓库 → 完整 URL
 *
 * 所有函数都是无 I/O 的纯函数，不依赖设备/网络/文件系统，可在 localUnit 跑。
 *
 * 新增日期：2026-05-04
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseMavenName, mavenToRelativePath, mavenToUrl } from 'feature_core';

export default function mavenUtilsTest() {
  describe('MavenUtils', () => {

    // ============================================================
    //  parseMavenName
    // ============================================================

    it('parseMavenName: 基础 3 段式 group:artifact:version', 0, () => {
      let coord = parseMavenName('net.fabricmc:fabric-loader:0.16.10');
      expect(coord !== null).assertTrue();
      if (coord !== null) {
        expect(coord.groupId).assertEqual('net.fabricmc');
        expect(coord.artifactId).assertEqual('fabric-loader');
        expect(coord.version).assertEqual('0.16.10');
        expect(coord.extension).assertEqual('jar');
        expect(coord.classifier === undefined).assertTrue();
      }
    });

    it('parseMavenName: 4 段式带 classifier', 0, () => {
      let coord = parseMavenName('net.minecraftforge:forge:1.20.4-49.0.30:client');
      expect(coord !== null).assertTrue();
      if (coord !== null) {
        expect(coord.groupId).assertEqual('net.minecraftforge');
        expect(coord.artifactId).assertEqual('forge');
        expect(coord.version).assertEqual('1.20.4-49.0.30');
        expect(coord.classifier).assertEqual('client');
        expect(coord.extension).assertEqual('jar');
      }
    });

    it('parseMavenName: 带 @extension 后缀', 0, () => {
      let coord = parseMavenName('org.lwjgl:lwjgl:3.3.1@zip');
      expect(coord !== null).assertTrue();
      if (coord !== null) {
        expect(coord.groupId).assertEqual('org.lwjgl');
        expect(coord.artifactId).assertEqual('lwjgl');
        expect(coord.version).assertEqual('3.3.1');
        expect(coord.extension).assertEqual('zip');
        expect(coord.classifier === undefined).assertTrue();
      }
    });

    it('parseMavenName: 带 classifier 和 @extension', 0, () => {
      let coord = parseMavenName('org.lwjgl:lwjgl:3.3.1:natives-linux@jar');
      expect(coord !== null).assertTrue();
      if (coord !== null) {
        expect(coord.classifier).assertEqual('natives-linux');
        expect(coord.extension).assertEqual('jar');
      }
    });

    it('parseMavenName: 非法格式返回 null', 0, () => {
      expect(parseMavenName('') === null).assertTrue();
      expect(parseMavenName('only-one-part') === null).assertTrue();
      expect(parseMavenName('group:artifact') === null).assertTrue();  // 缺 version
    });

    it('parseMavenName: group 含点号保留原样（不转斜杠）', 0, () => {
      let coord = parseMavenName('com.google.guava:guava:31.1-jre');
      expect(coord !== null).assertTrue();
      if (coord !== null) {
        expect(coord.groupId).assertEqual('com.google.guava');  // 关键：此处不转斜杠
      }
    });

    // ============================================================
    //  mavenToRelativePath
    // ============================================================

    it('mavenToRelativePath: 基础坐标生成标准 Maven 路径', 0, () => {
      let path = mavenToRelativePath('net.fabricmc:fabric-loader:0.16.10');
      expect(path).assertEqual('net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
    });

    it('mavenToRelativePath: 带 classifier 的路径', 0, () => {
      let path = mavenToRelativePath('org.lwjgl:lwjgl:3.3.1:natives-linux');
      expect(path).assertEqual('org/lwjgl/lwjgl/3.3.1/lwjgl-3.3.1-natives-linux.jar');
    });

    it('mavenToRelativePath: 带 @extension', 0, () => {
      let path = mavenToRelativePath('net.minecraftforge:forge:1.20.4-49.0.30@zip');
      expect(path).assertEqual('net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30.zip');
    });

    it('mavenToRelativePath: Forge client classifier（项目实际场景）', 0, () => {
      let path = mavenToRelativePath('net.minecraftforge:forge:1.20.4-49.0.30:client');
      expect(path).assertEqual('net/minecraftforge/forge/1.20.4-49.0.30/forge-1.20.4-49.0.30-client.jar');
    });

    it('mavenToRelativePath: 非法坐标返回空串', 0, () => {
      expect(mavenToRelativePath('invalid')).assertEqual('');
    });

    // ============================================================
    //  mavenToUrl
    // ============================================================

    it('mavenToUrl: repoUrl 末尾无斜杠自动补齐', 0, () => {
      let url = mavenToUrl('net.fabricmc:fabric-loader:0.16.10', 'https://maven.fabricmc.net');
      expect(url).assertEqual('https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
    });

    it('mavenToUrl: repoUrl 末尾已有斜杠不重复', 0, () => {
      let url = mavenToUrl('net.fabricmc:fabric-loader:0.16.10', 'https://maven.fabricmc.net/');
      expect(url).assertEqual('https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
    });

    it('mavenToUrl: 非法坐标返回空串', 0, () => {
      expect(mavenToUrl('invalid', 'https://repo/')).assertEqual('');
    });

    it('mavenToUrl: BMCLAPI 镜像场景', 0, () => {
      let url = mavenToUrl('net.fabricmc:fabric-loader:0.16.10', 'https://bmclapi2.bangbang93.com/maven/');
      expect(url).assertEqual('https://bmclapi2.bangbang93.com/maven/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar');
    });
  });
}
