#!/usr/bin/env node
// scripts/test-check-log-domains.mjs
//
// check-log-domains.mjs 的定向自测。
//
// 本门禁有两个方向都会静默失效，必须各自钉住：
//   · 抽取器坏掉 ⇒ 一个 tag 都扫不到 ⇒ 0 个未登记 ⇒ **通过**（§4）；
//   · 登记表烂掉 ⇒ 塞满已经不存在的 tag，看起来很全，实际是一份历史清单（§3）。
//
// §5 逐条钉住五种 tag 声明形态。少认一种，那一批 tag 就永远不会被要求登记 ——
// 而它同样表现为「门禁通过」。

import { analyze, readSources, findTags, inventory } from './check-log-domains.mjs';

let failed = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${name}${extra ? `\n       ${extra}` : ''}`);
  }
}

const real = readSources();
const clone = (s) => ({ registryText: s.registryText, texts: new Map(s.texts) });

// ── 1. 正向
{
  const r = analyze(clone(real));
  check('real repo: 门禁通过', r.ok === true,
    JSON.stringify({ schema: r.schema, unreg: r.unregistered, stale: r.stale, pc: r.positiveControl }));
  check('real repo: 域与 tag 数量非零', r.domains > 0 && r.tags > 0, `${r.domains} / ${r.tags}`);
}

// ── 2. ⭐ 承重：新增一个没登记的 tag ⇒ 红
{
  const s = clone(real);
  s.texts.set('commons/src/main/ets/utils/Brand.ets', "const TAG: string = 'BrandNewThing';\n");
  const r = analyze(s);
  check('2.1 新 tag 未登记 ⇒ 不通过', r.ok === false);
  check('2.2 新 tag 未登记 ⇒ 点名到 tag 与文件',
    r.unregistered.some((x) => x.includes('BrandNewThing') && x.includes('Brand.ets')),
    JSON.stringify(r.unregistered));
}

// ── 3. ⭐ 承重：登记表里有源码已不存在的 tag ⇒ 红（防表烂成历史清单）
{
  const s = clone(real);
  s.registryText = s.registryText.replace('"SessionMarker": "launch",',
    '"SessionMarker": "launch",\n    "GhostTagThatNoLongerExists": "launch",');
  const r = analyze(s);
  check('3.1 登记了不存在的 tag ⇒ 不通过', r.ok === false);
  check('3.2 且点名到那个死条目',
    r.stale.includes('GhostTagThatNoLongerExists'), JSON.stringify(r.stale));
}

// ── 4. ⭐ 承重：抽取器失效必须硬失败，不许静默变绿
{
  const r = analyze({ registryText: real.registryText, texts: new Map([['a.ets', '// nothing\n']]) });
  check('4.1 全仓零 tag ⇒ 不通过', r.ok === false);
  check('4.2 且明确说抽取器坏了',
    r.positiveControl.some((x) => x.includes('抽取器必然是坏的')), JSON.stringify(r.positiveControl));
}
{
  // 已知 tag 消失（比如有人把声明写法改了）
  const s = clone(real);
  s.texts.set('launch/src/main/ets/SessionMarker.ets', '// tag declaration rewritten\n');
  const r = analyze(s);
  check('4.3 已知 tag 扫不到 ⇒ 阳性对照开火',
    r.ok === false && r.positiveControl.some((x) => x.includes('SessionMarker')),
    JSON.stringify(r.positiveControl));
}

// ── 5. 五种声明形态都要认（少认一种 = 那批 tag 永远不被要求登记）
{
  const forms = [
    ["const TAG: string = 'AlphaOne';", 'AlphaOne', 'ArkTS 带类型注解'],
    ["const TAG = 'AlphaTwo';", 'AlphaTwo', 'ArkTS 无类型注解'],
    ['#define LOG_TAG "AlphaThree"', 'AlphaThree', 'native #define'],
    ['static const char* LOG_TAG = "AlphaFour";', 'AlphaFour', 'native static const char*'],
    ['constexpr const char* LOG_TAG = "AlphaFive";', 'AlphaFive', 'native constexpr'],
  ];
  for (const [src, expect, why] of forms) {
    check(`5.x 认得: ${why}`, findTags(src + '\n').includes(expect), src);
  }
  // 不许把无关字符串当成 tag
  check('5.y 不误报: 普通字符串常量',
    findTags("const NAME = 'NotATag';\nconst x = 'LOG_TAG';\n").length === 0);
}

// ── 6. schema
{
  const s = clone(real);
  s.registryText = s.registryText.replace('"SessionMarker": "launch"', '"SessionMarker": "nosuchdomain"');
  const r = analyze(s);
  check('6.1 tag 指向未声明的域 ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('nosuchdomain')), JSON.stringify(r.schema));
}
{
  const s = clone(real);
  s.registryText = s.registryText.replace(
    '{ "id": "launch", "owner": "launch + entry/cpp/jvm", "purpose"',
    '{ "id": "launch", "ownerX": "launch + entry/cpp/jvm", "purpose"');
  const r = analyze(s);
  check('6.2 域缺 owner ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('owner')), JSON.stringify(r.schema));
}
{
  const s = clone(real);
  s.registryText = s.registryText.replace(/"purpose": "启动链[^"]*"/, '"purposeX": "x"');
  const r = analyze(s);
  check('6.3 域缺 purpose ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('purpose')), JSON.stringify(r.schema));
}

// ── 7. 注册表损坏 ⇒ fatal
{
  check('7.1 非法 JSON ⇒ fatal',
    analyze({ registryText: '{ oops', texts: real.texts }).fatal !== null);
  check('7.2 无域 ⇒ fatal',
    analyze({ registryText: '{"domains":[],"tags":{}}', texts: real.texts }).fatal !== null);
  check('7.3 缺 tags 映射 ⇒ fatal',
    analyze({ registryText: '{"domains":[{"id":"a","owner":"a","purpose":"a"}]}', texts: real.texts }).fatal !== null);
}

// ── 8. 存量本身的合理性：每个域都要真的有 tag 落进去（空域是设计噪声）
{
  const doc = JSON.parse(real.registryText);
  const used = new Set(Object.values(doc.tags));
  const empty = doc.domains.map((d) => d.id).filter((id) => !used.has(id));
  check('8.1 没有空域（声明了却没有任何 tag 归属）', empty.length === 0, JSON.stringify(empty));
  const inv = inventory(real.texts);
  const exempt = new Set(doc.staleExempt || []);
  // 登记表 = 源码存量 + 豁免名单（后者声明在扫描面之外，如 tests/ 下的探针）
  check('8.2 登记表 = 源码存量 + 豁免名单',
    Object.keys(doc.tags).length === inv.size + exempt.size,
    `registry=${Object.keys(doc.tags).length} source=${inv.size} exempt=${exempt.size}`);
}

// ── 9. staleExempt 名单本身要防烂
{
  const s = clone(real);
  // 豁免一个源码里确实存在的 tag ⇒ 名单过期，必须红
  s.registryText = s.registryText.replace('"staleExempt": ["MG_RENDER_PROBE"]',
    '"staleExempt": ["MG_RENDER_PROBE", "SessionMarker"]');
  const r = analyze(s);
  check('9.1 豁免了一个扫得到的 tag ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('SessionMarker')), JSON.stringify(r.schema));
}
{
  const s = clone(real);
  // 豁免了但没登记域 ⇒ 也要红
  s.registryText = s.registryText.replace('"staleExempt": ["MG_RENDER_PROBE"]',
    '"staleExempt": ["MG_RENDER_PROBE", "NeverRegisteredGhost"]');
  const r = analyze(s);
  check('9.2 豁免了但没登记域 ⇒ 不通过',
    r.ok === false && r.schema.some((x) => x.includes('NeverRegisteredGhost')), JSON.stringify(r.schema));
}
{
  const s = clone(real);
  // 去掉豁免 ⇒ MG_RENDER_PROBE 变成死条目
  s.registryText = s.registryText.replace('"staleExempt": ["MG_RENDER_PROBE"],', '"staleExempt": [],');
  const r = analyze(s);
  check('9.3 去掉豁免 ⇒ 扫描面外的 tag 被判成死条目',
    r.ok === false && r.stale.includes('MG_RENDER_PROBE'), JSON.stringify(r.stale));
}

// ── 10. 三种声明约定都要覆盖到（这是抽取器第一版漏掉的那一层）
{
  // ② LogTags.ets 的集中常量：只在那个文件里生效
  const inLogTags = findTags("static readonly PAGE_X: string = 'SomePage';\n",
    'commons/src/main/ets/common/LogTags.ets');
  check('10.1 LogTags.ets 的 static readonly ⇒ 认',
    inLogTags.includes('SomePage'), JSON.stringify(inLogTags));
  const elsewhere = findTags("static readonly CATEGORY: string = 'download';\n",
    'feature_core/src/main/ets/download/DownloadHistory.ets');
  check('10.2 别处的 static readonly ⇒ 不认（那是活动类目常量，不是日志 tag）',
    !elsewhere.includes('download'), JSON.stringify(elsewhere));

  // ③ 内联字面量
  check('10.3 AppLogger 内联字面量 ⇒ 认',
    findTags("AppLogger.info('LWJGL', 'x');\n").includes('LWJGL'));
  check('10.4 AMCL_LOG 内联字面量 ⇒ 认',
    findTags('AMCL_LOG_I("MG_RENDER_PROBE", "%s", x);\n').includes('MG_RENDER_PROBE'));

  // 注释里的用法示例不算
  check('10.5 文档注释里的示例 ⇒ 不认',
    !findTags(' * AMCL_LOG_I("MODULE", "message %d", value);\n').includes('MODULE'));
  check('10.6 // 行注释里的示例 ⇒ 不认',
    !findTags("// AppLogger.info('EXAMPLE', 'x');\n").includes('EXAMPLE'));
  check('10.7 活动 scope 内联 tag 不依赖其他工作树文件补声明',
    findTags("this.launchLogger_().info('GraphicsCapability', 'probe');\n").includes('GraphicsCapability'));
  check('10.8 绑定实例的内联 tag 可识别',
    findTags("this.alog.error('WorkerFailure', 'failed');\n").includes('WorkerFailure'));
  check('10.9 普通业务方法不会被当作 logger',
    !findTags("this.service.info('BusinessCategory', 'data');\n").includes('BusinessCategory'));
  check('10.10 显式 native 活动日志字面量',
    findTags('amclLogWriteFor(amclLedgerGetLaunchActivity(), AMCL_LOG_LEVEL_INFO, "SessionEnvironment", "data");').includes('SessionEnvironment'));
  check('10.11 独立 DSO 日志桥字面量',
    findTags('amclExternalLogWrite(1, "SessionEnvironment", "data");').includes('SessionEnvironment'));
}

console.log(failed === 0 ? `\n✅ ALL PASS` : `\n❌ ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
