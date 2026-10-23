/**
 * 不依赖 UI/网络的目录边界校验。先检查运行时类型，再使用 JSON 中的值；
 * 验签不意味着任意字符串、槽位或能力可执行。未知平台/adapter 保留但不准安装。
 * 与发布仓 tools/protocol.mjs 使用同一契约，宿主互操作测试直接执行本生产文件。
 */
import { RuntimeCatalog, RuntimeDefinition, RuntimeBuild } from './RuntimeCatalogTypes';

export const RUNTIME_CATALOG_LIMIT: number = 1024 * 1024;

function requireValue(condition: boolean, label: string): void {
  if (!condition) throw new Error('JDK 目录无效：' + label);
}
export function requireCatalogObject(value: Object, fields: string[], label: string): void {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value), label);
  for (const key of Object.keys(value)) requireValue(fields.indexOf(key) >= 0, label + ' 未知字段 ' + key);
}
function boundedText(value: string, limit: number, label: string): void {
  requireValue(typeof value === 'string' && value.length > 0 && value.length <= limit, label);
}
function identifier(value: string): void {
  boundedText(value, 96, '身份');
  requireValue(new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(value), '身份格式');
}
function integer(value: number, min: number, max: number): void {
  requireValue(typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max, '整数范围');
}
function arrayLimit(value: Object, min: number, max: number): void {
  requireValue(Array.isArray(value), '数组');
  const length = (value as Object[]).length;
  requireValue(length >= min && length <= max, '数组数量');
}
function unique(values: string[], label: string): void {
  const seen: string[] = [];
  for (const value of values) { requireValue(seen.indexOf(value) < 0, label + ' 重复'); seen.push(value); }
}
function hash(value: string): void {
  requireValue(typeof value === 'string' && new RegExp('^[0-9a-f]{64}$').test(value), 'SHA-256');
}
/** HTTPS 地址不含账号、fragment、控制字符或本机地址；路径是下载目标，不是本地路径。 */
export function validateRuntimeUrl(value: string): void {
  boundedText(value, 2048, '下载 URL');
  requireValue(!new RegExp('[\\s\\x00-\\x1f\\x7f\\\\#]').test(value), 'URL 字符');
  const match = value.match(new RegExp('^https://([a-zA-Z0-9.-]+)(?::([0-9]+))?(?:[/?].*)?$'));
  requireValue(match !== null, 'HTTPS URL');
  if (match === null) return;
  const host = match[1].toLowerCase();
  requireValue(!new RegExp('^(localhost|127\\.|0\\.|10\\.|192\\.168\\.|169\\.254\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)').test(host), '内网 URL');
}

/** 解析整体目录；任一身份、引用或摘要错误拒绝整个快照，不能部分安装损坏目录。 */
export function parseRuntimeCatalog(text: string, expectedChannel: string = ''): RuntimeCatalog {
  requireValue(typeof text === 'string' && text.length <= RUNTIME_CATALOG_LIMIT, '目录长度');
  const c = JSON.parse(text) as RuntimeCatalog;
  requireCatalogObject(c, ['schemaVersion','catalogRevision','channel','issuedAt','expiresAt','runtimes','builds'], '目录');
  requireValue(c.schemaVersion === 1, 'schemaVersion');
  requireValue((c.channel === 'stable' || c.channel === 'preview') && (expectedChannel === '' || c.channel === expectedChannel), '通道');
  integer(c.catalogRevision, 1, Number.MAX_SAFE_INTEGER);
  for (const value of [c.issuedAt,c.expiresAt]) {
    boundedText(value, 30, '日期');
    requireValue(new RegExp('^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$').test(value) && Number.isFinite(Date.parse(value)), 'UTC 日期');
  }
  requireValue(Date.parse(c.expiresAt) > Date.parse(c.issuedAt), '有效期');
  arrayLimit(c.runtimes, 1, 64); arrayLimit(c.builds, 1, 256);
  const ids: string[] = []; const majors: string[] = []; const bids: string[] = [];
  for (const r of c.runtimes) {
    requireCatalogObject(r, ['id','javaMajor','displayName','os','arch','libc','adapter','minimumCatalogProtocol','minimumApi','loaderProtocol','recommendationRevision','recommendedBuildId','rollback'], '运行时');
    identifier(r.id); integer(r.javaMajor, 8, 999); boundedText(r.displayName,100,'名称');
    for (const value of [r.os,r.arch,r.libc,r.adapter,r.recommendedBuildId]) identifier(value);
    integer(r.minimumCatalogProtocol,1,999); integer(r.minimumApi,1,999); integer(r.loaderProtocol,1,999);
    integer(r.recommendationRevision,1,Number.MAX_SAFE_INTEGER);
    if (r.rollback !== undefined) {
      requireCatalogObject(r.rollback,['fromBuildIds','reason'],'回退指令');
      arrayLimit(r.rollback.fromBuildIds,1,32); boundedText(r.rollback.reason,1000,'回退原因');
      for (const id of r.rollback.fromBuildIds) identifier(id);
      unique(r.rollback.fromBuildIds,'回退来源');
      requireValue(r.rollback.fromBuildIds.indexOf(r.recommendedBuildId) < 0,'回退目标不能同时是来源');
    }
    ids.push(r.id); majors.push(r.javaMajor.toString());
  }
  unique(ids,'运行时'); unique(majors,'主版本槽位');
  for (const b of c.builds) {
    requireCatalogObject(b, ['id','runtimeId','javaVersion','legacyTags','archive','downloads','notes','capabilities','validationLevel','provenance','status'], '构建');
    identifier(b.id); identifier(b.runtimeId); boundedText(b.javaVersion,80,'Java 版本');
    requireValue(ids.indexOf(b.runtimeId) >= 0, '孤立构建'); bids.push(b.id);
    requireValue(b.status === 'available' || b.status === 'withdrawn', '构建状态');
    arrayLimit(b.legacyTags,0,16); for (const tag of b.legacyTags) identifier(tag);
    requireCatalogObject(b.archive,['type','fileName','sizeBytes','sha256'],'归档');
    requireValue(b.archive.type === 'zip','归档类型');
    boundedText(b.archive.fileName,155,'包文件名');
    requireValue(new RegExp('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,150}\\.zip$').test(b.archive.fileName),'包文件名');
    integer(b.archive.sizeBytes,1,2147483647); hash(b.archive.sha256);
    arrayLimit(b.downloads,1,8); const sources: string[] = [];
    for (const d of b.downloads) {
      requireCatalogObject(d,['sourceId','transport','url','parts'],'下载');
      requireValue(['github','gitee','web'].indexOf(d.sourceId) >= 0,'来源'); sources.push(d.sourceId);
      if (d.transport === 'single-file') {
        requireValue(d.parts === undefined && d.url !== undefined,'单文件描述'); validateRuntimeUrl(d.url as string);
      } else {
        requireValue(d.transport === 'concat-parts' && d.url === undefined && d.parts !== undefined,'分卷描述');
        const parts = d.parts!; arrayLimit(parts,2,16); let sum = 0; const urls: string[] = [];
        for (const p of parts) {
          requireCatalogObject(p,['url','sizeBytes','sha256'],'分卷'); validateRuntimeUrl(p.url);
          integer(p.sizeBytes,1,b.archive.sizeBytes); hash(p.sha256); sum += p.sizeBytes; urls.push(p.url);
        }
        unique(urls,'分卷 URL'); requireValue(sum === b.archive.sizeBytes,'分卷总大小');
      }
      // “源站/Gitee”不能被目录改标成自有服务；即使签名可信，也保留用户的来源选择边界。
      const addresses: string[] = d.transport === 'single-file' ? [d.url!] : d.parts!.map((part): string => part.url);
      for (const address of addresses) {
        if (d.sourceId === 'github') requireValue(address.startsWith('https://github.com/'),'GitHub 来源域名');
        if (d.sourceId === 'gitee') requireValue(address.startsWith('https://gitee.com/'),'Gitee 来源域名');
      }
    }
    unique(sources,'下载源'); arrayLimit(b.notes,0,24); for (const note of b.notes) boundedText(note,1000,'说明');
    arrayLimit(b.capabilities,0,24); for (const cap of b.capabilities) identifier(cap);
    requireValue(['legacy-compatible','artifact-audited','target-device-tested','device-matrix-tested'].indexOf(b.validationLevel) >= 0,'验收等级');
    const p = b.provenance;
    requireCatalogObject(p,['kind','sourceRepository','sourceCommit','manifestSha256','evidence'],'来源证据');
    requireValue(p.kind === 'legacy' || p.kind === 'source-build','来源类型'); boundedText(p.sourceRepository,256,'源码仓');
    requireValue(typeof p.sourceCommit === 'string' && new RegExp('^[0-9a-f]{40}$').test(p.sourceCommit),'源码提交');
    if (p.manifestSha256 !== '') hash(p.manifestSha256);
    arrayLimit(p.evidence,0,24); for (const evidence of p.evidence) boundedText(evidence,1000,'证据');
  }
  unique(bids,'构建');
  for (const r of c.runtimes) requireValue(c.builds.some((b: RuntimeBuild): boolean => b.id === r.recommendedBuildId && b.runtimeId === r.id && b.status === 'available'),'推荐引用');
  for (const r of c.runtimes) if (r.rollback !== undefined) {
    for (const id of r.rollback.fromBuildIds) requireValue(c.builds.some((b: RuntimeBuild): boolean => b.id === id && b.runtimeId === r.id && b.status === 'withdrawn'),'回退来源必须是已撤回的同槽构建');
  }
  return c;
}

/** 新主版本必须命中已有布局和原生装载协议；元数据不能授权新的平台能力。 */
export function supportsRuntime(r: RuntimeDefinition, apiVersion: number): boolean {
  return r.os === 'ohos' && r.arch === 'aarch64' && r.libc === 'musl' &&
    r.minimumCatalogProtocol <= 1 && r.minimumApi <= apiVersion && r.loaderProtocol === 1 &&
    ((r.javaMajor === 8 && r.adapter === 'classic-jre-v1') || (r.javaMajor >= 17 && r.adapter === 'modular-jdk-v1'));
}
export function runtimeBuildIdentity(b: RuntimeBuild): string {
  // 固定顺序的原始字段投影，不受 JSON 对象属性顺序影响。
  return [b.runtimeId,b.javaVersion,b.archive.type,b.archive.fileName,b.archive.sizeBytes.toString(),b.archive.sha256].join('|');
}
/** 全局代次与各运行时推荐代次分开；更高代次可以主动回滚到仍登记的旧 build。 */
export function validateRuntimeTransition(previous: RuntimeCatalog, next: RuntimeCatalog): void {
  requireValue(previous.channel === next.channel && next.catalogRevision >= previous.catalogRevision,'目录降代次');
  if (next.catalogRevision === previous.catalogRevision) {
    requireValue(JSON.stringify(previous) === JSON.stringify(next),'同代次内容变化'); return;
  }
  for (const b of previous.builds) {
    const current = next.builds.find((x: RuntimeBuild): boolean => x.id === b.id);
    requireValue(current !== undefined && runtimeBuildIdentity(current!) === runtimeBuildIdentity(b),'构建身份漂移');
    requireValue(b.status !== 'withdrawn' || current!.status === 'withdrawn','撤回构建不可复活');
  }
  for (const r of previous.runtimes) {
    const current = next.runtimes.find((x: RuntimeDefinition): boolean => x.id === r.id);
    if (current === undefined) continue;
    requireValue(current.javaMajor === r.javaMajor && current.os === r.os && current.arch === r.arch && current.libc === r.libc && current.adapter === r.adapter,'槽位身份漂移');
    requireValue(current.recommendationRevision >= r.recommendationRevision &&
      (current.recommendedBuildId === r.recommendedBuildId || current.recommendationRevision > r.recommendationRevision),'推荐降代次');
    if (JSON.stringify(current.rollback) !== JSON.stringify(r.rollback)) {
      requireValue(current.recommendationRevision > r.recommendationRevision,'回退指令变化必须增加推荐代次');
    }
  }
}

/** JWS 使用 64 字节 r||s；系统 ECC 验签使用 ASN.1 DER 正整数序列。 */
export function p1363ToDer(signature: Uint8Array): Uint8Array {
  requireValue(signature.length === 64,'ES256 签名长度');
  const integers: number[][] = [];
  for (let offset = 0; offset < 64; offset += 32) {
    let start = offset; while (start < offset + 31 && signature[start] === 0) start++;
    const data: number[] = [];
    if ((signature[start] & 128) !== 0) data.push(0);
    for (let i = start; i < offset + 32; i++) data.push(signature[i]);
    integers.push(data);
  }
  const result: number[] = [48,4 + integers[0].length + integers[1].length];
  for (const value of integers) { result.push(2,value.length); for (const byte of value) result.push(byte); }
  return new Uint8Array(result);
}
