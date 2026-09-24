import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

export function evaluateDesktopDiagnosticArtifact(product, maps, abc) {
  const enabled=product==='desktop';
  const expected='entry/src/'+(enabled?'desktop':'main')+'/ProductRenderDiagnostics.ets';
  const providers=Object.entries(maps).filter(([, value])=>(value.sources??[]).some(s=>s.endsWith('/ProductRenderDiagnostics.ets')));
  const marker=Buffer.from('AMCL_DESKTOP_RENDER_DIAGNOSTIC_V1');
  const issues=[];
  if(!['desktop','default','store','sideload'].includes(product))issues.push('Unknown or retired product');
  // 生产 sideload/store 裁掉开发页面后，编译器会删除没有实际引用的空诊断模块。
  // 缺少这个 no-op 的 source map 并不代表桌面实现混入。只有同一份实际映射中
  // 唯一产品元数据来自目标生产源集、且诊断 provider 完全缺席时才接受该形态；
  // 桌面真实现、错误/重复源集和空映射仍拒绝，下面的 ABC 标记检查也继续独立执行。
  const profiles=Object.values(maps).filter(value=>(value.sources??[]).some(s=>s.endsWith('/ProductBuildProfile.ets')));
  const prunedProductionStub=['sideload','store'].includes(product)&&providers.length===0
    &&profiles.length===1&&profiles[0].sources.includes('entry/src/'+product+'/ProductBuildProfile.ets');
  if(!prunedProductionStub&&(providers.length!==1||!providers[0][1].sources.includes(expected)))issues.push('Wrong product diagnostic source set');
  if(Buffer.from(abc).includes(marker)!==enabled)issues.push('Desktop-only diagnostic implementation differs from product policy');
  return {product,enabled,providerSources:providers.flatMap(([,v])=>v.sources),markerPresent:Buffer.from(abc).includes(marker),issues};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const arg=name=>{const i=process.argv.indexOf('--'+name);return i<0?'':process.argv[i+1];};
  try{
    const hap=arg('hap'),product=arg('product'),sourceMap=arg('source-map');
    if(!hap||!sourceMap||!['desktop','default','store','sideload'].includes(product))throw new Error('--hap, --source-map and valid --product are required');
    const bytes=fs.readFileSync(hap);
    const result=evaluateDesktopDiagnosticArtifact(product,JSON.parse(fs.readFileSync(sourceMap,'utf8')),readUniqueZipEntry(bytes,'ets/modules.abc'));
    if(result.issues.length)throw new Error(result.issues.join('; '));
    const report={...result,hap:path.resolve(hap),sha256:createHash('sha256').update(bytes).digest('hex')};
    if(arg('report'))fs.writeFileSync(arg('report'),JSON.stringify(report,null,2)+'\n');
    console.log('[desktop-render-artifact] PASS '+product+': '+(result.enabled?'desktop implementation included':'no desktop diagnostic implementation'));
  }catch(error){console.error('[desktop-render-artifact] FAIL '+error.message);process.exitCode=1;}
}
