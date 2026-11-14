/** 发布工具与网站共用的纯目录结构/代次契约；不要在消费者维护第二份版本列表。 */
const ID = /^[a-z0-9][a-z0-9._-]{0,95}$/;
const HASH = /^[0-9a-f]{64}$/;

/** 不使用隐式转换：null、字符串数字、数组对象等都拒绝，错误能定位到字段。 */
function assert(test, message) { if (!test) throw new Error(message); }
function object(x, name, keys) {
  assert(x !== null && typeof x === 'object' && !Array.isArray(x), name + ': expected object');
  assert(Object.keys(x).every(k => keys.includes(k)), name + ': unknown field');
}
function text(x, name, max = 256) { assert(typeof x === 'string' && x.length > 0 && x.length <= max, name + ': expected bounded string'); }
function id(x, name) { text(x, name, 96); assert(ID.test(x), name + ': invalid id'); }
function integer(x, name, min = 1, max = Number.MAX_SAFE_INTEGER) { assert(Number.isSafeInteger(x) && x >= min && x <= max, name + ': invalid integer'); }
function list(x, name, max, min = 0) { assert(Array.isArray(x) && x.length >= min && x.length <= max, name + ': invalid array'); }
function unique(values, name) { assert(new Set(values).size === values.length, name + ': duplicate'); }
function url(value) {
  text(value, 'url', 2048);
  const parsed = new URL(value);
  assert(parsed.protocol === 'https:' && !parsed.username && !parsed.password && !parsed.hash, 'HTTPS URL without credentials/hash required');
  // 下载凭据不能进入签名目录；URL 可以含公开 CDN 查询参数，但不允许本机/内网地址。
  assert(!/^(localhost|127\.|0\.|10\.|192\.168\.|169\.254\.|\[|172\.(1[6-9]|2\d|3[01])\.)/i.test(parsed.hostname), 'local download URL forbidden');
}

/** 对象字段必须完整且有界。签名可信也不允许超大数组/包、越界版本或不明归档。 */
export function validateCatalog(c, channel) {
  object(c, 'catalog', ['schemaVersion','catalogRevision','channel','issuedAt','expiresAt','runtimes','builds']);
  assert(c.schemaVersion === 1, 'unsupported schemaVersion');
  assert(['stable','preview'].includes(c.channel) && (!channel || c.channel === channel), 'channel mismatch');
  integer(c.catalogRevision, 'catalogRevision');
  for (const k of ['issuedAt','expiresAt']) { text(c[k], k); assert(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(c[k]) && Number.isFinite(Date.parse(c[k])), 'invalid UTC time'); }
  assert(Date.parse(c.expiresAt) > Date.parse(c.issuedAt), 'invalid validity interval');
  list(c.runtimes, 'runtimes', 64, 1); list(c.builds, 'builds', 256, 1);
  unique(c.runtimes.map(r => r.id), 'runtime id'); unique(c.runtimes.map(r => r.javaMajor), 'major slot');
  unique(c.builds.map(b => b.id), 'build id');
  // 新 buildId 不能借同名 ZIP 覆盖历史下载身份；资产文件名也必须全目录唯一。
  unique(c.builds.map(b => b.archive?.fileName), 'archive filename');
  for (const r of c.runtimes) {
    object(r, 'runtime', ['id','javaMajor','displayName','os','arch','libc','adapter','minimumCatalogProtocol','minimumApi','loaderProtocol','recommendationRevision','recommendedBuildId','rollback']);
    id(r.id, 'runtime.id'); integer(r.javaMajor, 'javaMajor', 8, 999); text(r.displayName,'displayName',100);
    for (const k of ['os','arch','libc','adapter']) id(r[k], k);
    integer(r.minimumCatalogProtocol, 'minimumCatalogProtocol', 1, 999); integer(r.minimumApi,'minimumApi',1,999);
    integer(r.loaderProtocol,'loaderProtocol',1,999); integer(r.recommendationRevision, 'recommendationRevision');
    id(r.recommendedBuildId, 'recommendedBuildId');
    if(r.rollback!==undefined){
      object(r.rollback,'rollback',['fromBuildIds','reason']);list(r.rollback.fromBuildIds,'rollback source',32,1);text(r.rollback.reason,'rollback reason',1000);
      for(const value of r.rollback.fromBuildIds)id(value,'rollback source id');unique(r.rollback.fromBuildIds,'rollback source');
      assert(!r.rollback.fromBuildIds.includes(r.recommendedBuildId),'rollback target cannot be source');
      for(const value of r.rollback.fromBuildIds)assert(c.builds.some(b=>b.id===value&&b.runtimeId===r.id&&b.status==='withdrawn'),'rollback source must be a withdrawn build in the same runtime');
    }
    const b = c.builds.find(b => b.id === r.recommendedBuildId && b.runtimeId === r.id);
    assert(b && b.status === 'available', 'recommendation missing or withdrawn');
  }
  for (const b of c.builds) {
    object(b, 'build', ['id','runtimeId','javaVersion','legacyTags','archive','downloads','notes','capabilities','validationLevel','provenance','status']);
    id(b.id, 'build.id'); id(b.runtimeId, 'runtimeId'); text(b.javaVersion,'javaVersion',80);
    assert(c.runtimes.some(r => r.id === b.runtimeId), 'orphan build');
    assert(['available','withdrawn'].includes(b.status), 'invalid build status');
    list(b.legacyTags,'legacyTags',16); for (const tag of b.legacyTags) id(tag,'legacyTag');
    object(b.archive, 'archive', ['type','fileName','sizeBytes','sha256']);
    assert(b.archive.type === 'zip', 'unsupported archive');
    assert(typeof b.archive.fileName === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,150}\.zip$/.test(b.archive.fileName), 'unsafe archive fileName');
    integer(b.archive.sizeBytes, 'sizeBytes', 1, 2147483647); assert(HASH.test(b.archive.sha256), 'invalid archive hash');
    list(b.downloads,'downloads',8,1); unique(b.downloads.map(d => d.sourceId), 'source');
    for (const d of b.downloads) {
      object(d, 'download', ['sourceId','transport','url','parts']);
      assert(['github','gitee','web'].includes(d.sourceId), 'unsupported source');
      if (d.transport === 'single-file') { url(d.url); assert(d.parts === undefined, 'unexpected parts'); }
      else {
        assert(d.transport === 'concat-parts' && d.url === undefined, 'unsupported transport');
        list(d.parts,'parts',16,2); let sum = 0;
        for (const p of d.parts) {
          object(p,'part',['url','sizeBytes','sha256']); url(p.url); integer(p.sizeBytes,'part size',1,b.archive.sizeBytes);
          assert(HASH.test(p.sha256),'invalid part hash'); sum += p.sizeBytes;
        }
        unique(d.parts.map(p => p.url),'part URL'); assert(sum === b.archive.sizeBytes, 'parts total mismatch');
      }
      // 来源类别也是客户端网络偏好的边界，不能把自有 URL 标成 github 绕过默认关闭。
      const addresses=d.transport==='single-file'?[d.url]:d.parts.map(p=>p.url);
      for(const address of addresses){
        if(d.sourceId==='github')assert(address.startsWith('https://github.com/'),'github source host mismatch');
        if(d.sourceId==='gitee')assert(address.startsWith('https://gitee.com/'),'gitee source host mismatch');
      }
    }
    list(b.notes,'notes',24); for (const note of b.notes) text(note,'note',1000);
    list(b.capabilities,'capabilities',24); for (const cap of b.capabilities) id(cap,'capability');
    assert(['legacy-compatible','artifact-audited','target-device-tested','device-matrix-tested'].includes(b.validationLevel), 'unknown validation level');
    object(b.provenance,'provenance',['kind','sourceRepository','sourceCommit','manifestSha256','evidence']);
    assert(['legacy','source-build'].includes(b.provenance.kind), 'unknown provenance');
    text(b.provenance.sourceRepository,'sourceRepository',256);
    assert(/^[0-9a-f]{40}$/.test(b.provenance.sourceCommit), 'invalid source commit');
    assert(b.provenance.manifestSha256 === '' || HASH.test(b.provenance.manifestSha256), 'invalid manifest hash');
    list(b.provenance.evidence,'evidence',24); for (const e of b.provenance.evidence) text(e,'evidence',1000);
  }
  return c;
}

/** 同 buildId 必须保持二进制身份；可增加镜像/验收记录，不制造无意义更新。 */
export function buildIdentity(b) { return JSON.stringify([b.runtimeId,b.javaVersion,b.archive.type,b.archive.fileName,b.archive.sizeBytes,b.archive.sha256]); }
export function runtimeIdentity(r) { return JSON.stringify([r.javaMajor,r.os,r.arch,r.libc,r.adapter]); }
/** 同一runtime保存已装历史槽的可达范围。提高整体门槛会连安全替代一起隐藏，不能靠加代次退休旧用户。 */
export function validateRuntimeAdmission(previous,next,checkCatalogProtocol=true) {
  assert(next.minimumApi<=previous.minimumApi,'runtime admission minimumApi tightened: '+previous.id);
  if(checkCatalogProtocol)assert(next.minimumCatalogProtocol<=previous.minimumCatalogProtocol,'runtime admission minimumCatalogProtocol tightened: '+previous.id);
}
export function validateTransition(previous, next) {
  if (!previous) return;
  assert(next.channel === previous.channel, 'channel transition mismatch');
  assert(next.catalogRevision >= previous.catalogRevision, 'catalog rollback');
  if (next.catalogRevision === previous.catalogRevision) {
    assert(JSON.stringify(next) === JSON.stringify(previous), 'same revision changed'); return;
  }
  for (const old of previous.builds) {
    const fresh = next.builds.find(b => b.id === old.id);
    // 保留历史身份，回滚推荐也不需要删除旧条目；撤回使用显式状态。
    assert(fresh && buildIdentity(old) === buildIdentity(fresh), 'build removed or identity changed: ' + old.id);
    assert(old.status!=='withdrawn'||fresh.status==='withdrawn','withdrawn build id cannot be revived');
  }
  for (const old of previous.runtimes) {
    const fresh = next.runtimes.find(r => r.id === old.id);
    if (!fresh) continue; // 下架列表不意味着卸载本地运行时。
    assert(runtimeIdentity(old) === runtimeIdentity(fresh), 'runtime identity changed');
    validateRuntimeAdmission(old,fresh);
    assert(fresh.recommendationRevision >= old.recommendationRevision, 'recommendation rollback');
    assert(fresh.recommendedBuildId === old.recommendedBuildId || fresh.recommendationRevision > old.recommendationRevision, 'changed recommendation needs new revision');
    if (['minimumCatalogProtocol','minimumApi','loaderProtocol'].some(k=>fresh[k]!==old[k]))
      assert(fresh.recommendationRevision>old.recommendationRevision,'changed admission requires new recommendation revision');
    if(JSON.stringify(fresh.rollback)!==JSON.stringify(old.rollback))assert(fresh.recommendationRevision>old.recommendationRevision,'changed rollback requires new recommendation revision');
  }
}
