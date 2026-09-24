/*
 * McDownloader.test.ets — Phase 7 (S3-4) 纯函数单元测试
 *
 * 覆盖：McDownloader.filterLibraries（零 IO、零 NAPI、零网络）
 *   - 无 rules 的 lib → 全部保留
 *   - java-objc-bridge → 强制保留（即使 rules 会排除它）
 *   - 仅有 allow rule（无 OS 限制） → 保留
 *   - allow + linux OS → 保留（AMCL 伪装为 Linux）
 *   - allow + windows OS → 排除
 *   - disallow + linux → 排除
 *   - allow linux + disallow linux 同时存在 → 排除
 *   - 混合 lib 数组 → 正确分类
 *
 * AMCL 把设备 OS 伪装成 Linux 传给 Minecraft（因为 Mojang 未发布 HarmonyOS 构建），
 * filterLibraries 必须按 Linux 规则筛。
 *
 * 创建日期：2026-05-06
 */

import { describe, it, expect } from '@ohos/hypium';
import { McDownloader, LibraryEntry, LibraryRule, RuleOs } from 'feature_core';

// 顶层 helper（ArkTS 严格模式禁止嵌套函数 + 禁止未类型化对象字面量）
function makeLib(name: string, rules?: LibraryRule[]): LibraryEntry {
  let e: LibraryEntry = { name } as LibraryEntry;
  if (rules) e.rules = rules;
  return e;
}

function makeRule(action: string, osName?: string): LibraryRule {
  let r: LibraryRule = { action } as LibraryRule;
  if (osName) {
    let o: RuleOs = { name: osName } as RuleOs;
    r.os = o;
  }
  return r;
}

function allowLinux(): LibraryRule   { return makeRule('allow', 'linux'); }
function allowWindows(): LibraryRule { return makeRule('allow', 'windows'); }
function allowAny(): LibraryRule     { return makeRule('allow'); }
function disallowLinux(): LibraryRule { return makeRule('disallow', 'linux'); }

export default function mcDownloaderTest() {

describe('McDownloader.filterLibraries — 规则筛选（伪装为 Linux）', () => {

  it('无 rules → 全部保留', 0, () => {
    let libs: LibraryEntry[] = [
      makeLib('com.mojang:blocklist:1.0.10'),
      makeLib('com.google.code.gson:gson:2.10.1'),
    ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(2);
  });

  it('java-objc-bridge 即使有排除 rules 也必须保留', 0, () => {
    // 模拟真实情况：Mojang 原始 manifest 里 java-objc-bridge 通常标 allow osx 或
    // allow 后 disallow other OS。AMCL 强制保留是因为 MC 代码硬引用 ca.weblite.objc.Client。
    let libs: LibraryEntry[] = [
      makeLib('ca.weblite:java-objc-bridge:1.1', [allowWindows()]),  // 规则上在 Linux 下会被排除
    ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(1);
    expect(out[0].name).assertEqual('ca.weblite:java-objc-bridge:1.1');
  });

  it('allow 无 OS → 保留', 0, () => {
    let libs: LibraryEntry[] = [ makeLib('org.lwjgl:lwjgl:3.3.1', [allowAny()]) ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(1);
  });

  it('allow linux → 保留', 0, () => {
    let libs: LibraryEntry[] = [ makeLib('org.lwjgl:lwjgl-natives-linux:3.3.1', [allowLinux()]) ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(1);
  });

  it('allow windows → 排除', 0, () => {
    let libs: LibraryEntry[] = [ makeLib('org.lwjgl:lwjgl-natives-windows:3.3.1', [allowWindows()]) ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(0);
  });

  it('disallow linux → 排除', 0, () => {
    let libs: LibraryEntry[] = [
      makeLib('x:y:1.0', [allowAny(), disallowLinux()]),
    ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(0);
  });

  it('allow + disallow 同 OS → disallow 胜', 0, () => {
    // allow osx + disallow linux: dominated_allow=false（allow 是 osx），
    // dominated_disallow=true（disallow linux） → 排除
    let libs: LibraryEntry[] = [
      makeLib('oshi:oshi:6.4.0', [
        makeRule('allow', 'osx'),
        disallowLinux(),
      ]),
    ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(0);
  });

  it('混合数组 → 正确分类（4 保留 / 2 排除）', 0, () => {
    let libs: LibraryEntry[] = [
      makeLib('keep:norules:1.0'),                                  // keep: 无 rules
      makeLib('ca.weblite:java-objc-bridge:1.1', [allowWindows()]), // keep: 硬依赖
      makeLib('keep:allowlinux:1.0', [allowLinux()]),               // keep
      makeLib('keep:allowany:1.0', [allowAny()]),                   // keep
      makeLib('drop:allowwindows:1.0', [allowWindows()]),           // drop
      makeLib('drop:disallowlinux:1.0', [allowAny(), disallowLinux()]), // drop
    ];
    let out = McDownloader.filterLibraries(libs);
    expect(out.length).assertEqual(4);
    let names = out.map((l: LibraryEntry) => l.name);
    expect(names.includes('keep:norules:1.0')).assertTrue();
    expect(names.includes('ca.weblite:java-objc-bridge:1.1')).assertTrue();
    expect(names.includes('keep:allowlinux:1.0')).assertTrue();
    expect(names.includes('keep:allowany:1.0')).assertTrue();
  });

  it('空数组 → 空数组', 0, () => {
    expect(McDownloader.filterLibraries([]).length).assertEqual(0);
  });
});

} // mcDownloaderTest
