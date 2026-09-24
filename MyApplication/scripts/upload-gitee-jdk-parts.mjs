#!/usr/bin/env node
/**
 * upload-gitee-jdk-parts.mjs — 把 JDK 分卷传到 Gitee 的 Release 附件
 *
 * ⭐ 为什么会有这个脚本（2026-08-29）：
 *
 * Gitee 是国内用户的**快路径**（直连、单连接就快），代价是单文件 ≤100MB 且不支持 Range，
 * 所以 JDK 包要切分卷（8 → 2 卷，17/21/25 → 3 卷）。这条路径此前**全靠手工网页上传**，
 * 而它有三个一错就很难查的地方：
 *   · 分卷名必须与 `JdkManager.giteeParts` 逐字一致（URL 是 `<base>/<tag>/<附件名>` 直拼）；
 *   · 每卷字节数必须与 `giteePartSizes` 逐一相等（`JdkInstaller.validateInputs()` 在**下载前**
 *     就用它判死，长度不等或数值不对＝该版本直接不能下）；
 *   · 分卷必须是从**同一份**新 zip 切出来的（拼回去要等于整包 sha256）。
 * 手工上传时这三条只能靠人眼，且传错了不会立刻报错 —— 用户侧才炸。
 *
 * 本脚本做的事：读四处 SoT 已经对齐后的那份配置（直接复用 check-jdk-release-pin 的解析器，
 * 所以 SoT 不一致时**跑不起来**），核对本地分卷字节数，按需建 Release，逐卷上传，
 * 最后回读 Gitee 的附件列表逐卷比对 name + size。
 *
 * 用法：
 *   node scripts/upload-gitee-jdk-parts.mjs --dir <分卷所在目录>
 *   node scripts/upload-gitee-jdk-parts.mjs --dir <目录> --only 8        # 只做某个版本
 *   node scripts/upload-gitee-jdk-parts.mjs --dir <目录> --dry-run       # 只看计划，不写网络
 *   node scripts/upload-gitee-jdk-parts.mjs --dir <目录> --replace-mismatched
 *
 * 令牌来源，按优先级：
 *   1) `--token <值>`（⚠️ 会进命令历史，不推荐）
 *   2) 环境变量 `GITEE_TOKEN`
 *   3) `.secrets/gitee-token`（**默认路径，什么都不用设就能跑**；该目录整体被 .gitignore 忽略）
 * 获取：Gitee → 设置 → 私人令牌，勾 `projects` 权限。
 * **脚本不打印令牌**，报错信息里也刻意不带 URL（GET 的 query 里挂着 access_token）。
 *
 * ⚠️ 纪律：本脚本默认**不动**已存在且字节数正确的附件；发现同名但字节数不符时**报错退出**，
 *    要替换必须显式加 `--replace-mismatched`。理由与 GitHub 侧一致 —— 已发布的资产被原地
 *    替换会让那批把 size/sha256 硬编码在 HAP 里的用户装不上且不自愈。
 */
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { run as readSoT } from './check-jdk-release-pin.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const API = 'https://gitee.com/api/v5';

function parseArgs(argv) {
  const out = { dir: null, only: null, token: null, dryRun: false, replaceMismatched: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dir') out.dir = argv[++i];
    else if (a === '--only') out.only = argv[++i];
    else if (a === '--token') out.token = argv[++i];
    else if (a === '--dry-run') out.dryRun = true;
    else if (a === '--replace-mismatched') out.replaceMismatched = true;
    else { console.error(`未知参数: ${a}`); process.exit(2); }
  }
  return out;
}

/**
 * 取令牌：--token → GITEE_TOKEN → .secrets/gitee-token。
 * 返回值**不得**被打印或拼进 URL 后写日志。
 */
function resolveToken(cliToken) {
  if (cliToken) return { token: cliToken, from: '--token' };
  if (process.env.GITEE_TOKEN) return { token: process.env.GITEE_TOKEN, from: 'GITEE_TOKEN 环境变量' };
  const p = path.join(ROOT, '.secrets/gitee-token');
  if (fs.existsSync(p)) {
    const t = fs.readFileSync(p, 'utf8').trim();
    if (t.length > 0) return { token: t, from: '.secrets/gitee-token' };
  }
  return { token: '', from: null };
}

/** 从 JdkManager 的 GITEE_RELEASE_BASE 里取 owner/repo —— 不再硬编码第二份。 */
function readGiteeRepo() {
  const text = fs.readFileSync(path.join(ROOT, 'launch/src/main/ets/JdkManager.ets'), 'utf8');
  const m = text.match(/GITEE_RELEASE_BASE\s*=\s*'https:\/\/gitee\.com\/([^/]+)\/([^/]+)\/releases\/download'/);
  if (!m) throw new Error('JdkManager.ets 里没解析到 GITEE_RELEASE_BASE');
  return { owner: m[1], repo: m[2] };
}

async function api(method, pathname, { token, query, json, form } = {}) {
  const u = new URL(API + pathname);
  if (query) for (const [k, v] of Object.entries(query)) u.searchParams.set(k, String(v));
  if (method === 'GET' && token) u.searchParams.set('access_token', token);
  const init = { method, headers: {} };
  if (json) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify({ ...json, access_token: token });
  } else if (form) {
    init.body = form; // FormData 自带 boundary，不要手写 Content-Type
  }
  const res = await fetch(u, init);
  const text = await res.text();
  let data = null;
  try { data = text.length > 0 ? JSON.parse(text) : null; } catch { /* 非 JSON 原样留在 text */ }
  if (!res.ok) {
    // 绝不把 URL 打出去 —— GET 的 query 里带着 access_token
    const msg = (data && (data.message || data.error_description)) || text.slice(0, 300);
    throw new Error(`${method} ${pathname} -> HTTP ${res.status}: ${msg}`);
  }
  return data;
}

async function findReleaseByTag(owner, repo, tag, token) {
  try {
    return await api('GET', `/repos/${owner}/${repo}/releases/tags/${encodeURIComponent(tag)}`, { token });
  } catch (e) {
    if (String(e.message).includes('HTTP 404')) return null;
    throw e;
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const { token, from: tokenFrom } = resolveToken(args.token);
  if (!args.dir) {
    console.error('缺 --dir <分卷所在目录>');
    process.exit(2);
  }
  if (!fs.existsSync(args.dir)) {
    console.error(`目录不存在: ${args.dir}`);
    process.exit(2);
  }
  if (!token && !args.dryRun) {
    console.error('缺 Gitee 令牌。三种给法（按优先级）：--token <值> / 环境变量 GITEE_TOKEN /'
      + ' .secrets/gitee-token 单行文本。也可先用 --dry-run 看计划。');
    console.error('获取：Gitee → 设置 → 私人令牌，勾 projects 权限。');
    process.exit(2);
  }
  // 只报来源，不报值
  console.log(`[upload-gitee] 令牌来源：${tokenFrom === null ? '（无）' : tokenFrom}`);

  // 复用门禁的解析器：SoT 不一致时直接拒绝上传（避免把不一致的分卷传上去）
  const sot = readSoT(ROOT);
  if (sot.problems.length > 0) {
    console.error('[upload-gitee] 拒绝上传：四处 SoT 尚未对齐，先跑 node scripts/check-jdk-release-pin.mjs');
    for (const p of sot.problems) console.error('  - ' + p);
    process.exit(1);
  }
  const { owner, repo } = readGiteeRepo();
  console.log(`[upload-gitee] 目标仓库 ${owner}/${repo}${args.dryRun ? '（dry-run，不写网络）' : ''}`);

  const vers = Object.keys(sot.jdk).sort((a, b) => Number(a) - Number(b));
  let failures = 0;

  for (const v of vers) {
    if (args.only && args.only !== v) continue;
    const j = sot.jdk[v];
    console.log(`\n=== JDK ${v} — tag ${j.tag} ===`);
    if (j.giteeParts.length === 0) {
      console.log('  该版本未配置 Gitee 分卷，跳过');
      continue;
    }

    // ---- 1) 本地分卷先自证：存在 + 字节数与 SoT 逐一相等 ----
    let localOk = true;
    for (let i = 0; i < j.giteeParts.length; i++) {
      const name = j.giteeParts[i];
      const want = j.giteePartSizes[i];
      const p = path.join(args.dir, name);
      if (!fs.existsSync(p)) { console.error(`  ❌ 本地缺分卷 ${name}`); localOk = false; continue; }
      const got = fs.statSync(p).size;
      if (got !== want) {
        console.error(`  ❌ ${name} 本地 ${got} B ≠ SoT ${want} B`);
        localOk = false;
      } else {
        console.log(`  本地 ${name}  ${got} B  ✓`);
      }
    }
    if (!localOk) { failures++; console.error('  ⇒ 本地分卷与 SoT 不符，该版本跳过'); continue; }

    if (args.dryRun) {
      console.log(`  [dry-run] 将确保 Gitee 存在 tag ${j.tag} 的 Release，并上传 ${j.giteeParts.length} 个分卷`);
      continue;
    }

    // ---- 2) Release 存在性 ----
    let rel = await findReleaseByTag(owner, repo, j.tag, token);
    if (rel === null) {
      const repoInfo = await api('GET', `/repos/${owner}/${repo}`, { token });
      const branch = repoInfo.default_branch || 'master';
      console.log(`  Gitee 上没有 ${j.tag}，创建（target_commitish=${branch}）`);
      rel = await api('POST', `/repos/${owner}/${repo}/releases`, {
        token,
        json: {
          tag_name: j.tag,
          name: `JDK ${v} (OHOS) ${j.tag}`,
          body: `国内镜像：${j.dataFile} 切 ${j.giteeParts.length} 卷。`
            + `整包 sizeBytes=${j.sizeBytes} sha256=${j.sha256}。`
            + `权威发布在 GitHub LZZLHY/mc-ohos-resources ${j.tag}。`,
          target_commitish: branch,
          prerelease: false,
        },
      });
      console.log(`  已创建 Release id=${rel.id}`);
    } else {
      console.log(`  已有 Release id=${rel.id}`);
    }

    // ---- 3) 逐卷上传（幂等）----
    let attaches = await api('GET', `/repos/${owner}/${repo}/releases/${rel.id}/attach_files`,
      { token, query: { per_page: 100 } }) || [];
    for (let i = 0; i < j.giteeParts.length; i++) {
      const name = j.giteeParts[i];
      const want = j.giteePartSizes[i];
      const p = path.join(args.dir, name);
      const exist = attaches.find((a) => a.name === name);
      if (exist && Number(exist.size) === want) {
        console.log(`  已存在且字节数正确，跳过 ${name}`);
        continue;
      }
      if (exist) {
        if (!args.replaceMismatched) {
          console.error(`  ❌ ${name} 线上已存在但 ${exist.size} B ≠ ${want} B。`);
          console.error('     这可能是上一版的残留。确认没有已发布客户端依赖它之后，加 --replace-mismatched 重传。');
          failures++;
          continue;
        }
        console.log(`  删除字节数不符的旧附件 ${name}（id=${exist.id}）`);
        await api('DELETE', `/repos/${owner}/${repo}/releases/${rel.id}/attach_files/${exist.id}`, { token });
      }
      const buf = fs.readFileSync(p);
      const form = new FormData();
      form.set('access_token', token);
      form.set('file', new File([buf], name, { type: 'application/octet-stream' }));
      process.stdout.write(`  上传 ${name}（${want} B）… `);
      const up = await api('POST', `/repos/${owner}/${repo}/releases/${rel.id}/attach_files`, { token, form });
      console.log(`ok（id=${up && up.id ? up.id : '?'}）`);
      attaches = await api('GET', `/repos/${owner}/${repo}/releases/${rel.id}/attach_files`,
        { token, query: { per_page: 100 } }) || [];
    }

    // ---- 4) 回读核对（上传成功 ≠ 传对了）----
    attaches = await api('GET', `/repos/${owner}/${repo}/releases/${rel.id}/attach_files`,
      { token, query: { per_page: 100 } }) || [];
    let allOk = true;
    for (let i = 0; i < j.giteeParts.length; i++) {
      const name = j.giteeParts[i];
      const want = j.giteePartSizes[i];
      const a = attaches.find((x) => x.name === name);
      if (!a) { console.error(`  ❌ 回读缺 ${name}`); allOk = false; continue; }
      if (Number(a.size) !== want) {
        console.error(`  ❌ 回读 ${name} 线上 ${a.size} B ≠ SoT ${want} B`);
        allOk = false;
        continue;
      }
      console.log(`  线上 ${name}  ${a.size} B  ✓`);
    }
    if (allOk) {
      console.log(`  ⇒ JDK ${v} 的 ${j.giteeParts.length} 个分卷已就位，直链形如：`);
      console.log(`     https://gitee.com/${owner}/${repo}/releases/download/${j.tag}/${j.giteeParts[0]}`);
    } else {
      failures++;
    }
  }

  console.log('');
  if (failures > 0) {
    console.error(`[upload-gitee] FAIL — ${failures} 个版本没收口`);
    process.exit(1);
  }
  console.log('[upload-gitee] DONE');
  console.log('  提醒：Gitee 只是国内快路径。它没传成功也不会让功能坏（会回退 GitHub 镜像多段下载），');
  console.log('        但国内用户会明显变慢 ⇒ 发 HAP 之前应当传完。');
}

main().catch((e) => {
  console.error('[upload-gitee] 异常：' + e.message);
  process.exit(1);
});
