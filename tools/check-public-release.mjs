#!/usr/bin/env node
/** 公开候选先核源码；最终发行另核真实feed，避免为了让CI通过而提前推送更新。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { parseJson5 } from '../MyApplication/scripts/product-contract.mjs';
import { validateUpdateFeeds, validatePublishedSourceVersion } from './validate-update-feeds.mjs';

/** 两阶段共用实际源码、gitlink和许可检查；候选模式不授予HAP编译、装机或更新推送资格。 */
export function checkPublicRelease(root,{sourceOnly=false}={}) {
  const read=relative=>fs.readFileSync(path.join(root,relative),'utf8').replace(/\r\n/g,'\n');
  const json=relative=>JSON.parse(read(relative));
  const app=parseJson5(read('MyApplication/AppScope/app.json5')).app;
  const snapshot=json('MyApplication/SOURCE_SNAPSHOT.json');
  assert.equal(snapshot.sourceDirty,false,'a published snapshot must identify a clean source commit');
  assert.match(snapshot.sourceCommit,/^[a-f0-9]{40}$/);
  const displayed=read('MyApplication/commons/src/main/ets/common/Constants.ets').match(/APP_VERSION\s*=\s*'([^']+)'/);
  assert.equal(displayed?.[1],app.versionName);
  const bundled=json('MyApplication/entry/src/main/resources/rawfile/changelog.json');
  const matches=value=>value?.versionName===app.versionName&&value?.versionCode===app.versionCode&&value?.tag==='v'+app.versionName;
  assert(matches(bundled.latest)&&bundled.releases?.some(matches),'bundled changelog is not bound to the source release');
  if(!sourceOnly) {
    const update=json('update.json');
    assert.equal(update.url,`https://github.com/LZZLHY/amcl/releases/tag/${update.tag}`);
    validatePublishedSourceVersion(app,bundled,json('changelog.json'),validateUpdateFeeds(root));
    assert(Buffer.byteLength(read('update.json'))<8192,'older clients need a bounded update manifest');
  }
  for(const dependency of snapshot.dependencyWorktrees) {
    const output=execFileSync('git',['-C',root,'ls-files','--stage','--',`MyApplication/${dependency.path}`],{encoding:'utf8'});
    assert.equal(output.match(/^160000 ([a-f0-9]{40}) /)?.[1],dependency.baseCommit,dependency.path);
  }
  assert.equal(read('LICENSE'),read('MyApplication/LICENSE'));
  const notices=json('MyApplication/third-party-notices/manifest.json');
  for(const notice of notices.files) {
    const filename=path.resolve(root,'MyApplication/third-party-notices',notice.file);
    assert(filename.startsWith(path.join(root,'MyApplication/third-party-notices')+path.sep));
    const bytes=fs.readFileSync(filename,'utf8').replace(/\r\n/g,'\n');
    assert.equal(createHash('sha256').update(bytes).digest('hex'),notice.sha256,notice.file);
  }
  return {mode:sourceOnly?'source-candidate':'published-release',versionName:app.versionName,versionCode:app.versionCode,
    sourceCommit:snapshot.sourceCommit,noticeCopies:notices.files.length,hapBuildVerified:false};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const args=process.argv.slice(2);
    assert(args.length===0||(args.length===1&&args[0]==='--source-only'),'Usage: check-public-release.mjs [--source-only]');
    const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
    console.log(JSON.stringify({ok:true,...checkPublicRelease(root,{sourceOnly:args.length===1})}));
  } catch(error) {console.error(error.message);process.exitCode=1;}
}
