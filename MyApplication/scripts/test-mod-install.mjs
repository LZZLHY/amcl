import {spawnSync} from 'node:child_process';
import path from 'node:path';
// 回归检查覆盖保留的安装计划/文件事务及真实启动边界，防止已退役的兼容性扫描重新成为门槛。
for (const name of ['test-mod-install-policy.mjs','test-prelaunch-mod-state.mjs','test-check-mod-install-artifact.mjs','test-mod-dependency-plan.mjs','test-mod-transaction.mjs','test-mod-install-ui.mjs','test-mod-loader-environment.mjs','test-mod-member-tasks.mjs','test-download-task-snapshot.mjs']) {
  const result=spawnSync(process.execPath,[path.join(import.meta.dirname,name)],{stdio:'inherit',windowsHide:true});
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status??1);
}
console.log('Mod install regression gate passed');
