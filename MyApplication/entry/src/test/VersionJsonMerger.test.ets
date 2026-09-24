/*
 * VersionJsonMerger.test.ets — Phase 7 (S3-4) 纯函数单元测试
 *
 * 覆盖：VersionJsonMerger.mergeJsonObjects / dedupeStringArray（零 IO，纯 JSON 变换）
 *   - PCL2 merge 规则：mainClass 加载器优先、libraries 加载器前置、arguments.game/jvm 追加
 *   - 清理：inheritsFrom / jar / _comment_ 字段必须去除
 *   - id 设为 outputName
 *   - minecraftArguments（1.12-）合并去重
 *   - 空 loaderJson 分支（原版透传）
 *   - dedupeStringArray 保序 + 去重
 *
 * 不覆盖：
 *   - readTextFile / writeTextFile / merge() 的文件 IO 部分 —— 留给 ohosTest 集成。
 *
 * 创建日期：2026-05-06
 */

import { describe, it, expect } from '@ohos/hypium';
import { VersionJsonMerger } from 'feature_core';

// 顶层 helper（ArkTS 严格模式禁止嵌套函数 + 禁止未类型化对象字面量）
function libEntry(name: string): Record<string, Object> {
  let e: Record<string, Object> = {};
  e['name'] = name;
  return e;
}

function argumentsObj(game: string[], jvm: string[]): Record<string, Object> {
  let a: Record<string, Object> = {};
  a['game'] = game as Object[];
  a['jvm'] = jvm as Object[];
  return a;
}

function makeMcJson(): Record<string, Object> {
  let j: Record<string, Object> = {};
  j['id'] = '1.20.1';
  j['mainClass'] = 'net.minecraft.client.main.Main';
  j['type'] = 'release';
  j['releaseTime'] = '2023-06-12T13:25:51+00:00';
  j['libraries'] = [
    libEntry('com.mojang:blocklist:1.0.10'),
    libEntry('com.mojang:logging:1.1.1'),
  ] as Object[];
  j['arguments'] = argumentsObj(
    ['--username', '${auth_player_name}'],
    ['-Xmx2G'],
  );
  return j;
}

function makeForgeJson(): Record<string, Object> {
  let j: Record<string, Object> = {};
  j['id'] = '1.20.1-forge-47.2.0';
  j['mainClass'] = 'cpw.mods.bootstraplauncher.BootstrapLauncher';
  j['inheritsFrom'] = '1.20.1';  // 必须被清理
  j['jar'] = '1.20.1';            // 必须被清理
  j['_comment_'] = ['ignore me'] as Object[];  // 必须被清理
  j['type'] = 'release';
  j['libraries'] = [
    libEntry('net.minecraftforge:forge:1.20.1-47.2.0'),
    libEntry('cpw.mods:bootstraplauncher:1.1.2'),
  ] as Object[];
  j['arguments'] = argumentsObj(
    ['--launchTarget', 'forgeclient'],
    ['-Dforge.mod=true'],
  );
  return j;
}

function makeLegacyMcJson(): Record<string, Object> {
  // 1.12-/1.7 style: 用 minecraftArguments 字符串
  let j: Record<string, Object> = {};
  j['id'] = '1.7.10';
  j['mainClass'] = 'net.minecraft.client.main.Main';
  j['minecraftArguments'] = '--username ${auth_player_name} --version ${version_name}';
  j['libraries'] = [] as Object[];
  return j;
}

function makeLegacyForgeJson(): Record<string, Object> {
  let j: Record<string, Object> = {};
  j['id'] = '1.7.10-Forge';
  j['mainClass'] = 'net.minecraft.launchwrapper.Launch';
  j['minecraftArguments'] = '--tweakClass cpw.mods.fml.common.launcher.FMLTweaker --version ${version_name}';
  j['libraries'] = [] as Object[];
  j['inheritsFrom'] = '1.7.10';
  return j;
}

export default function versionJsonMergerTest() {

describe('VersionJsonMerger.mergeJsonObjects — PCL2 合并规则', () => {

  it('null loader → 透传原版 + 清理 inheritsFrom 等 + 设置 id', 0, () => {
    let mc = makeMcJson();
    mc['inheritsFrom'] = 'should_not_exist';  // 即便原版有也要清
    let out = VersionJsonMerger.mergeJsonObjects(mc, null, 'my-version');

    expect(out['id']).assertEqual('my-version');
    expect(out['mainClass']).assertEqual('net.minecraft.client.main.Main');
    expect(out['inheritsFrom'] === undefined).assertTrue();
    expect(out['jar'] === undefined).assertTrue();
    expect((out['libraries'] as Object[]).length).assertEqual(2);
  });

  it('Forge loader → mainClass 被覆盖、libraries 前置、arguments 追加', 0, () => {
    let out = VersionJsonMerger.mergeJsonObjects(makeMcJson(), makeForgeJson(), 'mc+forge');

    // mainClass: 加载器胜
    expect(out['mainClass']).assertEqual('cpw.mods.bootstraplauncher.BootstrapLauncher');

    // libraries: 加载器在前 (2 个) + 原版在后 (2 个) = 4 个
    let libs = out['libraries'] as Object[];
    expect(libs.length).assertEqual(4);
    let firstLib = libs[0] as Record<string, Object>;
    expect(firstLib['name']).assertEqual('net.minecraftforge:forge:1.20.1-47.2.0');
    let lastLib = libs[3] as Record<string, Object>;
    expect(lastLib['name']).assertEqual('com.mojang:logging:1.1.1');

    // arguments.game: 原版 + 加载器 = 4 项
    let args = out['arguments'] as Record<string, Object>;
    let game = args['game'] as Object[];
    expect(game.length).assertEqual(4);
    expect(game[0]).assertEqual('--username');
    expect(game[3]).assertEqual('forgeclient');

    // arguments.jvm: 原版 + 加载器 = 2 项
    let jvm = args['jvm'] as Object[];
    expect(jvm.length).assertEqual(2);
    expect(jvm[0]).assertEqual('-Xmx2G');
    expect(jvm[1]).assertEqual('-Dforge.mod=true');

    // id: 用户指定
    expect(out['id']).assertEqual('mc+forge');

    // 清理字段
    expect(out['inheritsFrom'] === undefined).assertTrue();
    expect(out['jar'] === undefined).assertTrue();
    expect(out['_comment_'] === undefined).assertTrue();
  });

  it('minecraftArguments 旧格式 → 合并去重', 0, () => {
    let out = VersionJsonMerger.mergeJsonObjects(
      makeLegacyMcJson(),
      makeLegacyForgeJson(),
      'mc+forge-legacy'
    );
    let mca = out['minecraftArguments'] as string;
    // 包含原版 + Forge 追加，${version_name} 出现 2 次应被去重
    expect(mca.includes('--username')).assertTrue();
    expect(mca.includes('--tweakClass')).assertTrue();
    expect(mca.includes('cpw.mods.fml.common.launcher.FMLTweaker')).assertTrue();

    // 去重：${version_name} 只出现一次
    let parts = mca.split(' ');
    let vnCount = 0;
    for (let p of parts) { if (p === '${version_name}') vnCount++; }
    expect(vnCount).assertEqual(1);
  });

  it('loader 无 libraries → 保留原版 libraries', 0, () => {
    let loader: Record<string, Object> = {};
    loader['mainClass'] = 'com.loader.Main';
    loader['libraries'] = [] as Object[];
    let out = VersionJsonMerger.mergeJsonObjects(makeMcJson(), loader, 'mc+empty-loader');
    let libs = out['libraries'] as Object[];
    expect(libs.length).assertEqual(2);  // 原版 2 个完整保留
    expect(out['mainClass']).assertEqual('com.loader.Main');
  });

  it('loader 无 mainClass → 保留原版 mainClass', 0, () => {
    let loader: Record<string, Object> = {};
    loader['libraries'] = [] as Object[];
    let out = VersionJsonMerger.mergeJsonObjects(makeMcJson(), loader, 'x');
    expect(out['mainClass']).assertEqual('net.minecraft.client.main.Main');
  });

  it('type 字段：加载器优先', 0, () => {
    let mc = makeMcJson();
    mc['type'] = 'release';
    let loader: Record<string, Object> = {};
    loader['type'] = 'snapshot';
    let out = VersionJsonMerger.mergeJsonObjects(mc, loader, 'x');
    expect(out['type']).assertEqual('snapshot');
  });

  it('id 始终被覆盖为 outputName，哪怕原版已有同名', 0, () => {
    let mc = makeMcJson();
    mc['id'] = 'old-id';
    let out = VersionJsonMerger.mergeJsonObjects(mc, null, 'brand-new-name');
    expect(out['id']).assertEqual('brand-new-name');
  });
});

describe('VersionJsonMerger.dedupeStringArray — 去重保序', () => {

  it('空数组 → 空数组', 0, () => {
    expect(VersionJsonMerger.dedupeStringArray([]).length).assertEqual(0);
  });

  it('无重复 → 原数组', 0, () => {
    let r = VersionJsonMerger.dedupeStringArray(['a', 'b', 'c']);
    expect(r.length).assertEqual(3);
    expect(r[0]).assertEqual('a');
    expect(r[2]).assertEqual('c');
  });

  it('有重复 → 保留首次出现的顺序', 0, () => {
    let r = VersionJsonMerger.dedupeStringArray(['a', 'b', 'a', 'c', 'b', 'd']);
    expect(r.length).assertEqual(4);
    expect(r[0]).assertEqual('a');
    expect(r[1]).assertEqual('b');
    expect(r[2]).assertEqual('c');
    expect(r[3]).assertEqual('d');
  });

  it('全相同 → 单元素', 0, () => {
    let r = VersionJsonMerger.dedupeStringArray(['x', 'x', 'x']);
    expect(r.length).assertEqual(1);
    expect(r[0]).assertEqual('x');
  });
});

} // versionJsonMergerTest
