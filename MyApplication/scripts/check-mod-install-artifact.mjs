/**
 * 验证所选 HAP 的模组安装职责：事务与安装服务必须存在，已撤销的启动语义裁决不得残留。
 * 此门只证明可识别字节码标记，生产行为由 test-mod-install.mjs 的函数回放另行验证。
 * 必须先命中已知入口，防止读取空数据后把“找不到旧实现”误当成退役成功。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {readUniqueZipEntry} from './zip-entry-buffer.mjs';

// 正式 release 会裁掉/改名纯函数模块名；已用旧正式包与本次候选确认 ModUpdatePolicy、
// ensureModDirectory 都不是可靠阳性。改为核对两包均保留的事务类、journal 与复验/恢复分支文案，
// 再要求本轮新入口及状态 id；不能以某个优化后的内部名字缺失判断文件保障被删除。
export const requiredModMarkers = ['ModInstallService', 'ModInstallTransaction', 'mod plan committed:',
  '.amcl-mod-transaction.json', '模组提交前文件校验失败：', '模组恢复尚未完成，原文件备份保留在 ',
  'runModInstallState', 'mod_install_state', '模组安装状态'];
export const retiredModMarkers = ['runMods', 'NestedModSearch', 'ModVersionRange', 'ModZipReader',
  '模组依赖与兼容性', '模组组合无法启动，原文件已保留', '正在检查模组组合'];

/** 校验真实提取或测试注入的 ABC 字节；遇到缺失保障或残留旧判据均抛错。 */
export function verifyModInstallAbc(abc) {
  if (!abc.includes(Buffer.from('EntryAbility')) || abc.includes(Buffer.from('__amcl_impossible_artifact_canary_79b15__'))) {
    throw new Error('Artifact reader control failed');
  }
  for (const marker of requiredModMarkers) if (!abc.includes(Buffer.from(marker))) throw new Error('HAP lacks ' + marker);
  for (const marker of retiredModMarkers) if (abc.includes(Buffer.from(marker))) throw new Error('HAP retains retired mod gate: ' + marker);
}

/** 始终使用调用者指定的 HAP，返回内容哈希，供构建和本地修复验收关联同一个产物。 */
export function checkModInstallArtifact(filename) {
  const file = path.resolve(filename);
  const hap = fs.readFileSync(file);
  const abc = readUniqueZipEntry(hap, 'ets/modules.abc');
  verifyModInstallAbc(abc);
  return {path:file, bytes:hap.length, sha256:crypto.createHash('sha256').update(hap).digest('hex'),
    abcSha256:crypto.createHash('sha256').update(abc).digest('hex'), required:requiredModMarkers, retired:retiredModMarkers};
}

// 导入时仅提供检查函数，CLI 才读取产物，便于自测覆盖负例而不触碰默认构建目录。
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('Pass the exact HAP path to verify');
  const result = checkModInstallArtifact(process.argv[2]);
  console.log(JSON.stringify(result, null, 2));
  if (process.argv[3]) fs.writeFileSync(process.argv[3], JSON.stringify(result, null, 2));
}
