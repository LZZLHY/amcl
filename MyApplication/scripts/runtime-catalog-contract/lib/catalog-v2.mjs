/**
 * 目录v2：宿主要求属于不可变build，推荐列表只表达顺序；签名与平台准入仍分别执行。
 * 复用v1字段验证器检查共同数据，规范化副本仅用于结构验证，不作为签名/发布原文。
 */
import {validateCatalog,validateTransition,buildIdentity,runtimeIdentity,validateRuntimeAdmission} from './catalog-validation.mjs';
const clone=value=>structuredClone(value);
const assert=(test,message)=>{if(!test)throw Error(message);};
const ids=r=>r.recommendedBuildIds;

export function validateCatalogV2(c,channel){
  assert(c?.schemaVersion===2,'unsupported v2 schema');
  assert(Array.isArray(c.runtimes)&&c.runtimes.length>0&&c.runtimes.length<=64,'invalid runtimes');
  assert(Array.isArray(c.builds)&&c.builds.length>0&&c.builds.length<=256,'invalid builds');
  const copy=clone(c);copy.schemaVersion=1;
  for(const build of copy.builds){
    assert(Number.isSafeInteger(build.requiredHostProtocol)&&build.requiredHostProtocol>=1&&build.requiredHostProtocol<=999,'invalid requiredHostProtocol');
    delete build.requiredHostProtocol;
  }
  for(const runtime of copy.runtimes){
    assert(runtime.loaderProtocol===undefined&&runtime.recommendedBuildId===undefined,'v1 runtime fields in v2');
    const selected=runtime.recommendedBuildIds;
    assert(Array.isArray(selected)&&selected.length<=8&&new Set(selected).size===selected.length,'invalid compatible recommendations');
    for(const id of selected)assert(c.builds.some(b=>b.id===id&&b.runtimeId===runtime.id&&b.status==='available'),'missing/withdrawn compatible recommendation');
    // 空推荐可以停止下载。共同验证器需要一个临时引用；此副本永远不返回给发布者。
    const check=copy.builds.find(b=>b.runtimeId===runtime.id);
    assert(check,'runtime lacks identity history');
    runtime.recommendedBuildId=selected[0]??check.id;runtime.loaderProtocol=1;
    delete runtime.recommendedBuildIds;
    if(!selected.length)check.status='available';
    if(runtime.rollback){
      assert(!selected.some(id=>runtime.rollback.fromBuildIds.includes(id)),'rollback target is source');
      if(!selected.length)delete runtime.rollback;
    }
  }
  validateCatalog(copy,channel);
  // 空列表也保留回退指令校验，不能借结构投影绕过已撤回/同槽要求。
  for(const r of c.runtimes)if(r.rollback){
    assert(Object.keys(r.rollback).every(k=>['fromBuildIds','reason'].includes(k)),'unknown rollback field');
    assert(Array.isArray(r.rollback.fromBuildIds)&&r.rollback.fromBuildIds.length>0&&r.rollback.fromBuildIds.length<=32&&new Set(r.rollback.fromBuildIds).size===r.rollback.fromBuildIds.length,'invalid rollback sources');
    assert(typeof r.rollback.reason==='string'&&r.rollback.reason.length>0&&r.rollback.reason.length<=1000,'invalid rollback reason');
    for(const id of r.rollback.fromBuildIds)assert(c.builds.some(b=>b.id===id&&b.runtimeId===r.id&&b.status==='withdrawn'),'rollback source must be withdrawn same runtime');
  }
  return c;
}

export function validateTransitionV2(previous,next){
  validateCatalogV2(next);if(!previous)return;
  validateCatalogV2(previous);
  assert(next.channel===previous.channel&&next.catalogRevision>=previous.catalogRevision,'v2 catalog rollback');
  if(next.catalogRevision===previous.catalogRevision){assert(JSON.stringify(next)===JSON.stringify(previous),'same v2 revision changed');return;}
  for(const old of previous.builds){
    const fresh=next.builds.find(b=>b.id===old.id);
    assert(fresh&&buildIdentity(old)===buildIdentity(fresh)&&old.requiredHostProtocol===fresh.requiredHostProtocol,'immutable build/host identity changed');
    assert(old.status!=='withdrawn'||fresh.status==='withdrawn','withdrawn build revived');
  }
  for(const old of previous.runtimes){
    const fresh=next.runtimes.find(r=>r.id===old.id);if(!fresh)continue;
    assert(runtimeIdentity(old)===runtimeIdentity(fresh),'runtime identity changed');
    validateRuntimeAdmission(old,fresh);
    assert(fresh.recommendationRevision>=old.recommendationRevision,'recommendation rollback');
    if(JSON.stringify(ids(old))!==JSON.stringify(ids(fresh))||JSON.stringify(old.rollback)!==JSON.stringify(fresh.rollback))assert(fresh.recommendationRevision>old.recommendationRevision,'changed recommendation requires revision');
    if(old.minimumApi!==fresh.minimumApi||old.minimumCatalogProtocol!==fresh.minimumCatalogProtocol)assert(fresh.recommendationRevision>old.recommendationRevision,'changed admission requires revision');
  }
}

/** 同一源生成两通道；稳定的列表每一项都必须满足正式资格，而不只检查第一项。 */
export function projectCatalogCandidate(source,channel){
  assert(source?.schemaVersion===2,'v2 source schema required');
  const c={schemaVersion:2,catalogRevision:source.catalogRevision,channel,issuedAt:source.issuedAt,expiresAt:source.expiresAt,
    runtimes:source.runtimes.map(r=>{const {recommendations,...identity}=r;return{...identity,...recommendations[channel]};}),builds:clone(source.builds)};
  validateCatalogV2(c,channel);
  return c;
}
/** 正式生成路径额外核设备资格；未完成矩阵的候选只能进入明确的隔离验证路径。 */
export function projectCatalogV2(source,channel){
  const c=projectCatalogCandidate(source,channel);
  if(channel==='stable')for(const r of c.runtimes)for(const id of ids(r)){
    const b=c.builds.find(b=>b.id===id);
    assert(b.provenance.kind==='legacy'||b.validationLevel==='device-matrix-tested','stable promotion requires device matrix: '+id);
  }
  return c;
}

/**
 * 旧端不能解析空推荐，但能解析并拒绝不支持的loaderProtocol。没有协议1推荐时投影
 * 第一项的真实宿主要求，让旧App保留现有安装且不下载新包；绝不将协议2伪标为1。
 * App新头另外验证实际v1回落是否满足其行为要求，不能用旧host1包掩盖新App的修复需求。
 */
export function projectLegacyCatalog(source,channel){
  return projectLegacyCatalogFromV2(projectCatalogV2(source,channel));
}
/** 部署者可核v1是否确实是同份已验签v2的兼容投影，避免只比相同代次而混用两个来源。 */
export function projectLegacyCatalogFromV2(c){
  validateCatalogV2(c);const result=clone(c);result.schemaVersion=1;
  for(const r of result.runtimes){
    const compatible=r.recommendedBuildIds.find(id=>c.builds.find(b=>b.id===id).requiredHostProtocol===1) ?? r.recommendedBuildIds[0];
    assert(compatible,'V1_NO_RECOMMENDATION:'+r.id);
    r.recommendedBuildId=compatible;r.loaderProtocol=c.builds.find(b=>b.id===compatible).requiredHostProtocol;r.minimumCatalogProtocol=1;delete r.recommendedBuildIds;
  }
  for(const b of result.builds)delete b.requiredHostProtocol;
  validateCatalog(result,c.channel);return result;
}

/** 实际HAP的行为要求；旧原件缺字段为无新增要求，不把管理员表单当包内事实。 */
export function normalizeRuntimeRequirements(value){
  const capabilities=value.runtimeRequiredCapabilities??[],majors=value.runtimeRequiredMajors??[];
  assert(Array.isArray(capabilities)&&capabilities.length<=24&&new Set(capabilities).size===capabilities.length&&
    capabilities.every(v=>typeof v==='string'&&/^[a-z0-9][a-z0-9._-]{0,95}$/.test(v))&&
    Array.isArray(majors)&&majors.length<=64&&new Set(majors).size===majors.length&&majors.every(v=>Number.isSafeInteger(v)&&v>=8&&v<=999)&&
    (!capabilities.length||majors.length>0),'APP_RUNTIME_REQUIREMENTS_INVALID');
  // null是显式坏字段，不能被??解释成合法历史缺省。
  assert(value.runtimeRequiredCapabilities!==null&&value.runtimeRequiredMajors!==null,'APP_RUNTIME_REQUIREMENTS_INVALID');
  return{runtimeRequiredCapabilities:[...capabilities],runtimeRequiredMajors:[...majors]};
}

/**
 * 反向发布门：stable v1/v2 必须同源并同时存在；供给按实际HAP声明的目录读取能力核验。
 * 显式 reader2 使用 v2 的有序推荐，v1保留旧客户端的host1下载；未声明 reader2 时仍
 * 保持原来的两格式严格门。读取协议、JDK装载ABI和恢复协议是三个独立事实，不能互推。
 * 本函数只接收调用方已验签的目录；有效期、平台及原件身份仍在此独立核对。
 */
export function assertAppRuntimeCoverage(inputCatalogs,host,now=Date.now()){
  assert(host.runtimeCatalogProtocol===undefined||[1,2].includes(host.runtimeCatalogProtocol),'APP_RUNTIME_CATALOG_PROTOCOL_INVALID');
  const requirements=normalizeRuntimeRequirements(host);
  if(!requirements.runtimeRequiredMajors.length)return{required:false,selections:[]};
  assert(Array.isArray(host.runtimeHostProtocols)&&host.runtimeHostProtocols.length>0&&Number.isSafeInteger(host.minApi)&&host.minApi>=1&&host.abi==='arm64-v8a','APP_RUNTIME_HOST_INVALID');
  const catalogs=inputCatalogs.filter(c=>c.channel==='stable');
  assert(catalogs.length===2&&new Set(catalogs.map(c=>c.schemaVersion)).size===2&&catalogs.some(c=>c.schemaVersion===1)&&catalogs.some(c=>c.schemaVersion===2),'APP_STABLE_RUNTIME_PAIR_REQUIRED');
  const modern=catalogs.find(c=>c.schemaVersion===2),legacy=catalogs.find(c=>c.schemaVersion===1);
  validateCatalogV2(modern,'stable');validateCatalog(legacy,'stable');
  assert(JSON.stringify(projectLegacyCatalogFromV2(modern))===JSON.stringify(legacy),'APP_STABLE_RUNTIME_PROJECTION_MISMATCH');
  const selections=[];
  for(const catalog of catalogs){
    assert(Date.parse(catalog.issuedAt)<=now+300000&&Date.parse(catalog.expiresAt)>now,'APP_STABLE_RUNTIME_CATALOG_EXPIRED');
    // 只有实际HAP显式声明 reader2 才不要求其从旧端专用v1取得新ABI包；v1仍须通过
    // 上面的验签调用方、同源投影和有效期检查，不能删除旧入口或用无关目录凑数。
    if(host.runtimeCatalogProtocol===2&&catalog.schemaVersion===1)continue;
    for(const major of requirements.runtimeRequiredMajors){
      const slot=catalog.runtimes.find(r=>r.javaMajor===major);
      assert(slot&&slot.os==='ohos'&&slot.arch==='aarch64'&&slot.libc==='musl'&&slot.minimumApi<=host.minApi&&slot.minimumCatalogProtocol<=catalog.schemaVersion,
        'APP_STABLE_RUNTIME_PLATFORM_MISSING:'+major);
      const ordered=catalog.schemaVersion===2?slot.recommendedBuildIds:[slot.recommendedBuildId];
      const selected=ordered.map(id=>catalog.builds.find(b=>b.id===id&&b.runtimeId===slot.id)).find(b=>b&&b.status==='available'&&
        host.runtimeHostProtocols.includes(catalog.schemaVersion===2?b.requiredHostProtocol:slot.loaderProtocol)&&
        requirements.runtimeRequiredCapabilities.every(capability=>b.capabilities.includes(capability)));
      assert(selected,'APP_STABLE_RUNTIME_INCOMPATIBLE:v'+catalog.schemaVersion+'/'+major);
      assert(selected.provenance.kind==='source-build'&&/^[0-9a-f]{64}$/.test(selected.provenance.manifestSha256)&&selected.validationLevel==='device-matrix-tested',
        'APP_STABLE_RUNTIME_NOT_QUALIFIED:'+major+'/'+selected.id);
      selections.push({schemaVersion:catalog.schemaVersion,catalogRevision:catalog.catalogRevision,javaMajor:major,buildId:selected.id,
        requiredHostProtocol:catalog.schemaVersion===2?selected.requiredHostProtocol:slot.loaderProtocol,sha256:selected.archive.sha256,sizeBytes:selected.archive.sizeBytes});
    }
  }
  return{required:true,...requirements,selections};
}

/** 已公开App收据必须来自真实头；developer、staged或仅自报版本都不能授权公共JDK推荐。 */
export function assertPublishedHostCoverage(catalog,hosts){
  validateCatalogV2(catalog);assert(Array.isArray(hosts),'published host receipts required');
  for(const r of catalog.runtimes)for(const id of ids(r)){
    const b=catalog.builds.find(b=>b.id===id);
    assert(hosts.some(h=>h.schema===1&&h.product==='sideload'&&['stable','preview'].includes(h.channel)&&
      (catalog.channel!=='stable'||h.channel==='stable')&&/^[0-9a-f]{64}$/.test(h.sha256)&&
      Array.isArray(h.runtimeHostProtocols)&&h.runtimeHostProtocols.includes(b.requiredHostProtocol)&&
      Number.isSafeInteger(h.versionCode)&&typeof h.tag==='string'&&h.tag.length>0),
    'PUBLIC_HOST_NOT_READY:'+id+':'+b.requiredHostProtocol);
  }
}

/**
 * 公开宿主事实来自官网对真实HAP的审计及实际通道头。只接受完整原件定位和确定的能力，
 * 不能以管理员填入的“可回退”布尔、developer或尚未公开的候选替代这些事实。
 */
function normalizeHostArtifact(value,product=value?.product,allowHistorical=false){
  const protocols=value?.runtimeHostProtocols,devices=value?.deviceTypes;
  const version=value?.versionName;
  // 1.0.5 原件已在旧官网公开，缺少源码提交声明且沿用通用文件名。
  // 例外绑定既有原件的完整字节身份和实际能力，只供历史/下载曝光读取。
  // 当前推荐头仍走默认严格分支，不能借此让未知旧包或伪造的源码身份参与正向准入。
  const historical=allowHistorical&&value?.product==='sideload'&&value.tag==='v1.0.5'&&
    version==='1.0.5'&&value.versionCode===1000678&&value.name==='amcl-v1.0.5-unsigned.hap'&&
    value.sizeBytes===77157706&&value.sha256==='15e1a1f5d3e3890837a21fb6b579c6b731e3e26fbf0b797572188888736c125f'&&
    value.sourceRevision===''&&value.minApi===20&&value.abi==='arm64-v8a'&&
    JSON.stringify(protocols)==='[1]'&&value.runtimePlanProtocol===0&&Array.isArray(devices)&&
    JSON.stringify([...devices].sort())==='["2in1","phone","tablet"]';
  assert(value?.schema===1&&['sideload','desktop'].includes(product)&&value.product===product&&value.source==='github','PUBLIC_HOST_IDENTITY_INVALID');
  assert(typeof version==='string'&&version.length<=80&&/^\d+\.\d+\.\d+(?:-(?:pre[1-9]\d*|(?:alpha|beta|rc|pre)\.\d+))?$/.test(version)&&
    version.match(/\d+/g).every(n=>Number.isSafeInteger(Number(n)))&&value.tag==='v'+version,'PUBLIC_HOST_VERSION_INVALID');
  const kind=version.includes('-')?'preview':'stable';
  assert(value.releaseKind===kind&&
    Number.isSafeInteger(value.versionCode)&&value.versionCode>0&&value.versionCode<=2147483647,'PUBLIC_HOST_RELEASE_INVALID');
  assert(typeof value.sha256==='string'&&typeof value.sourceRevision==='string'&&/^[0-9a-f]{64}$/.test(value.sha256)&&
    (historical||/^[0-9a-f]{40}$/.test(value.sourceRevision))&&Number.isSafeInteger(value.sizeBytes)&&value.sizeBytes>0&&value.sizeBytes<=2147483648,'PUBLIC_HOST_ORIGINAL_INVALID');
  const name=historical?'amcl-v1.0.5-unsigned.hap':'amcl-'+value.tag+'-'+product+'-unsigned.hap';
  assert(value.name===name&&value.websiteUrl==='https://amcl.lovedhy.cn/api/packages/files/'+value.sha256+'/'+encodeURIComponent(name),'PUBLIC_HOST_URL_INVALID');
  assert(Array.isArray(protocols)&&protocols.length>0&&protocols.length<=8&&new Set(protocols).size===protocols.length&&
    protocols.every(p=>Number.isSafeInteger(p)&&p>=1&&p<=999)&&[0,1,2].includes(value.runtimePlanProtocol),'PUBLIC_HOST_PROTOCOL_INVALID');
  assert(Number.isSafeInteger(value.minApi)&&value.minApi>=1&&value.minApi<=999&&value.abi==='arm64-v8a'&&
    Array.isArray(devices)&&devices.length>0&&devices.length<=3&&new Set(devices).size===devices.length&&
    devices.every(d=>['phone','tablet','2in1'].includes(d)),'PUBLIC_HOST_PLATFORM_INVALID');
  const requirements=normalizeRuntimeRequirements(value);
  assert(value.runtimeCatalogProtocol===undefined||[1,2].includes(value.runtimeCatalogProtocol),'PUBLIC_HOST_CATALOG_PROTOCOL_INVALID');
  const declaredCatalog=value.runtimeCatalogProtocol===undefined?{}:{runtimeCatalogProtocol:value.runtimeCatalogProtocol};
  const declaredRequirements=value.runtimeRequiredCapabilities!==undefined||value.runtimeRequiredMajors!==undefined?requirements:{};
  return{schema:1,product,source:'github',releaseKind:kind,tag:value.tag,versionName:version,versionCode:value.versionCode,
    name,sha256:value.sha256,sizeBytes:value.sizeBytes,sourceRevision:value.sourceRevision,
    websiteUrl:value.websiteUrl,minApi:value.minApi,abi:value.abi,deviceTypes:[...devices].sort(),
    runtimeHostProtocols:[...protocols].sort((a,b)=>a-b),runtimePlanProtocol:value.runtimePlanProtocol,...declaredCatalog,...declaredRequirements};
}
export function normalizePublishedHost(value,product=value?.product,channel=value?.channel,allowHistorical=false){
  const artifact=normalizeHostArtifact(value,product,allowHistorical);
  // channels-v1 迁移曾写入这个真实旧指针。保留原字符串，不给历史补造 64 位发布 ID。
  // allowHistorical 只用于不可变历史行，heads 调用者始终使用默认 false。
  const legacyPublication=allowHistorical&&artifact.sourceRevision===''&&channel==='stable'&&
    value.publicationId==='legacy-v1.0.5-sideload-1000678';
  assert(['stable','preview'].includes(channel)&&value.channel===channel&&(channel!=='stable'||artifact.releaseKind==='stable')&&
    typeof value.publicationId==='string'&&(legacyPublication||/^[0-9a-f]{64}$/.test(value.publicationId)),'PUBLIC_HOST_IDENTITY_INVALID');
  return{...artifact,channel,publicationId:value.publicationId};
}
/** ready官方原件已可人工公开下载，属于独立曝光事实；没有假通道或publicationId。 */
export function normalizeOfficialDownloadExposure(value,product=value?.product){
  const artifact=normalizeHostArtifact(value,product,true);
  assert(value.kind==='official-download-exposure'&&value.channel===undefined&&value.publicationId===undefined&&
    typeof value.exposureId==='string'&&/^[0-9a-f]{64}$/.test(value.exposureId),'PUBLIC_HOST_EXPOSURE_IDENTITY_INVALID');
  assert(value.githubUrl==='https://github.com/LZZLHY/amcl/releases/download/'+artifact.tag+'/'+artifact.name,'PUBLIC_HOST_EXPOSURE_URL_INVALID');
  return{...artifact,kind:'official-download-exposure',exposureId:value.exposureId,githubUrl:value.githubUrl};
}

const hostKey=h=>h.kind==='official-download-exposure'?h.product+'/exposure/'+h.exposureId:h.product+'/'+h.channel+'/'+h.publicationId;
/** 完整官方发布历史与当前头必须同批取得。latest数组既不能证明旧用户已迁移，也不能证明历史完整。 */
export function normalizePublishedHostFacts(value){
  assert(value?.schema===1&&Array.isArray(value.products)&&value.products.length===2,'PUBLIC_HOST_HISTORY_REQUIRED');
  assert(new Set(value.products.map(p=>p?.product)).size===2&&value.products.every(p=>['sideload','desktop'].includes(p?.product)),'PUBLIC_HOST_HISTORY_PRODUCTS_INVALID');
  const products=value.products.map(p=>{
    assert(p.schema===1&&p.coverage==='complete','PUBLIC_HOST_HISTORY_INCOMPLETE:'+p.product);
    assert(Array.isArray(p.heads)&&p.heads.length<=2&&Array.isArray(p.publications)&&Array.isArray(p.exposures)&&p.publications.length+p.exposures.length<=256,'PUBLIC_HOST_HISTORY_LIMIT:'+p.product);
    const heads=p.heads.map(h=>normalizePublishedHost(h,p.product,h.channel));
    const publications=p.publications.map(h=>normalizePublishedHost(h,p.product,h.channel,true));
    const exposures=p.exposures.map(h=>normalizeOfficialDownloadExposure(h,p.product));
    assert(Number.isSafeInteger(p.historyRevision)&&p.historyRevision>=0&&p.publicationCount===publications.length&&p.exposureCount===exposures.length,'PUBLIC_HOST_HISTORY_COUNT_MISMATCH');
    assert(new Set(heads.map(h=>h.channel)).size===heads.length,'PUBLIC_HOST_AMBIGUOUS');
    assert(new Set(publications.map(hostKey)).size===publications.length,'PUBLIC_HOST_PUBLICATION_AMBIGUOUS');
    assert(new Set(exposures.map(hostKey)).size===exposures.length,'PUBLIC_HOST_EXPOSURE_AMBIGUOUS');
    for(const head of heads)assert(publications.some(h=>JSON.stringify(h)===JSON.stringify(head)),'PUBLIC_HOST_HEAD_HISTORY_MISMATCH');
    return{schema:1,product:p.product,coverage:'complete',historyRevision:p.historyRevision,publicationCount:p.publicationCount,exposureCount:p.exposureCount,heads,publications,exposures};
  }).sort((a,b)=>a.product.localeCompare(b.product));
  assert(products[0].historyRevision===products[1].historyRevision&&products[0].historyRevision===products.reduce((n,p)=>n+p.publicationCount+p.exposureCount,0),'PUBLIC_HOST_HISTORY_SNAPSHOT_CHANGED_RETRY');
  return{schema:1,products};
}

/** 固定官网每产品一份事务快照；有界正文/超时/拒重定向。404不是“从未公开”，历史端点必须存在。 */
export async function fetchPublishedRuntimeHosts(fetchImpl=globalThis.fetch,products=['sideload']){
  validateReleaseProducts(products);
  const snapshots=[];
  for(const product of ['sideload','desktop']){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);
    try{
      const response=await fetchImpl('https://amcl.lovedhy.cn/api/packages/runtime-host-facts?product='+product,
        {redirect:'error',signal:controller.signal,headers:{Accept:'application/json','Cache-Control':'no-cache'}});
      assert(response.ok,'PUBLIC_HOST_HTTP:'+response.status);
      let size=0;const chunks=[];
      if(!response.body)throw Error('PUBLIC_HOST_EMPTY_RESPONSE');
      for await(const chunk of response.body){size+=chunk.byteLength;assert(size<=524288,'PUBLIC_HOST_RESPONSE_TOO_LARGE');chunks.push(chunk);}
      const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
      const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
      const snapshot=JSON.parse(text);assert(snapshot?.product===product,'PUBLIC_HOST_HISTORY_PRODUCTS_INVALID');snapshots.push(snapshot);
    }finally{clearTimeout(timer);controller.abort();}
  }
  return normalizePublishedHostFacts({schema:1,products:snapshots});
}

/** 旧格式仅提升其真实单推荐/宿主语义用于门禁，不重签、不改原v1 payload或伪造协议1替代。 */
export function releaseCatalogV2(catalog,bindings=runtimeHostBindings([catalog])){
  if(catalog.schemaVersion===2){validateCatalogV2(catalog);return clone(catalog);}
  validateCatalog(catalog);
  const result=clone(catalog);result.schemaVersion=2;
  for(const build of result.builds){
    const binding=bindings.get(build.runtimeId+'/'+build.id);
    assert(binding&&binding.identity===buildIdentity(build),'BUILD_HOST_BINDING_REQUIRED:'+build.id);
    build.requiredHostProtocol=binding.protocol;
  }
  for(const runtime of result.runtimes){runtime.recommendedBuildIds=[runtime.recommendedBuildId];delete runtime.recommendedBuildId;delete runtime.loaderProtocol;}
  validateCatalogV2(result);return result;
}

/**
 * 逐原件收集宿主身份：v2给每个build明确绑定，v1只能证明其当时真正推荐的一项。
 * 不能把v1单推荐的协议套给同槽全部历史；无证据保持阻断，冲突不按新旧顺序覆盖。
 */
export function runtimeHostBindings(catalogs){
  const bindings=new Map();
  const add=(build,protocol)=>{
    const key=build.runtimeId+'/'+build.id,identity=buildIdentity(build),prior=bindings.get(key);
    assert(!prior||prior.identity===identity,'BUILD_HOST_IDENTITY_CHANGED:'+build.id);
    assert(!prior||prior.protocol===protocol,'BUILD_HOST_REQUIREMENT_CONFLICT:'+build.id);
    bindings.set(key,{identity,protocol});
  };
  for(const catalog of catalogs){
    if(catalog.schemaVersion===2){validateCatalogV2(catalog);for(const build of catalog.builds)add(build,build.requiredHostProtocol);}
    else{validateCatalog(catalog);for(const runtime of catalog.runtimes)add(catalog.builds.find(b=>b.id===runtime.recommendedBuildId),runtime.loaderProtocol);}
  }
  return bindings;
}

/** 产品集合是本次明确输入，既不填缺失desktop占位，也不从历史宿主头自动扩大本批范围。 */
export function validateReleaseProducts(products){
  assert(Array.isArray(products)&&products.length>0&&products.length<=2&&new Set(products).size===products.length&&
    products.every(product=>['sideload','desktop'].includes(product)),'RELEASE_PRODUCTS_INVALID');
  return[...products].sort();
}

/** 恢复资格与下载原件身份共用同一谓词，v2选择及实际v1回落不能各自放宽。 */
function qualifiedReturnBuild(build,stable,current){
  return build&&build.status==='available'&&build.provenance.kind==='source-build'&&build.validationLevel==='device-matrix-tested'&&
    /^[0-9a-f]{64}$/.test(build.provenance.manifestSha256)&&stable.runtimeHostProtocols.includes(build.requiredHostProtocol)&&
    current.runtimeHostProtocols.includes(build.requiredHostProtocol);
}
/** 与当前客户端supportsRuntime一致的生产范围；结构检查仍允许未来平台/目录协议候选。 */
function assertClientRuntimeAdmission(runtime,api=999){
  assert(runtime.os==='ohos'&&runtime.arch==='aarch64'&&runtime.libc==='musl'&&runtime.minimumCatalogProtocol<=2&&runtime.minimumApi<=api&&
    ((runtime.javaMajor===8&&runtime.adapter==='classic-jre-v1')||(runtime.javaMajor>=17&&runtime.adapter==='modular-jdk-v1')),
    'RUNTIME_CLIENT_ADMISSION_UNSUPPORTED:'+runtime.id);
}
const runtimeAdmission=r=>({os:r.os,arch:r.arch,libc:r.libc,adapter:r.adapter,minimumApi:r.minimumApi,minimumCatalogProtocol:r.minimumCatalogProtocol});
function returnBuildIdentity(build,slot){
  const download=build.downloads.find(d=>d.sourceId==='github'&&d.transport==='single-file');
  const url=download?new URL(download.url):null;
  assert(url&&url.origin==='https://github.com'&&url.pathname.startsWith('/LZZLHY/mc-ohos-resources/releases/download/')&&
    url.pathname.endsWith('/'+build.archive.fileName)&&!url.search&&!url.hash,'STABLE_RETURN_JDK_ORIGINAL_INVALID:'+build.id);
  return{runtimeId:slot.id,javaMajor:slot.javaMajor,buildId:build.id,fileName:build.archive.fileName,
    sha256:build.archive.sha256,sizeBytes:build.archive.sizeBytes,requiredHostProtocol:build.requiredHostProtocol,
    sourceCommit:build.provenance.sourceCommit,manifestSha256:build.provenance.manifestSha256,admission:runtimeAdmission(slot)};
}

/**
 * 新v2激活有历史返回义务时，现代端还可能网络回落到实际部署的v1。必须核该已验签v1
 * 当前单推荐的真实资格，候选batch里有安全v1不等于已部署。允许旧代次但仍合格的v1，
 * 不强求同批/同推荐；过期与固定公钥由调用者验签边界拒绝，不用未签收据代替公开入口。
 */
export function assertLegacyReturnCoverage(legacyCatalogs,closure){
  if(!closure.returns.length)return[];
  assert(Array.isArray(legacyCatalogs)&&legacyCatalogs.length===2,'STABLE_RETURN_DEPLOYED_V1_REQUIRED');
  for(const channel of ['stable','preview']){
    const catalog=legacyCatalogs.find(c=>c?.channel===channel);
    assert(catalog?.schemaVersion===1,'STABLE_RETURN_DEPLOYED_V1_REQUIRED:'+channel);validateCatalog(catalog,channel);
  }
  return closure.returns.map(graph=>{
    const catalog=legacyCatalogs.find(c=>c.channel===graph.channel);
    const stable=closure.hosts.find(h=>hostKey(h)===graph.stableHost);
    const current=closure.hosts.find(h=>hostKey(h)===graph.fromHost);
    assert(stable&&current,'STABLE_RETURN_HOST_FACTS_REQUIRED');
    const replacements=graph.replacements.map(slot=>{
      const runtime=catalog.runtimes.find(r=>r.id===slot.runtimeId&&r.javaMajor===slot.javaMajor);
      assert(runtime&&slot.admission,'STABLE_RETURN_RUNTIME_ADMISSION_REQUIRED:'+slot.runtimeId);
      assertClientRuntimeAdmission(runtime,slot.admission.minimumApi);
      assert(runtime.os===slot.admission.os&&runtime.arch===slot.admission.arch&&runtime.libc===slot.admission.libc&&
        runtime.adapter===slot.admission.adapter,'STABLE_RETURN_RUNTIME_PLATFORM_CHANGED:'+slot.runtimeId);
      const selected=runtime&&catalog.builds.find(b=>b.id===runtime.recommendedBuildId&&b.runtimeId===runtime.id);
      const build=selected&&{...selected,requiredHostProtocol:runtime.loaderProtocol};
      assert(qualifiedReturnBuild(build,stable,current),'STABLE_RETURN_DEPLOYED_V1_NOT_QUALIFIED:'+graph.product+'/'+graph.channel+'/'+slot.javaMajor);
      return returnBuildIdentity(build,runtime);
    });
    return{product:graph.product,channel:graph.channel,catalogRevision:catalog.catalogRevision,replacements};
  });
}

/**
 * 派生发布闭包：正向推荐绑定真实公开App，未来宿主未发布时明确waiting-host；公开预览可装载的历史宿主要求仍高于
 * stable时，必须持续具备可认领恢复的稳定HAP及逐major精确合格替代。推荐移除和撤回
 * 不会卸载用户已有槽位，不能消除返回义务；仅登记而无公开预览支持的未来协议不触发。
 * App订阅和JDK选择通道独立，因此两份JDK通道都承担这一义务。替代来自各自当前推荐，
 * 同时被去/返两端宿主支持，拒绝legacy资格例外和已撤回内容。没有新能力差异的普通维护
 * 不强迫旧stable升级恢复协议。返回值仅是可重算索引，不接受“可回退”自报结论。
 */
export function derivePublishedReleaseClosure(inputCatalogs,inputHosts,targetProducts=['sideload'],historicalCatalogs=[],bindingCatalogs=[]){
  assert(Array.isArray(inputCatalogs)&&inputCatalogs.length===2,'RELEASE_CATALOG_PAIR_REQUIRED');
  const bindings=runtimeHostBindings([...inputCatalogs,...historicalCatalogs,...bindingCatalogs]);
  const catalogs=inputCatalogs.map(c=>releaseCatalogV2(c,bindings)).sort((a,b)=>a.channel.localeCompare(b.channel));
  assert(catalogs[0].channel==='preview'&&catalogs[1].channel==='stable'&&
    catalogs[0].catalogRevision===catalogs[1].catalogRevision&&catalogs[0].issuedAt===catalogs[1].issuedAt&&
    catalogs[0].expiresAt===catalogs[1].expiresAt,'RELEASE_CATALOG_SOURCE_MISMATCH');
  assert(Array.isArray(historicalCatalogs)&&[0,2].includes(historicalCatalogs.length),'RELEASE_HISTORY_PAIR_REQUIRED');
  const historyCatalogs=historicalCatalogs.map(c=>releaseCatalogV2(c,bindings)).sort((a,b)=>a.channel.localeCompare(b.channel));
  if(historyCatalogs.length)assert(historyCatalogs[0].channel==='preview'&&historyCatalogs[1].channel==='stable'&&
    historyCatalogs[0].catalogRevision===historyCatalogs[1].catalogRevision&&historyCatalogs[0].issuedAt===historyCatalogs[1].issuedAt&&
    historyCatalogs[0].expiresAt===historyCatalogs[1].expiresAt,'RELEASE_HISTORY_SOURCE_MISMATCH');
  for(const catalog of catalogs)for(const runtime of catalog.runtimes){
    assertClientRuntimeAdmission(runtime);
    for(const prior of historyCatalogs.flatMap(c=>c.runtimes).filter(r=>r.id===runtime.id)){
      assert(runtimeIdentity(prior)===runtimeIdentity(runtime),'runtime identity changed across catalog namespaces');
      // v1兼容投影的目录协议可保持1；跨格式只约束真实平台API范围，已支持目录上限由上门拒未知3。
      validateRuntimeAdmission(prior,runtime,false);
    }
  }
  const hostFacts=normalizePublishedHostFacts(inputHosts),facts=hostFacts.products.flatMap(p=>p.heads),publications=hostFacts.products.flatMap(p=>p.publications),exposures=hostFacts.products.flatMap(p=>p.exposures);
  const products=validateReleaseProducts(targetProducts);
  const used=new Map(),forward=[],returns=[];
  // 历史身份是两份目录的并集。v2源通常共享此列表；旧v1各通道的宿主语义提升后仍要
  // 保留其已交付可能性，不能因用户只切JDK通道而把另一个通道装入的槽位视为不存在。
  // 伴随旧目录只补已交付身份；当前候选的withdrawn等状态优先，不能被旧available覆盖成假复活。
  const history=[...new Map([...historyCatalogs,...catalogs].flatMap(c=>c.builds).map(b=>[b.runtimeId+'/'+b.id+'/'+b.requiredHostProtocol,b])).values()];
  const use=h=>{used.set(hostKey(h),h);return hostKey(h);};
  for(const product of products){
    const stable=facts.find(h=>h.product===product&&h.channel==='stable');
    assert(stable,'PUBLIC_STABLE_BASELINE_REQUIRED:'+product);
    for(const catalog of catalogs){
      for(const runtime of catalog.runtimes)for(const id of runtime.recommendedBuildIds){
        const build=catalog.builds.find(b=>b.id===id),required=build.requiredHostProtocol;
        const eligible=facts.filter(h=>h.product===product&&(catalog.channel==='preview'||h.channel==='stable')&&h.runtimeHostProtocols.includes(required));
        const current=eligible.find(h=>h.channel==='stable')??eligible.find(h=>h.channel==='preview');
        // 未来宿主尚未公开时，真实协议让旧端拒绝下载；这是等待宿主，不伪造已公开App。
        // 已有公开群体的返回义务仍在下方完整派生，不能借waiting-host绕过reader或安全替代。
        assert(current||required>1,'PUBLIC_HOST_NOT_READY:'+product+'/'+catalog.channel+'/'+id+':'+required);
        forward.push({product,channel:catalog.channel,runtimeId:runtime.id,javaMajor:runtime.javaMajor,buildId:id,
          sha256:build.archive.sha256,sizeBytes:build.archive.sizeBytes,requiredHostProtocol:required,
          state:current?'ready':'waiting-host',host:current?use(current):null});
      }
    }
  }
  // 显式products只界定本次正向准入，不授权忽略已存在的其它产品消费者。共享签名目录
  // 没有product查询参数；公开desktop预览若能用历史2，也必须单独具备其正式版返回图。
  // 同一HAP先曝光后切头只代表一个已装cohort，优先保留真实publication定位，不伪造曝光的通道。
  const cohorts=[...new Map([...exposures,...publications].map(h=>[h.product+'/'+h.sha256,h])).values()];
  // 已公开新App的稳定供给不能在后续JDK发布中被抽走，即使ABI编号没有变化。
  const stableCatalog=catalogs.find(c=>c.channel==='stable');
  for(const host of [...facts,...cohorts])assertAppRuntimeCoverage([stableCatalog,projectLegacyCatalogFromV2(stableCatalog)],host);
  for(const current of cohorts){
    const product=current.product,stable=facts.find(h=>h.product===product&&h.channel==='stable');
    const cohort=history.filter(b=>current.runtimeHostProtocols.includes(b.requiredHostProtocol));
    if(!cohort.length)continue;
    assert(stable,'PUBLIC_STABLE_BASELINE_REQUIRED:'+product);
    const cohortMinimumApi=Math.max(current.minApi,Math.min(...cohort.map(b=>Math.min(...[...catalogs,...historyCatalogs].flatMap(c=>c.runtimes).filter(r=>r.id===b.runtimeId).map(r=>r.minimumApi)))));
    // 头换成更高API/更窄设备也不会卸载旧用户；stable须覆盖原HAP与可安装JDK交集范围。
    assert(stable.versionCode>=current.versionCode&&stable.minApi<=cohortMinimumApi&&stable.abi===current.abi&&
      current.deviceTypes.every(d=>stable.deviceTypes.includes(d)),'STABLE_RETURN_HAP_INCOMPATIBLE:'+product);
    assert(stable.runtimePlanProtocol>=current.runtimePlanProtocol,'STABLE_RETURN_READER_NOT_COVERED:'+product);
    const retained=cohort.filter(b=>!stable.runtimeHostProtocols.includes(b.requiredHostProtocol));
    if(!retained.length)continue;
    for(const catalog of catalogs){
      // 不声称stable曾推荐过2：用户可先装preview的2，再只切JDK通道stable，槽位仍为2。
      // 两通道需独立提供恢复替代；未公开支持的未来协议3仍只是候选，不扩大正向发布范围。
        const dropped=[...new Set(retained.map(b=>b.requiredHostProtocol))].sort((a,b)=>a-b);
        // 恢复reader2覆盖1MiB/compact身份、schema2续作intent及耐久completion。旧plan1
        // 仍是合法历史事实，不能据此假定旧reader能消费本轮新的跨应用JDK交接格式。
        assert(current.runtimePlanProtocol===2&&stable.runtimePlanProtocol===2,'STABLE_RETURN_PLAN_REQUIRED:'+product);
        const replacements=[];
        for(const slot of catalog.runtimes){
          const historyApi=Math.min(...[...catalogs,...historyCatalogs].flatMap(c=>c.runtimes).filter(r=>r.id===slot.id).map(r=>r.minimumApi));
          assertClientRuntimeAdmission(slot,historyApi);
          const candidates=slot.recommendedBuildIds.map(id=>catalog.builds.find(b=>b.id===id));
          const qualified=b=>qualifiedReturnBuild(b,stable,current);
          assert(candidates.some(qualified),'STABLE_RETURN_JDK_NOT_QUALIFIED:'+product+'/'+catalog.channel+'/'+slot.javaMajor);
          // 新批次的v1投影实际只选择第一个协议1推荐。不能在v2尾部追加安全包却让现代端
          // 网络回落到v1后只看到legacy；保留推荐顺序语义，缺资格就阻断，不伪造矩阵标记。
          const replacement=candidates.find(b=>b.requiredHostProtocol===1);
          assert(qualified(replacement),'STABLE_RETURN_V1_NOT_QUALIFIED:'+product+'/'+catalog.channel+'/'+slot.javaMajor);
          replacements.push(returnBuildIdentity(replacement,slot));
        }
        returns.push({product,channel:catalog.channel,fromHost:use(current),stableHost:use(stable),cohortMinimumApi,droppedHostProtocols:dropped,
          retainedBuilds:retained.map(b=>({runtimeId:b.runtimeId,buildId:b.id,requiredHostProtocol:b.requiredHostProtocol,
            status:b.status,sha256:b.archive.sha256,sizeBytes:b.archive.sizeBytes})),replacements});
    }
  }
  const result={schemaVersion:1,products,hostFacts,returnProducts:[...new Set(returns.map(r=>r.product))].sort(),historyCatalogs:historicalCatalogs.map(c=>({schemaVersion:c.schemaVersion,channel:c.channel,catalogRevision:c.catalogRevision,issuedAt:c.issuedAt,expiresAt:c.expiresAt})),catalogs:catalogs.map(c=>({schemaVersion:2,channel:c.channel,catalogRevision:c.catalogRevision,
    issuedAt:c.issuedAt,expiresAt:c.expiresAt})),hosts:[...used.values()].sort((a,b)=>hostKey(a).localeCompare(hostKey(b))),forward,returns};
  assert(new TextEncoder().encode(JSON.stringify(result)).byteLength<=262144,'RELEASE_CLOSURE_TOO_LARGE');
  return result;
}
