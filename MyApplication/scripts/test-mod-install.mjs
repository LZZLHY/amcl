import {spawnSync} from 'node:child_process';
import path from 'node:path';
for (const name of ['test-mod-manifest.mjs','test-mod-dependency-plan.mjs','test-mod-transaction.mjs','test-mod-install-ui.mjs','test-mod-loader-environment.mjs','test-mod-member-tasks.mjs','test-download-task-snapshot.mjs']) {
  const result=spawnSync(process.execPath,[path.join(import.meta.dirname,name)],{stdio:'inherit',windowsHide:true});
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status??1);
}
console.log('Mod install regression gate passed');
