import assert from 'node:assert/strict';
import fs from 'node:fs';
import { runtime } from './desktop-render-test-runtime.mjs';
import { evaluateDesktopDiagnosticArtifact } from './check-desktop-render-diagnostics.mjs';

const desktopMap={module:{sources:['entry/src/desktop/ProductRenderDiagnostics.ets']}};
const mobileMap={module:{sources:['entry/src/main/ProductRenderDiagnostics.ets']}};
const marker=Buffer.from('AMCL_DESKTOP_RENDER_DIAGNOSTIC_V1');
assert.equal(evaluateDesktopDiagnosticArtifact('desktop',desktopMap,marker).issues.length,0);
assert.equal(evaluateDesktopDiagnosticArtifact('default',mobileMap,Buffer.from('no-op')).issues.length,0);
assert(evaluateDesktopDiagnosticArtifact('default',desktopMap,marker).issues.length);
assert(evaluateDesktopDiagnosticArtifact('desktop',desktopMap,Buffer.from('no-op')).issues.length);
assert(evaluateDesktopDiagnosticArtifact('desktop',mobileMap,marker).issues.length);
assert(evaluateDesktopDiagnosticArtifact('default',mobileMap,marker).issues.length);
assert(evaluateDesktopDiagnosticArtifact('desktopLegacy',mobileMap,Buffer.from('no-op')).issues.length);

// 实际 sideload Release source map 证明未使用的 no-op 模块可被删除。保留目标
// 产品元数据作为独立证据，并验证错产品、桌面标记、重复 provider 仍无法通过。
for(const product of ['sideload','store']){
  const pruned={profile:{sources:['entry/src/'+product+'/ProductBuildProfile.ets']}};
  assert.equal(evaluateDesktopDiagnosticArtifact(product,pruned,Buffer.from('no-op')).issues.length,0);
  assert(evaluateDesktopDiagnosticArtifact(product,pruned,marker).issues.length);
  assert(evaluateDesktopDiagnosticArtifact('desktop',pruned,marker).issues.length);
  assert(evaluateDesktopDiagnosticArtifact(product,{},Buffer.from('no-op')).issues.length);
  assert(evaluateDesktopDiagnosticArtifact(product,{profile:{sources:['entry/src/main/ProductBuildProfile.ets']}},Buffer.from('no-op')).issues.length);
  assert(evaluateDesktopDiagnosticArtifact(product,{...pruned,...desktopMap},Buffer.from('no-op')).issues.length);
  assert(evaluateDesktopDiagnosticArtifact(product,{...pruned,a:mobileMap.module,b:mobileMap.module},Buffer.from('no-op')).issues.length);
}

for(const product of ['desktop']){
  const r=runtime(product),{Provider:p,state:s}=r;
  try{
    assert(p.enabled);
    assert.equal(p.read(s.filesDir),undefined);
    p.save(s.filesDir,'BASIC_PROBE',false);assert(!p.read(s.filesDir).detailed);
    const full='PROBE_HEAD\n'+('render detail '+'GL pixel samples OK '.repeat(8)+'\n').repeat(1800)+'PROBE_MIDDLE\n'
      +('detail '+'shader texture buffer '.repeat(7)+'\n').repeat(1800)+'PROBE_TAIL';
    p.save(s.filesDir,full,true);const saved=p.read(s.filesDir);
    assert(saved.detailed&&saved.text.endsWith(full));assert(saved.text.includes('product='+product));
    p.save(s.filesDir,'NEW_BASIC',false);assert.equal(p.read(s.filesDir).id,saved.id,'basic probes retain the full result');
    for(const fault of ['writeFails','shortWrite','fsyncFails']){
      s[fault]=true;assert.throws(()=>p.save(s.filesDir,'REPLACEMENT',true));s[fault]=false;
      assert.equal(p.read(s.filesDir).id,saved.id,'failed atomic save keeps the prior file');
      assert(fs.readdirSync(s.filesDir+'/logs/desktop-render/'+product).every(n=>!n.endsWith('.tmp')));
    }
    assert.throws(()=>p.save(s.filesDir,'x'.repeat(1024*1024+1),true));
    const largeGame='GAME_HEAD\n'+'game vertex texture upload geometry frame\n'.repeat(80000)+'GAME_TAIL';
    assert(Buffer.byteLength(r.logExport.sanitizeLogForExport(largeGame,r.logExport.LogExportTarget.LOGSHARE,Number.MAX_SAFE_INTEGER))>2*1024*1024);
    const joined=p.appendForShare(largeGame,saved);
    assert(Buffer.byteLength(joined)<=10*1024*1024);
    for(const mark of ['GAME_HEAD','GAME_TAIL','PROBE_HEAD','PROBE_MIDDLE','PROBE_TAIL'])assert(joined.includes(mark));
    assert(joined.endsWith(r.logExport.sanitizeLogForExport(saved.text,r.logExport.LogExportTarget.LOGSHARE,Number.MAX_SAFE_INTEGER)));
    assert.equal(r.logExport.sanitizeLogForExport(joined,r.logExport.LogExportTarget.LOGSHARE),joined);
    const game=r.seed();
    const a=r.activity(game.id);await a.prepare_(false);assert(a.snapshot,a.errorText);
    assert.equal(s.posts.length,0,'first action only freezes a preview');
    assert(!a.snapshot.files.some(file=>file.role.startsWith('renderer')),'independent probes are not implicitly attached to a game');
    await a.send_(false);assert(a.shared,a.errorText);
    assert.equal(a.shared.desktopDiagnosticId,undefined);
    assert(!r.control.files.some(file=>file.content.includes('PROBE_MIDDLE')));
    const first=s.posts.length;await a.copy_();assert.equal(s.posts.length,first);
    const b=r.sheet(game.id,game.mc);assert(await b.lsSubmit_());assert.equal(s.posts.length,first,'same snapshot reuses an existing session share');
    p.save(s.filesDir,'SECOND_PROBE_HEAD\nSECOND_PROBE_TAIL',true);
    assert(await b.lsSubmit_());assert.equal(s.posts.length,first,'AI reuses an explicit share and never uploads a new probe');
    a.advanced_();await a.prepare_(false);await a.send_(false);assert(a.shared,a.errorText);
    assert.equal(s.posts.length,first,'unchanged selected files reuse their digest after preview');
    const c=r.page();s.newProbeText='PAGE_COMPLETE_HEAD\nPAGE_COMPLETE_TAIL';await c.verify(true);
    assert(c.saveError==='');assert(p.read(s.filesDir).text.includes('PAGE_COMPLETE_TAIL'));
    const fresh=r.page();fresh.restoreSaved(true);assert(fresh.result.includes('PAGE_COMPLETE_TAIL'));
    await fresh.shareResult();assert.equal(s.posts.length,first,'diagnostic action opens the shared preview page without network');
    const route=s.routes.at(-1);assert.equal(route.url,'pages/ActivityLogPage');assert.equal(route.params.showShare,true);
    const diagnostic=r.activity(route.params.activityId);
    await diagnostic.prepare_(false);assert(diagnostic.snapshot,diagnostic.errorText);
    assert(diagnostic.snapshot.files.some(file=>file.role==='renderer-probe'));
    r.control.id=r.control.urlId='sDiag001';
    s.prefsFail=true;await diagnostic.send_(false);assert.equal(diagnostic.shared,undefined);assert(diagnostic.errorText);
    const pendingPosts=s.posts.length;assert.equal(pendingPosts,first+1);
    s.prefsFail=false;await diagnostic.retrySave_();assert(diagnostic.shared,diagnostic.errorText);
    assert.equal(s.posts.length,pendingPosts,'credential persistence retry must not upload again');
    assert(r.control.files.some(file=>file.content.includes('PAGE_COMPLETE_TAIL')));
    await diagnostic.copy_();assert.equal(s.clipboard,diagnostic.shared.url);
    s.clipboardFails=true;await fresh.copyShareUrl(diagnostic.shared.url);assert(fresh.shareStatus.includes('复制失败'));
    s.clipboardFails=false;assert((await r.client.revokeShare(r.context,diagnostic.shared)).ok);
    assert(!(await r.client.loadShareRecords(r.context)).some(record=>record.id===diagnostic.shared.id));
    s.probeFails=true;await c.verify(true);assert(p.read(s.filesDir).text.includes('PROBE_EXCEPTION_SENTINEL'));
    assert(c.verdict.includes('ERROR'));
    fs.writeFileSync(s.filesDir+'/logs/desktop-render/'+product+'/render.json','{"schema":99}');
    assert(!p.read(s.filesDir).detailed,'invalid full record cannot pretend to be a valid full result');
    console.log('PASS '+product+': atomic persistence, faults, explicit preview/selection, scoped game shares, digest reuse, credential retry, diagnostic share/revoke');
  }finally{r.cleanup();}
}
for(const product of ['default','store','sideload','desktopLegacy']){
  for(const misplaced of [false,true]){
    const r=runtime(product,misplaced),{Provider:p,state:s}=r;
    try{
      assert(!p.enabled);p.save(s.filesDir,'DO_NOT_PERSIST',true);assert.equal(p.read(s.filesDir),undefined);
      assert.equal(p.appendForShare('ordinary log',{id:'old-desktop',text:'PRIVATE_DESKTOP_REPORT',detailed:true,capturedAt:1}),'ordinary log');
      const page=r.page();await page.verify(true);await page.shareResult();assert.equal(s.probeCalls,0);assert.equal(s.posts.length,0);
      assert.equal(s.reads,0);assert.equal(s.writes,0);
      const game=r.seed();
      assert.equal(await r.sheet(game.id,game.mc).lsSubmit_(),false);
      assert.equal(s.posts.length,0,'AI without an explicit share only opens the composer');
      assert.equal(s.routes.at(-1).url,'pages/ActivityLogPage');
      const activity=r.activity(game.id);await activity.prepare_(false);assert(activity.snapshot,activity.errorText);
      assert.equal(s.posts.length,0);await activity.send_(false);assert(activity.shared,activity.errorText);
      const body=r.control.files.map(file=>file.content).join('\n');
      assert(body.includes('GAME_END'),'non-desktop LogShare payload keeps the game tail');
      assert(body.includes('SCOPED_RENDER_FAILURE EGL_BAD_SURFACE=0x300d'),'non-desktop LogShare payload keeps the middle render failure');
      assert(Buffer.byteLength(body)<=10*1024*1024,'non-desktop LogShare payload stays within service limit');
      assert(!body.includes('AMCL_DESKTOP_RENDER_DIAGNOSTIC'));
      assert.equal(s.reads,0);assert.equal(s.writes,0);
      console.log('PASS '+product+(misplaced?' misplaced provider':'')+': no probe, no diagnostic IO, unchanged ordinary sharing');
    }finally{r.cleanup();}
  }
}
