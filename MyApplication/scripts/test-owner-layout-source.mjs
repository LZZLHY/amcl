/** 真实source仓库的原文/范围/冷启/净修改/回滚回归，只替换SDK文件与Preferences边界。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

let groups=0;
function passed(name){groups++;console.log('PASS '+name);}
function fixture(){
  const disk=evidenceRuntime(),cache=new Map(),durable=new Map(),control={failFlush:0,flushes:[]};
  disk.kitFs.lstatSync=p=>{const s=fs.lstatSync(p);return{size:s.size,isFile:()=>s.isFile(),isDirectory:()=>s.isDirectory()};};
  const pref={getSync:(k,f)=>cache.get(k)??f,get:async(k,f)=>cache.get(k)??f,
    putSync:(k,v)=>cache.set(k,v),put:async(k,v)=>cache.set(k,v),
    flush:async()=>{control.flushes.push(new Map(cache));if(control.failFlush>0){control.failFlush--;throw Error('disk flush failure');}
      durable.clear();for(const[k,v]of cache)durable.set(k,v);}};
  const {OwnerLayoutSourceRepository}=disk.load('commons/src/main/ets/utils/OwnerLayoutSourceRepository.ets');
  return {disk,pref,cache,durable,control,Repo:OwnerLayoutSourceRepository,cold(){cache.clear();for(const[k,v]of durable)cache.set(k,v);
    return OwnerLayoutSourceRepository.open(disk.context,pref);}};
}
function input(profile,index){return{profileId:'p_'+index,profileRevision:1,name:profile.name,isPreset:false,targetDevice:'any',sourceIndex:index,raw:JSON.stringify(profile)};}

{
  const f=fixture();try{
    const profiles=[{name:'一,]"\\',controls:[],nested:{a:[{b:'[]'}]}},{name:'二😀',controls:[]}];
    const raw=' [ '+JSON.stringify(profiles[0])+' , \n '+JSON.stringify(profiles[1])+' ] ';
    f.cache.set('profiles',raw);f.cache.set('active_profile',profiles[1].name);
    const repo=await f.Repo.openOrMigrate(f.disk.context,f.pref,raw,profiles[1].name,profiles.map(input));
    assert.equal(f.cache.get('profiles'),raw,'源XML原文不改写');assert.equal(repo.activeProfileId(),'p_1');
    assert.deepEqual(JSON.parse(repo.readProfileRaw('p_0')),profiles[0]);assert.deepEqual(JSON.parse(repo.readProfileRaw('p_1')),profiles[1]);
    const catalog=repo.getCatalog();catalog[0].name='poison';assert.notEqual(repo.getCatalog()[0].name,'poison');
    const cold=f.cold();assert.equal(cold.sourceDigest(),repo.sourceDigest());assert.equal(cold.sourceBytes(),Buffer.byteLength(raw));
    assert.deepEqual(JSON.parse(cold.readProfileRaw('p_1')),profiles[1]);
    const directory=path.join(f.disk.directory,'layout-source',JSON.parse(f.cache.get('profiles_source_backend')).generation);
    assert.equal(fs.readdirSync(directory).filter(n=>n.startsWith('payload_')).length,0,'旧条目范围不产生每方案文件');
    passed('source ranges handle escapes/Unicode/nesting, preserve original XML and reopen exact catalog without canonical library');
  }finally{f.disk.close();}
}
{
  const f=fixture();try{
    const profile={name:'old',controls:[]},raw=JSON.stringify([profile]);f.cache.set('profiles',raw);f.cache.set('active_profile','old');
    const repo=await f.Repo.openOrMigrate(f.disk.context,f.pref,raw,'old',[input(profile,0)]);
    const before=f.cache.get('profiles_source_backend'),source=repo.sourceDigest();
    const current=repo.getCatalog();current[0].name='renamed';current[0].profileRevision=2;
    const changed=JSON.stringify({name:'renamed',controls:[],globalScale:1});
    f.control.failFlush=1;
    await assert.rejects(()=>repo.commit(current,[{profileId:'p_0',raw:changed}],'p_0',{key:'game_layout_applied_test',value:'receipt'}),/flush failure/);
    assert.equal(f.cache.get('profiles_source_backend'),before);assert.equal(f.cache.get('active_profile'),'old');
    assert.equal(f.cache.get('game_layout_applied_test'),'');assert.equal(repo.getCatalog()[0].name,'old');
    await repo.commit(current,[{profileId:'p_0',raw:changed}],'p_0',{key:'game_layout_applied_test',value:'receipt'});
    assert.equal(f.cache.get('active_profile'),'renamed');assert.equal(f.cache.get('game_layout_applied_test'),'receipt');
    assert.equal(repo.sourceDigest(),source);assert.equal(f.cache.get('profiles'),raw);
    const cold=f.cold();assert.equal(cold.getCatalog()[0].name,'renamed');assert.equal(cold.readProfileRaw('p_0'),changed);
    const oldRepository=f.Repo.open(f.disk.context,f.pref),nextCatalog=cold.getCatalog();nextCatalog[0].name='latest';nextCatalog[0].profileRevision=3;
    await cold.commit(nextCatalog,[{profileId:'p_0',raw:JSON.stringify({name:'latest',controls:[]})}],'p_0');
    const latestPointer=f.cache.get('profiles_source_backend');
    await assert.rejects(()=>oldRepository.commit(oldRepository.getCatalog(),[],'p_0'),/StaleCandidate/);
    assert.equal(f.cache.get('profiles_source_backend'),latestPointer,'旧owner快照不能覆盖新authority');
    passed('net edits and active/completion share flush; disk failure restores all three fields, cold reopen retains changed payload and original');
  }finally{f.disk.close();}
}
{
  const f=fixture();try{
    const profile={name:'safe',controls:[]},raw=JSON.stringify([profile]);f.cache.set('profiles',raw);
    await assert.rejects(()=>f.Repo.openOrMigrate(f.disk.context,f.pref,raw,'safe',[{...input(profile,0),raw:JSON.stringify({name:'changed',controls:[]})}]),/identity drift/);
    assert.equal(f.cache.get('profiles_source_backend'),undefined);assert.equal(f.cache.get('profiles'),raw);
    const repo=await f.Repo.openOrMigrate(f.disk.context,f.pref,raw,'safe',[input(profile,0)]);
    const current=repo.getCatalog();current[0].profileRevision=2;
    const before=f.cache.get('profiles_source_backend');
    await assert.rejects(()=>repo.commit(current,[{profileId:'p_0',raw:'null'}],'p_0'),/profile object/);
    assert.equal(f.cache.get('profiles_source_backend'),before);
    const pointer=JSON.parse(f.cache.get('profiles_source_backend'));
    const sourcePath=path.join(f.disk.directory,'layout-source',pointer.sourceGeneration,'source-original.json');
    fs.writeFileSync(sourcePath,raw.replace('safe','evil'));
    assert.throws(()=>f.Repo.open(f.disk.context,f.pref),/digest mismatch/);
    passed('source-index content substitution and persisted source digest drift fail closed, original preference remains recoverable');
  }finally{f.disk.close();}
}
{
  const f=fixture();try{
    const profile={name:'safe',controls:[]},raw=JSON.stringify([profile]);f.cache.set('profiles',raw);
    const repo=await f.Repo.openOrMigrate(f.disk.context,f.pref,raw,'safe',[input(profile,0)]);
    const pointer=JSON.parse(f.cache.get('profiles_source_backend'));
    const genDir=path.join(f.disk.directory,'layout-source',pointer.generation),moved=genDir+'_original';
    fs.renameSync(genDir,moved);fs.symlinkSync(moved,genDir,'junction');
    assert.throws(()=>f.Repo.open(f.disk.context,f.pref),/linked|ordinary/);
    fs.unlinkSync(genDir);fs.renameSync(moved,genDir);
    assert.equal(repo.getCatalog().length,1);
    passed('source root directory junction cannot redirect payload/cold catalog outside its checked ordinary directory');
  }finally{f.disk.close();}
}
// 大目录专项只在显式--large时执行，避免四产品每次重复数千fsync；用真实131073条越过旧4096页硬门。
if(process.argv.includes('--large')){
  const f=fixture();try{
    const count=4096*32+1,profiles=Array.from({length:count},(_,index)=>({name:'old_'+index,controls:[]}));
    const raw=JSON.stringify(profiles);assert.ok(Buffer.byteLength(raw)<16*1024*1024);
    f.cache.set('profiles',raw);f.cache.set('active_profile',profiles.at(-1).name);
    const repo=await f.Repo.openOrMigrate(f.disk.context,f.pref,raw,profiles.at(-1).name,profiles.map(input));
    const pointer=JSON.parse(f.cache.get('profiles_source_backend'));
    assert.equal(pointer.pageCount,4097);assert.equal(repo.getCatalog().length,count);
    assert.deepEqual(JSON.parse(repo.readProfileRaw('p_131072')),profiles.at(-1));
    const cold=f.cold();assert.equal(cold.getCatalog().length,count);assert.equal(cold.activeProfileId(),'p_131072');
    console.log(JSON.stringify({evidence:'source-large-catalog',profiles:count,pages:pointer.pageCount,sourceBytes:Buffer.byteLength(raw),
      maxRssKiB:process.resourceUsage().maxRSS,limitation:'宿主源码IO/冷启证据；不证明目标手机峰值内存或磁盘性能'}));
    passed('real >4096-page legacy catalog migrates and cold reopens through original source ranges without normalized library allocation');
  }finally{f.disk.close();}
}
console.log(`owner source regressions: ${groups} groups passed`);
