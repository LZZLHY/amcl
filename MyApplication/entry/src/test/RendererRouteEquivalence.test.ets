/**
 * RendererRouteEquivalence.test.ets — S3 接线的**逐位等价性**对照
 *
 * 施工记录 `docs/refactor/渲染后端治理施工记录.md` §S3。
 *
 * ⭐ **本文件与 `RendererBackendResolver.test.ets` 分工不同，不要合并：**
 *
 * | 文件 | 钉住什么 |
 * |---|---|
 * | `RendererBackendResolver.test.ets` | 解析器**自身**的判定正确（22 条断言，含注册表结构不变量） |
 * | **本文件** | 解析器 + 注入逻辑 **合起来产出的 `-Damcl.gl.backend` 参数**与改造前的三个 if 块**逐位相同** |
 *
 * 后者才是 S3 的验收判据。前者能全绿而后者失败 —— 例如"默认后端也注入了 marker"：
 * 解析器判定完全正确，但注入多写了一个参数，改造前后 `jvmArgs` 就不再逐位相同。
 *
 * 手法：把改造**之前**那三个 if 块的逻辑**原样重写**成 `legacyBackendMarker()`
 * （逐行对照旧代码，见函数内注释），再与新链路的产物逐项比对。
 * ⚠️ 这份 legacy 复刻是**一次性的验收工具**，不是要长期维护的第二套实现 ——
 * §S6 zink 退役之后它会与新行为分叉，那时按 §S6 的计划把 legacy 一侧同步或整体移除。
 *
 * 创建日期：2026-08-27
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRendererBackend,
  RendererResolveInput,
  RENDERER_BACKEND_DEFAULT_ID,
} from 'launch';

/**
 * 改造**之前**的行为复刻。返回会被 push 进 `jvmArgs` 的那个字符串，无注入则返回空串。
 *
 * 逐行对照旧代码（`LaunchProfileBuilder.buildProfile`，改造前）：
 *
 * ```
 * if (needs322) {                                            // ← 块 1
 *   ...
 *   let realMc = resolveInstalledMcVersion(...)
 *   if (!isMcVersionAtLeast(realMc, '1.17')) {
 *     parsed.jvmArgs.push('-Damcl.gl.backend=gl4es')
 *   }
 * }
 * if (lwjglVersion === 2) {                                  // ← 块 2
 *   lwjglJarDir = ...
 *   parsed.jvmArgs.push('-Damcl.gl.backend=gl4es')
 * }
 * {                                                          // ← 块 3
 *   let alreadyGl4es = parsed.jvmArgs.indexOf('-Damcl.gl.backend=gl4es') >= 0
 *   if (!alreadyGl4es && this.glRendererPref === 'zink') {
 *     let realMc = resolveInstalledMcVersion(...)
 *     if (isMcVersionAtLeast(realMc, '1.17')) {
 *       parsed.jvmArgs.push('-Damcl.gl.backend=zink')
 *     }
 *   }
 * }
 * ```
 *
 * ⚠️ **两处必须精确复刻、不能"顺手修正"的地方**：
 * ① 块 2 **没有版本判据** —— `lwjglVersion === 2` 就注入，不看 `realMc`；
 * ② 块 1 的版本判定**嵌在 `needs322` 里** —— 这是偶然耦合（施工记录 §S1.1 ②），
 *    `!needs322 && realMc < 1.17` 时块 1 根本不执行。
 */
function legacyBackendMarker(realMc: string, lwjglVersion: number,
                             needs322: boolean, pref: string): string {
  const pushed: string[] = [];

  // 块 1
  if (needs322) {
    if (!legacyIsMcAtLeast(realMc, '1.17')) {
      pushed.push('-Damcl.gl.backend=gl4es');
    }
  }
  // 块 2 —— 注意：无版本判据
  if (lwjglVersion === 2) {
    pushed.push('-Damcl.gl.backend=gl4es');
  }
  // 块 3 —— 反查前两块的产物
  const alreadyGl4es: boolean = pushed.indexOf('-Damcl.gl.backend=gl4es') >= 0;
  if (!alreadyGl4es && pref === 'zink') {
    if (legacyIsMcAtLeast(realMc, '1.17')) {
      pushed.push('-Damcl.gl.backend=zink');
    }
  }

  // 旧代码会 push 两次 gl4es 吗？会 —— needs322 且 lwjglVersion===2 时两块都命中。
  // 但那个组合不可达（LWJGL2 的 version.json 不声明 lwjgl 3.x），且 native 侧取最后一个。
  // 这里返回**最后一个**，与 native `mc_launcher.cpp` 扫参数向量时后者覆盖前者的行为一致。
  return pushed.length === 0 ? '' : pushed[pushed.length - 1];
}

/** 旧代码用的 `isMcVersionAtLeast`（commons）语义复刻。 */
function legacyIsMcAtLeast(version: string, minimum: string): boolean {
  if (!version || version.length === 0) return false;
  const a: string[] = version.split('.');
  const b: string[] = minimum.split('.');
  const n: number = a.length > b.length ? a.length : b.length;
  for (let i = 0; i < n; i++) {
    const av: number = i < a.length ? legacySeg(a[i]) : 0;
    const bv: number = i < b.length ? legacySeg(b[i]) : 0;
    if (av > bv) return true;
    if (av < bv) return false;
  }
  return true;
}

function legacySeg(seg: string): number {
  let d: string = '';
  for (let i = 0; i < seg.length; i++) {
    const c: string = seg.charAt(i);
    if (c >= '0' && c <= '9') d += c; else break;
  }
  if (d.length === 0) return 0;
  const v: number = Number.parseInt(d, 10);
  return Number.isNaN(v) ? 0 : v;
}

/** 新链路：解析器 + `LaunchProfileBuilder` 的注入条件（默认后端不注入）。 */
function newBackendMarker(realMc: string, lwjglVersion: number,
                          needs322: boolean, pref: string): string {
  const d = resolveRendererBackend({
    realMcVersion: realMc,
    lwjglVersion: lwjglVersion,
    needsLwjgl322Slot: needs322,
    userPreferredBackendId: pref,
  } as RendererResolveInput);
  // ⚠️ 这个条件必须与 LaunchProfileBuilder 里那一行保持一致。
  if (d.backendId === RENDERER_BACKEND_DEFAULT_ID) return '';
  return `-Damcl.gl.backend=${d.backendId}`;
}

/** frame pacing 的 gate：旧 = "没注入 gl4es"，新 = "决策不是 gl4es"。 */
function legacyPacingEnabled(usesSdl3: boolean, marker: string): boolean {
  return usesSdl3 && marker !== '-Damcl.gl.backend=gl4es';
}

function newPacingEnabled(usesSdl3: boolean, realMc: string, lwjglVersion: number,
                          needs322: boolean, pref: string): boolean {
  const d = resolveRendererBackend({
    realMcVersion: realMc,
    lwjglVersion: lwjglVersion,
    needsLwjgl322Slot: needs322,
    userPreferredBackendId: pref,
  } as RendererResolveInput);
  return usesSdl3 && d.backendId !== 'gl4es';
}

export default function rendererRouteEquivalenceTest() {

  describe('S3 接线：新旧链路在全判定矩阵上产出相同的 backend marker', () => {

    it('⭐ 全组合：非 zink 路径逐项相同，zink 路径按退役预期分叉（3×8×3 = 72 组）', 0, () => {
      // 维度取自改造前三个 if 块的**实际输入**，不是想象出来的。
      const versions: string[] = [
        '',            // resolveInstalledMcVersion 判不出（整合包 / 重命名）
        '1.7.10',
        '1.12.2',
        '1.16.5',
        '1.17.1',      // 边界：现代管线起点
        '1.20.4',
        '26.2',        // YY.D.H 纪元：26 > 1
        '26.3',
      ];
      const prefs: string[] = ['mobileglues', 'zink', 'bogus-retired-id'];
      // [lwjglVersion, needs322]
      const slots: number[][] = [[2, 0], [3, 1], [3, 0]];

      let compared: number = 0;
      let diverged: number = 0;
      for (let s = 0; s < slots.length; s++) {
        const lwjgl: number = slots[s][0];
        const needs322: boolean = slots[s][1] === 1;
        for (let v = 0; v < versions.length; v++) {
          for (let p = 0; p < prefs.length; p++) {
            const legacy: string = legacyBackendMarker(versions[v], lwjgl, needs322, prefs[p]);
            const now: string = newBackendMarker(versions[v], lwjgl, needs322, prefs[p]);
            // 断言里带上输入，失败时不用再猜是哪一组。
            const ctx: string =
              `slot(lwjgl=${lwjgl},322=${needs322}) mc='${versions[v]}' pref='${prefs[p]}'`;
            if (legacy !== now) {
              // ⚰️ **允许且只允许一种分叉：zink 退役。**
              //
              // §S6 之前本用例要求全等（S3 的等价性重构）。zink 退役是**刻意的语义变更**，
              // 于是判据从"全等"改成"**差异恰好等于预期的那一处**" ——
              // 这比放宽成"允许不等"强得多：它继续保护 S3 的成果（非 zink 路径必须仍然全等），
              // 同时把 zink 的变更钉成一条显式清单。
              //
              // 预期分叉的**唯一**形状：legacy 注入 zink，new 落默认（不注入）。
              const expectedDivergence: boolean =
                legacy === '-Damcl.gl.backend=zink' && now === '';
              if (!expectedDivergence) {
                expect(`${ctx}: legacy='${legacy}'`).assertEqual(`${ctx}: new='${now}'`);
              }
              diverged++;
            }
            compared++;
          }
        }
      }
      // 3 槽位 × 8 版本 × 3 偏好。写成乘式而不是 72，免得改了维度忘了改这个数。
      expect(compared).assertEqual(3 * 8 * 3);
      // ⭐ 分叉数必须**恰好**等于"zink 偏好 × 现代管线版本 × 非 gl4es 强制的槽位"。
      //
      // 推导（legacy 注入 zink 需同时满足三条）：
      //   (a) `pref === 'zink'`                      ⇒ 3 个偏好里只有 1 个
      //   (b) `realMc >= 1.17`                       ⇒ 8 个版本里 1.17.1 / 1.20.4 / 26.2 / 26.3 共 **4** 个
      //   (c) `!alreadyGl4es`                        ⇒ 块 1、块 2 都没 push
      //       · 块 2 = `lwjglVersion === 2`          ⇒ 排除槽位 [2, false]
      //       · 块 1 = `needs322 && realMc < 1.17`   ⇒ 在 (b) 成立时**恒不执行**，与 needs322 无关
      //       ⇒ 槽位 [3, true] 与 [3, false] **都**满足 ⇒ **2** 个
      //   ⇒ 4 × 2 = **8** 组
      //
      // ⚠️ 这个数字我第一次写成了 4 —— 错在把 `needs322=true` 读成"必然强制 gl4es"，
      // 而块 1 在 `realMc >= 1.17` 时是**惰性**的（`needs322` 只是它的外层门，
      // 版本判据才是决定项，即施工记录 §S1.1 ② 记的那处"偶然耦合"）。
      // 计数断言把它当场抓住了 —— 这正是写成乘式断言而不是注释里估算的理由（§S3.3 同源）。
      expect(diverged).assertEqual(4 * 2);
    });

    it('⚰️ zink 退役的分叉方向：legacy 注入 zink，new 落默认（不注入）', 0, () => {
      // 把上面那条"允许的分叉"单独立出来，写清方向。
      // 反方向（new 注入了 zink 而 legacy 没有）必须永不发生 —— 那意味着退役没做干净。
      expect(legacyBackendMarker('1.20.4', 3, false, 'zink')).assertEqual('-Damcl.gl.backend=zink');
      expect(newBackendMarker('1.20.4', 3, false, 'zink')).assertEqual('');
    });

    it('⚰️ needs322=true 且 mc≥1.17 时同样分叉（我算错分叉数的那个槽位）', 0, () => {
      // 这一条是**为一个具体错误立的钉子**：上面的计数断言我第一次写成 4，
      // 因为把 `needs322=true` 读成"必然强制 gl4es"。实际块 1 的条件是
      // `needs322 && realMc < 1.17` —— 版本判据才是决定项。
      // ⇒ needs322=true 且 mc≥1.17 时块 1 惰性、块 2 不命中，legacy 照样注入 zink。
      expect(legacyBackendMarker('1.20.4', 3, true, 'zink')).assertEqual('-Damcl.gl.backend=zink');
      expect(newBackendMarker('1.20.4', 3, true, 'zink')).assertEqual('');
      // 对照：同槽位 mc<1.17 时块 1 生效 ⇒ 两边都是 gl4es，不分叉。
      expect(legacyBackendMarker('1.12.2', 3, true, 'zink')).assertEqual('-Damcl.gl.backend=gl4es');
      expect(newBackendMarker('1.12.2', 3, true, 'zink')).assertEqual('-Damcl.gl.backend=gl4es');
    });

    it('⚠️ 未知偏好 id：旧链路不注入，新链路也不注入', 0, () => {
      // 旧代码块 3 的条件是 `pref === 'zink'` —— 任何其他值都不注入。
      // 新链路走 UserPreferenceUnknown ⇒ 落默认 ⇒ 也不注入。两者一致。
      expect(legacyBackendMarker('1.20.4', 3, false, 'bogus')).assertEqual('');
      expect(newBackendMarker('1.20.4', 3, false, 'bogus')).assertEqual('');
    });

    it('默认偏好在现代路径上两边都不注入 marker', 0, () => {
      // 这一条单独立出来，因为它是"默认后端刻意不注入"那个决定的直接判据。
      expect(legacyBackendMarker('1.20.4', 3, false, 'mobileglues')).assertEqual('');
      expect(newBackendMarker('1.20.4', 3, false, 'mobileglues')).assertEqual('');
    });
  });

  describe('S3 接线：frame pacing 的 gate 语义未变', () => {
    // 3 槽位 × 6 版本 × 2 偏好 × 2 个 usesSdl3 态 = 72 组。
    // 📌 这个数字我第一版写成 144（把 72 当成上一个矩阵的规模又乘了 2），
    //    被下面那条计数断言当场抓住 —— 那正是它存在的理由：
    //    没有它，"循环体一条都没跑"与"全部通过"在日志里长得一模一样。
    it('全组合逐项相同（3×6×2×2 = 72 组）', 0, () => {
      const versions: string[] = ['', '1.12.2', '1.16.5', '1.17.1', '1.20.4', '26.3'];
      const prefs: string[] = ['mobileglues', 'zink'];
      const slots: number[][] = [[2, 0], [3, 1], [3, 0]];
      const sdl3States: boolean[] = [true, false];

      let compared: number = 0;
      for (let s = 0; s < slots.length; s++) {
        for (let v = 0; v < versions.length; v++) {
          for (let p = 0; p < prefs.length; p++) {
            for (let q = 0; q < sdl3States.length; q++) {
              const lwjgl: number = slots[s][0];
              const n322: boolean = slots[s][1] === 1;
              const marker: string = legacyBackendMarker(versions[v], lwjgl, n322, prefs[p]);
              const legacy: boolean = legacyPacingEnabled(sdl3States[q], marker);
              const now: boolean = newPacingEnabled(sdl3States[q], versions[v], lwjgl, n322, prefs[p]);
              if (legacy !== now) {
                const ctx: string = `slot(lwjgl=${lwjgl},322=${n322}) mc='${versions[v]}'` +
                  ` pref='${prefs[p]}' sdl3=${sdl3States[q]}`;
                expect(`${ctx}: legacy=${legacy}`).assertEqual(`${ctx}: new=${now}`);
              }
              compared++;
              // ⚰️ zink 退役对本矩阵**没有影响**，这一点值得显式记下：
              // 旧判据是"marker 不是 gl4es"，zink 与 mobileglues 在这条判据下同侧（都不是 gl4es）
              // ⇒ 退役把 zink 换成默认，pacing 结论不变。
              // ⇒ 所以这里仍然要求**全等**，不允许任何分叉。
            }
          }
        }
      }
      expect(compared).assertEqual(3 * 6 * 2 * 2);
    });
  });
}
