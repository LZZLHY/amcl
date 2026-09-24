#!/usr/bin/env node
/**
 * check-jdk-release-pin.mjs — JDK 发行版四处 SoT 的一致性门禁
 *
 * ⭐ 为什么会有这个脚本（2026-08-29）：
 *
 * `deps.lock` 的 `[mc-ohos-resources*]` 段注释一直写着「CI 校验本节字段跟
 * JdkManager.JDK_VERSIONS + Constants.*_RELEASE_TAG/ASSET + prebuilt/jdk/<v>/README.md
 * 三处一致」。**那句话是假的** —— 实测全仓没有任何脚本读过 `JDK_VERSIONS` 或
 * `mc-ohos-resources`，这个校验从来不存在。
 *
 * 也就是说换 JDK 包时「漏改一处」一直是没有网的：漏改的后果不在改动现场暴露，而是
 *   · `sizeBytes` 不符 → 下载期间被引擎判失败，所有源被拒；
 *   · `sha256` 不符 → 全量下完才报「校验和不匹配，可能镜像被劫持」，把用户引向错误结论；
 *   · `giteePartSizes` 长度/数值不符 → `JdkInstaller.validateInputs()` 在**下载前**判死；
 * 三种都离改动现场很远。
 *
 * 本脚本把那句注释变成真的。⚠️ 它只校验**内部一致性**（四处互相对齐 + 分卷算术自洽），
 * **不联网**、不验证线上资产真的存在 —— 那需要网络，属于发布流程而不是门禁。
 *
 * 用法：node scripts/check-jdk-release-pin.mjs
 * 自测：node scripts/test-check-jdk-release-pin.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

/** deps.lock 的段名 → JDK 主版本号 */
const SECTION_TO_VER = {
  'mc-ohos-resources': '17',
  'mc-ohos-resources-21': '21',
  'mc-ohos-resources-25': '25',
  'mc-ohos-resources-8': '8',
};

/** 解析 deps.lock 里的 [mc-ohos-resources*] 段。 */
export function parseDepsLock(text) {
  const out = {};
  const lines = text.split(/\r?\n/);
  let cur = null;
  for (const raw of lines) {
    const line = raw.trim();
    const m = line.match(/^\[([^\]]+)\]$/);
    if (m) {
      cur = SECTION_TO_VER[m[1]] || null;
      if (cur) out[cur] = {};
      continue;
    }
    if (!cur || line.startsWith('#') || line.length === 0) continue;
    const kv = line.match(/^(\w+)\s*=\s*(.+)$/);
    if (!kv) continue;
    out[cur][kv[1]] = kv[2].trim();
  }
  return out;
}

/** 解析 Constants.ets 里的 *_RELEASE_TAG / *_RELEASE_ASSET。 */
export function parseConstants(text) {
  const out = {};
  const re = /export const (\w*RELEASE_(?:TAG|ASSET))\s*=\s*'([^']+)'/g;
  let m;
  while ((m = re.exec(text)) !== null) out[m[1]] = m[2];
  return out;
}

/**
 * 解析 JdkManager.ets 的 JDK_VERSIONS。
 *
 * tag/dataFile 可能是字面量，也可能是对 Constants 的引用（21/25 是引用），
 * 所以要把 constants 表传进来解引用 —— 不解引用就会把 `JDK21_RELEASE_TAG` 这个
 * **标识符名**当成 tag 值去比，那种比较永远不会相等，门禁就变成了永红。
 */
export function parseJdkVersions(text, constants) {
  const out = {};
  // 每个条目形如   '17': { ... },   到下一个 "  '<ver>': {" 或 map 结束
  const entryRe = /'(\d+)':\s*\{/g;
  const starts = [];
  let m;
  while ((m = entryRe.exec(text)) !== null) starts.push({ ver: m[1], at: m.index });
  for (let i = 0; i < starts.length; i++) {
    const from = starts[i].at;
    const to = i + 1 < starts.length ? starts[i + 1].at : text.length;
    const body = text.slice(from, to);
    const e = {};
    const str = (k) => {
      const mm = body.match(new RegExp(`${k}:\\s*'([^']+)'`));
      return mm ? mm[1] : null;
    };
    const ident = (k) => {
      const mm = body.match(new RegExp(`${k}:\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*,`));
      return mm ? mm[1] : null;
    };
    const num = (k) => {
      const mm = body.match(new RegExp(`${k}:\\s*(\\d+)`));
      return mm ? Number(mm[1]) : null;
    };
    // tag / dataFile：先试字面量，再试标识符（去 constants 里解）
    e.tag = str('tag');
    if (e.tag === null) {
      const id = ident('tag');
      e.tag = id && constants[id] !== undefined ? constants[id] : (id ? `<未解析:${id}>` : null);
      e.tagFrom = id;
    }
    e.dataFile = str('dataFile');
    if (e.dataFile === null) {
      const id = ident('dataFile');
      e.dataFile = id && constants[id] !== undefined ? constants[id] : (id ? `<未解析:${id}>` : null);
      e.dataFileFrom = id;
    }
    e.sha256 = str('sha256');
    e.sizeBytes = num('sizeBytes');
    e.dataSizeMB = num('dataSizeMB');
    const partsM = body.match(/giteeParts:\s*\[([\s\S]*?)\]/);
    e.giteeParts = partsM
      ? partsM[1].split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter((s) => s.length > 0)
      : [];
    const sizesM = body.match(/giteePartSizes:\s*\[([\s\S]*?)\]/);
    e.giteePartSizes = sizesM
      ? sizesM[1].split(',').map((s) => Number(s.trim())).filter((n) => !Number.isNaN(n))
      : [];
    out[starts[i].ver] = e;
  }
  return out;
}

/** 逐条校验，返回问题列表（空 = 通过）。 */
export function verify(lock, jdk, readmes) {
  const problems = [];
  const vers = Object.keys(jdk).sort();
  for (const v of vers) {
    const j = jdk[v];
    const l = lock[v];
    const at = `JDK ${v}`;
    if (!l) {
      problems.push(`${at}: deps.lock 里没有对应的 [mc-ohos-resources*] 段`);
      continue;
    }
    if (j.tag !== l.tag) problems.push(`${at}: tag 不一致 — JdkManager='${j.tag}' deps.lock='${l.tag}'`);
    if (j.dataFile !== l.asset) {
      problems.push(`${at}: asset 不一致 — JdkManager='${j.dataFile}' deps.lock='${l.asset}'`);
    }
    if (String(j.sizeBytes) !== String(l.sizeBytes)) {
      problems.push(`${at}: sizeBytes 不一致 — JdkManager=${j.sizeBytes} deps.lock=${l.sizeBytes}`);
    }
    if ((j.sha256 || '').toLowerCase() !== (l.sha256 || '').toLowerCase()) {
      problems.push(`${at}: sha256 不一致 — JdkManager=${j.sha256} deps.lock=${l.sha256}`);
    }
    if (j.tag && j.tag.startsWith('<未解析:')) {
      problems.push(`${at}: tag 引用了 Constants 里不存在的常量 ${j.tagFrom}`);
    }
    if (j.dataFile && j.dataFile.startsWith('<未解析:')) {
      problems.push(`${at}: dataFile 引用了 Constants 里不存在的常量 ${j.dataFileFrom}`);
    }

    // ---- 分卷算术自洽（这条是全新的不变量，此前没有任何地方校验）----
    if (j.giteeParts.length !== j.giteePartSizes.length) {
      problems.push(
        `${at}: giteeParts(${j.giteeParts.length}) 与 giteePartSizes(${j.giteePartSizes.length}) 长度不等`
        + ` — JdkInstaller.validateInputs 会在下载前直接判死`);
    } else if (j.giteeParts.length > 0) {
      const sum = j.giteePartSizes.reduce((a, b) => a + b, 0);
      if (sum !== j.sizeBytes) {
        problems.push(
          `${at}: 分卷字节数之和 ${sum} ≠ sizeBytes ${j.sizeBytes}（差 ${sum - j.sizeBytes}）`
          + ` — 拼接出来的包大小不对，SHA-256 必然失败`);
      }
      for (const p of j.giteeParts) {
        if (!p.startsWith(j.dataFile)) {
          problems.push(`${at}: 分卷名 '${p}' 不以 asset '${j.dataFile}' 开头（很可能是换包时漏改）`);
        }
      }
      for (const s of j.giteePartSizes) {
        if (!(s > 0)) problems.push(`${at}: 分卷字节数含非正值 ${s}`);
      }
    }

    // ---- README 至少要提到当前 tag ----
    const rd = readmes[v];
    if (rd === undefined) {
      problems.push(`${at}: 找不到 prebuilt/jdk/${v}/README.md`);
    } else if (j.tag && rd.indexOf(j.tag) < 0) {
      problems.push(`${at}: prebuilt/jdk/${v}/README.md 里没有出现当前 tag '${j.tag}'（换包时漏改）`);
    }
  }
  return problems;
}

export function run(root = ROOT) {
  const lockText = fs.readFileSync(path.join(root, 'deps.lock'), 'utf8');
  const constText = fs.readFileSync(
    path.join(root, 'commons/src/main/ets/common/Constants.ets'), 'utf8');
  const jdkText = fs.readFileSync(
    path.join(root, 'launch/src/main/ets/JdkManager.ets'), 'utf8');
  const constants = parseConstants(constText);
  const lock = parseDepsLock(lockText);
  const jdk = parseJdkVersions(jdkText, constants);
  const readmes = {};
  for (const v of Object.keys(jdk)) {
    const p = path.join(root, 'prebuilt/jdk', v, 'README.md');
    if (fs.existsSync(p)) readmes[v] = fs.readFileSync(p, 'utf8');
  }
  return { lock, jdk, constants, readmes, problems: verify(lock, jdk, readmes) };
}

// 直接执行时作为门禁跑
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url))) {
  const r = run();
  const vers = Object.keys(r.jdk).sort();
  if (r.problems.length > 0) {
    console.error('[check-jdk-release-pin] FAIL  ' + r.problems.length + ' 处不一致：');
    for (const p of r.problems) console.error('  - ' + p);
    console.error('');
    console.error('  换 JDK 包必须同步四处：');
    console.error('    1) launch/src/main/ets/JdkManager.ets 的 JDK_VERSIONS[<ver>]');
    console.error('    2) commons/src/main/ets/common/Constants.ets 的 *_RELEASE_TAG / *_RELEASE_ASSET');
    console.error('    3) deps.lock 的 [mc-ohos-resources*]');
    console.error('    4) prebuilt/jdk/<ver>/README.md');
    process.exit(1);
  }
  console.log('[check-jdk-release-pin] PASS');
  for (const v of vers) {
    const j = r.jdk[v];
    console.log(`  JDK ${v}: ${j.tag} / ${j.dataFile} / ${j.sizeBytes} B`
      + (j.giteeParts.length > 0 ? ` / ${j.giteeParts.length} 卷之和一致` : ' / 无 Gitee 分卷'));
  }
  console.log('  checked: 四处 SoT 的 tag/asset/sizeBytes/sha256 互相一致；');
  console.log('           giteeParts 与 giteePartSizes 等长、之和等于 sizeBytes、卷名以 asset 开头；');
  console.log('           README 提到当前 tag。');
  console.log('  NOT checked: 线上资产是否真的存在（那需要联网，属发布流程不属门禁）。');
}
