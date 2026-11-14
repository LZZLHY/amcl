/**
 * 运行真实 JS 回归入口，核对成功清理、非零退出与显式 keep 的端到端存储行为。
 * 不复制安装或构建断言，也不模拟 cleanup 调用；父进程直接检查子进程留下的 summary
 * 与真实文件。故意保留的现场只位于本测试亲建域，全部验证成功后由外层 scope 收口。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHostTestScope} from './lib/host-test-lifecycle.mjs';
import {resolveWorkspacePath} from './lib/workspace-paths.mjs';
import {spawnSync} from 'node:child_process';

const parent=resolveWorkspacePath('run','test-output-lifecycle');fs.mkdirSync(parent,{recursive:true});
const reportRoot=fs.mkdtempSync(path.join(parent,'run-'));
const scope=createHostTestScope('fixtures-',{parent:reportRoot,automatic:false});
const cases=[];
let failure;
try {
  for(const [entry,id] of [['test-modpack-install.mjs','modpack-regression'],
    ['test-build-gate-session.mjs','gate-session-regression']]) {
    for(const mode of ['success','failure','keep']) {
      // 实际 gate suite 会创建 Git hooks；使用短物理名并给 --out，防止测试嵌套层级
      // 与完整语义名相乘后触发 Windows Git 长路径限制。完整身份仍在外层收据中。
      const gate=entry==='test-build-gate-session.mjs';
      const runRoot=path.join(scope.directory,`${gate?'g':'m'}-${mode[0]}`);fs.mkdirSync(runRoot);
      const source=`${mode==='failure'?'process.exitCode=9;':''}await import(${JSON.stringify(new URL(entry,import.meta.url).href)});`;
      const reportDirectory=path.join(runRoot,'out');
      const child=spawnSync(process.execPath,['--input-type=module','-e',source,...(gate?['--','--out',reportDirectory]:[])],{
        encoding:'utf8',timeout:120000,env:{...process.env,AMCL_RUN_DIR:runRoot,
          AMCL_KEEP_TEST_OUTPUT:mode==='keep'?'1':''}
      });
      assert.equal(child.error,undefined,child.error?.message);
      assert.equal(child.signal,null,child.stderr);
      assert.equal(child.status===0,mode!=='failure',child.stdout+child.stderr);
      // 每次入口保留独立小结果，不通过“最新”文件推断本轮结论或删除归属。
      let reportFile;
      if(gate)reportFile=path.join(reportDirectory,'summary.json');
      else {
        const output=path.join(runRoot,id),runs=fs.readdirSync(output).filter(name=>name.startsWith('run-'));
        assert.equal(runs.length,1,entry+' must create exactly one report invocation');
        reportFile=path.join(output,runs[0],'summary.json');
      }
      const report=JSON.parse(fs.readFileSync(reportFile,'utf8'));
      assert.equal(report.state,mode==='failure'?'FAIL':'PASS');
      assert.equal(fs.existsSync(report.fixture),mode!=='success',entry+' '+mode+' fixture lifetime');
      assert.ok(path.resolve(report.fixture).startsWith(path.resolve(runRoot)+path.sep));
      assert.ok((report.total??report.cases.length)>0,'真实用例必须执行后才能形成收尾结果');
      cases.push({entry,mode,state:'PASS',childExitCode:child.status,report:reportFile,
        fixtureRetained:fs.existsSync(report.fixture),businessCases:report.total??report.cases.length});
      console.log('PASS test output lifecycle: '+entry+' '+mode);
    }
  }
} catch(error) {
  failure=error;throw error;
} finally {
  const report={state:failure?'FAIL':'PASS',completedAt:new Date().toISOString(),cases,
    ...(failure?{error:failure.stack??String(failure)}:{})};
  fs.writeFileSync(path.join(reportRoot,'summary.json'),JSON.stringify(report,null,2)+'\n');
  await scope.close({success:!failure});
}
