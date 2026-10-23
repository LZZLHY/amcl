import {spawnSync} from 'node:child_process';
import path from 'node:path';
// 回归检查覆盖保留的安装计划/文件事务及真实启动边界，防止已退役的兼容性扫描重新成为门槛。
// Forge 专项执行实际服务接线，确保整合包基础版本替身不能掩盖发布坐标回归。
// 详情浏览单独执行真实页面/Sheet方法，防止安装校验再次缩窄全部版本目录。
for (const name of ['test-mod-install-policy.mjs','test-prelaunch-mod-state.mjs','test-check-mod-install-artifact.mjs','test-mod-dependency-plan.mjs','test-mod-update-session.mjs','test-installed-resource-data.mjs','test-mod-transaction.mjs','test-mod-install-ui.mjs','test-mod-detail-browse.mjs','test-mod-loader-environment.mjs','test-mod-member-tasks.mjs','test-download-task-snapshot.mjs','test-modpack-install.mjs','test-forge-coordinate.mjs','test-maven-batch-result.mjs','test-download-system.mjs']) {
  const result=spawnSync(process.execPath,[path.join(import.meta.dirname,name)],{stdio:'inherit',windowsHide:true});
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status??1);
}
console.log('Mod install regression gate passed');
