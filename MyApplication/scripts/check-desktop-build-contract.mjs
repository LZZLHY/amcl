// Desktop UI product provenance. Graphics providers use the shared artifact contract.
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { PRODUCT_ROOT, parseJson5 } from './product-contract.mjs';
import { auditDiagnosticBuild } from './check-diagnostics-contract.mjs';
import { evaluateNativeBuild } from './check-desktop-runtime.mjs';
import { toolchainLockIssues, runVersionCommand, sanitizedProfileProjection } from './check-mg-build-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const hashFile = file => hash(readFileSync(file));
// 日常开发工作树允许有未提交/未跟踪输入，完整Git清单可超过Node默认的1MiB缓冲。
// 与通用MG证据检查器保持32MiB有界读取；超限仍失败，不能截断清单或漏算构建身份。
const GIT_OUTPUT_LIMIT = 32 * 1024 * 1024;
export function auditDesktopBuild({ product='desktop', mode='release', hap, hapKind='signed', hvigor, requireClean=false, verifyPersisted=false }) {
  if (product !== 'desktop') throw new Error('System-only provenance is desktop-only');
  const root = PRODUCT_ROOT;
  const status = execFileSync('git',['status','--porcelain=v1','--untracked-files=all'],{cwd:root,encoding:'utf8',maxBuffer:GIT_OUTPUT_LIMIT});
  if (requireClean && status.trim()) throw new Error('Release requires a clean immutable checkout');
  const base = auditDiagnosticBuild({product,mode,hap,hapKind,verifySignature:true});
  if (requireClean && (mode !== 'release' || base.nativeGlValidation)) throw new Error('Release cannot contain validation/debug variants');
  const build = join(root,`entry/.cxx/desktop/desktop/${mode}/arm64-v8a`);
  const cacheText=readFileSync(join(build,'CMakeCache.txt'),'utf8');
  const cache = Object.fromEntries([...cacheText.matchAll(/^([^#/:=\n]+):[^=\n]+=(.*)$/gm)].map(m=>[m[1],m[2].trim()]));
  const rows=JSON.parse(readFileSync(join(build,'compile_commands.json'),'utf8'));
  const issues=evaluateNativeBuild(cacheText,rows,base.nativeGlValidation,true);
  const row=rows.find(r=>/[/\\]glfw_egl\.cpp$/.test(r.file));
  if(!row) throw new Error('Unified EGL compile input missing');
  const compilerMatch=row.command.match(/^(?:"([^"]+)"|(\S+))/);
  const compiler=compilerMatch?.[1] ?? compilerMatch?.[2];
  const version=(file,args)=>execFileSync(file,args,{cwd:root,encoding:'utf8'}).trim().split(/\r?\n/)[0];
  const module=JSON.parse(readUniqueZipEntry(readFileSync(hap),'module.json'));
  const profile=parseJson5(readFileSync(join(root,'build-profile.json5'),'utf8'));
  const template=parseJson5(readFileSync(join(root,'build-profile.json5.template'),'utf8'));
  const projection=sanitizedProfileProjection(profile,product,product);
  if(JSON.stringify(projection)!==JSON.stringify(sanitizedProfileProjection(template,product,product))) issues.push('Build profile differs from tracked product template');
  const selected=profile.app.products.find(p=>p.name===product);
  const signing=profile.app.signingConfigs.find(s=>s.name===selected.signingConfig);
  if(!signing || !['certpath','profile','storeFile'].every(k=>existsSync(signing.material[k]))) issues.push('Signing configuration references missing files');
  const actual={schemaVersion:1,platform:`${process.platform}-${process.arch}`,
    compileSdkVersion:module.app.compileSdkVersion,targetAPIVersion:module.app.targetAPIVersion,minAPIVersion:module.app.minAPIVersion,
    nativeCompiler:selected.buildOption?.nativeCompiler,signingAlgorithm:signing?.material?.signAlg,
    compiler:{versionFirstLine:version(compiler,['--version']),sha256:hashFile(compiler)},
    cmake:{versionFirstLine:version(cache.CMAKE_COMMAND,['--version']),sha256:hashFile(cache.CMAKE_COMMAND)},
    hvigor:{version:String(runVersionCommand(resolve(hvigor),['--version','--no-daemon'],root)).trim(),launcherSha256:hashFile(hvigor)},
    toolchainFile:{sha256:hashFile(cache.CMAKE_TOOLCHAIN_FILE)},hapSignTool:{sha256:base.signature.verifierSha256}};
  issues.push(...toolchainLockIssues(JSON.parse(readFileSync(join(root,'toolchain.lock'),'utf8')),actual,product));
  // Include untracked implementation inputs; a HEAD+dirty bit cannot identify a build.
  const names=execFileSync('git',['ls-files','-z','--cached','--others','--exclude-standard'],{cwd:root,encoding:'utf8',maxBuffer:GIT_OUTPUT_LIMIT}).split('\0')
    .filter(p=>p && !/^(docs|diagnostics|artifacts|prebuilt)\//.test(p) && /(?:\.(?:cpp|c|h|ets|java|ts|mjs|ps1|json5|json|lock|txt)|CMakeLists.txt)$/.test(p)).sort();
  const inputs=names.filter(p=>existsSync(join(root,p))).map(p=>[p,hashFile(join(root,p))]);
  if (!verifyPersisted) {
    const hapTime=statSync(hap).mtimeMs;
    const newer=inputs.filter(([p])=>!/(?:^|\/)(?:test|tests)\/|\/test-[^/]+$/.test(p) &&
      statSync(join(root,p)).mtimeMs > hapTime+1000).map(([p])=>p);
    if(newer.length) issues.push('Implementation inputs changed after this HAP was built: '+newer.slice(0,8).join(', '));
  }
  if(issues.length) throw new Error(issues.join('\n'));
  return {...base,purpose:'desktop-system-gl-build',releasable:requireClean && mode==='release',
    sourceInputsSha256:hash(JSON.stringify(inputs)),compileDatabaseSha256:hashFile(join(build,'compile_commands.json')),
    buildGraphSha256:hashFile(join(build,'build.ninja')),toolchain:actual,profile:projection};
}

if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const arg=(name,fallback)=>{const i=process.argv.indexOf(`--${name}`);return i<0?fallback:process.argv[i+1];};
  try {
    const result=auditDesktopBuild({product:arg('product','desktop'),mode:arg('mode','release'),hap:arg('hap'),
      hapKind:arg('hap-kind','signed'),hvigor:arg('hvigor'),requireClean:process.argv.includes('--require-clean'),verifyPersisted:!!arg('verify-provenance')});
    if(arg('verify-provenance') && JSON.stringify(JSON.parse(readFileSync(arg('verify-provenance'))))!==JSON.stringify(result)) throw new Error('Persisted desktop provenance differs');
    if(arg('write-provenance')) writeFileSync(arg('write-provenance'),JSON.stringify(result,null,2)+'\n');
    console.log(`[desktop-build-contract] PASS ${result.product}/${result.mode}; toolchain/signature/source/HAP verified`);
  } catch(error) {console.error(`[desktop-build-contract] FAIL ${error.message}`);process.exitCode=1;}
}
