/** 两台开发设备只读取证的旧记录形状回归；source使用固定样本，绝不声称此脚本安装或认证真机。 */
import assert from 'node:assert/strict';
import {fixture,record,payload} from './lib/sideload-coordinator-fixture.mjs';
for(const [label,targetCode,targetName,currentCode,currentName,uid,product] of [
  ['phone690-to-910',1000690,'1.0.5',1000910,'1.0.6',20020376,'default'],
  ['tablet910-same-code-source-replaced',1000910,'1.0.6',1000910,'1.0.6',20020237,'sideload']]) {
  const old=record('verified');Object.assign(old,{schema:2,revision:1,ownerAttemptId:old.id,installProtocol:2,installId:'a'.repeat(32),
    beforeVersionCode:targetCode-1,beforeUid:uid,installedIdentityVerified:true,confirmedAt:label.startsWith('phone')?1791193814309:1792774997006});
  old.asset={...old.asset,versionCode:targetCode,versionName:targetName};delete old.asset.sourceRevision;
  const f=await fixture({journal:old,initialEnvironment:{version:currentCode,versionName:currentName,payload:'f'.repeat(40),uid,product}});
  const migrated=f.coordinator.state();assert.equal(migrated.phase,'superseded',label);assert(migrated.legacySuperseded);
  assert.equal(migrated.completion,undefined);assert.equal(migrated.runtimeIntentId,undefined);assert.equal(migrated.expectedPayloadIdentity,payload);
  assert.equal(migrated.asset.sourceRevision,undefined,'old expectedPayloadIdentity remains authoritative history');
  assert.equal(f.coordinator.needsAttention(),false);assert.equal(f.counters.observe??0,0);assert.equal(f.counters.complete??0,0);
  assert.equal(f.counters.planVerified??0,0);assert.equal(f.counters.planSuperseded??0,0);assert.equal(f.storage.get('amclSideloadUpdateCompleted'),undefined);
  const stable=JSON.stringify(migrated);await f.coordinator.resumeVerifiedCompletion();assert.equal(JSON.stringify(f.coordinator.state()),stable,'cold/foreground repeat is idempotent');
  f.coordinator.setAbilityForeground(false);
}
{
  const old={...record('verified'),schema:2,revision:1,ownerAttemptId:'b'.repeat(32),installProtocol:2,installId:'a'.repeat(32),runtimeIntentId:'c'.repeat(32)};
  const f=await fixture({journal:old,runtimePlanPending:true,initialEnvironment:{version:3,versionName:'3.0.0',uid:42,payload:'f'.repeat(40)}});
  assert.equal(f.coordinator.state().phase,'verified');assert.equal(f.coordinator.state().legacySuperseded,undefined);
  assert.equal(f.coordinator.needsAttention(),true,'active plan/binding is never historical-migrated');f.coordinator.setAbilityForeground(false);
}
console.log('PASS legacy completion: real phone/tablet shapes, default canonical product, equal-code changed source, no fresh intent grant, active plan remains protected');
