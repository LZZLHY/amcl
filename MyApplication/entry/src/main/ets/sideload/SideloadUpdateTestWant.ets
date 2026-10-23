/** default诊断入口只编排参数并调用产品服务；材料文件位于debug沙箱，Want不能带URL或秘密。 */
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { DiagnosticPolicy } from 'commons';
import { SideloadUpdateAsset, SideloadUpdatePhase, UpdateManifest } from 'update';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { SideloadUpdateService } from './SideloadUpdateService';
import { SideloadFiles } from './SideloadFiles';
import { SideloadFixtureHttp } from './SideloadFixtureHttp';
import { SideloadUpdatePageParams } from './SideloadUpdateViewModel';
import { SideloadUpdateTestSession } from './SideloadUpdateTestSession';
interface UpdateFixture { schema: number; id: string; asset: SideloadUpdateAsset; sameVersionTest?: boolean; manifestUrl?: string; }
let running: boolean = false;

/** 双门禁隔离正式产品；固定文件名读取，输入上限防止误把大文件/秘密打印到普通日志。 */
export function runSideloadUpdateTestWant(context: common.UIAbilityContext, want: Want): void {
  if (ProductBuildProfile.product !== 'default' || !DiagnosticPolicy.hasTestHooks() || running) return;
  const action = want.parameters?.['amclSideloadUpdateTest'];
  if (typeof action !== 'string') return;
  if (action !== 'prepare' && action !== 'install' && action !== 'continue' && action !== 'flow' && action !== 'connection') return;
  // 只读连接验收共用产品连接器，结果只保存候选来源、端口和真实握手结论，不输出 UDID。
  if (action === 'connection') {
    running = true;
    checkConnection(context).finally((): void => { running = false; }); return;
  }
  const path = context.filesDir + '/sideload-update-fixture-v2.json';
  // 先记录受控动作是否抵达及实际沙箱目录，避免解析/服务初始化失败时只剩一个无结果的请求。
  // 记录不包含Want正文、材料内容或用户身份；诊断只在default TestHooks开启。
  SideloadFiles.write(context.filesDir + '/sideload-update-test-ack.json', JSON.stringify({ schema: 1,
    action: action, filesDir: context.filesDir, fixtureExists: fs.accessSync(path), receivedAt: Date.now() }));
  // 仅保持本应用窗口亮屏，不尝试解锁；窗口尚未创建时保持正常启动，不阻断测试请求。
  if (action !== 'flow') {
    window.getLastWindow(context).then((value: window.Window): void => { value.setWindowKeepScreenOn(true); }).catch((): void => {});
  }
  try {
    if (!fs.accessSync(path) || !fs.statSync(path).isFile() || fs.statSync(path).size > 4096) throw new Error('测试夹具必须是小型普通文件');
    const fixture = JSON.parse(fs.readTextSync(path)) as UpdateFixture;
    if (fixture.schema !== 1 || !new RegExp('^[a-zA-Z0-9_-]{1,64}$').test(fixture.id)) return;
    running = true;
    execute(context, fixture, action).finally((): void => { running = false; });
  } catch (error) {
    SideloadFiles.write(context.filesDir + '/sideload-update-test-result.json', JSON.stringify({ schema: 1,
      action: action, error: (error as Error).message, finishedAt: Date.now() }));
  }
}

/** 不要求安装包夹具；测试侧绝不提供端口，才能区分自动发现与测试预先填入。 */
async function checkConnection(context: common.UIAbilityContext): Promise<void> {
  const start = Date.now();
  const connection = SideloadUpdateService.get(context).connection;
  let verified = false; let error = '';
  try { await connection.check(); verified = true; }
  catch (failure) { error = (failure as Error).message; }
  finally {
    await connection.close();
    SideloadFiles.write(context.filesDir + '/sideload-update-connection-test.json', JSON.stringify({ schema: 1,
      verified: verified, method: connection.discoveryMethod, port: connection.currentPort(), error: error, elapsedMs: Date.now() - start }));
  }
}

/** 自动化和页面使用同一个import/prepare/install路径；完成判据是事务字段及真实下载/签名摘要。 */
async function execute(context: common.UIAbilityContext, fixture: UpdateFixture, action: string): Promise<void> {
  let service: SideloadUpdateService | undefined = undefined;
  let transport: SideloadFixtureHttp | undefined = undefined;
  const resultPath = context.filesDir + '/sideload-update-test-result.json';
  try {
    // 构造器也是可失败的业务步骤，必须包含在本次结构化结果的异常边界内。
    service = SideloadUpdateService.get(context);
    if (action === 'prepare' || action === 'flow') {
      const material = context.filesDir + '/sideload-update-test-material-v2.json';
      if (fs.accessSync(material)) {
        try { await service.importMaterial(fs.readTextSync(material)); }
        finally { fs.unlinkSync(material); }
      }
      if (action === 'flow' && fixture.manifestUrl !== undefined) {
        const previous = service.state()?.id ?? '';
        SideloadUpdateTestSession.configure(fixture.manifestUrl, fixture.asset, fixture.sameVersionTest === true);
        AppStorage.setOrCreate<number>('amclSideloadTestRequest', Date.now());
        await waitForProductFlow(service, previous);
      } else {
        transport = new SideloadFixtureHttp();
        fixture.asset.url = await transport.start(context.filesDir + '/entry-default-unsigned.hap');
        if (action === 'flow') {
        const manifest: UpdateManifest = { versionCode: fixture.asset.versionCode, versionName: fixture.asset.versionName,
          tag: fixture.asset.tag, url: '', notes: '', mandatory: false, schema: 1, date: '',
          sizeBytes: fixture.asset.sizeBytes, changelogUrl: '', notesEntries: [] };
        const params: SideloadUpdatePageParams = { manifest: manifest, autoStart: true,
          testAsset: fixture.asset, sameVersionTest: fixture.sameVersionTest === true };
        const previous = service.state()?.id ?? '';
        const appWindow = await window.getLastWindow(context);
        await appWindow.getUIContext().getRouter().pushUrl({ url: 'pages/SideloadUpdatePage', params: params });
        await waitForProductFlow(service, previous);
        } else await service.prepare(fixture.asset, fixture.sameVersionTest === true);
      }
    } else if (action === 'continue') await service.continuePreparing();
    else await service.install();
    SideloadFiles.write(resultPath, JSON.stringify({ schema: 1, fixtureId: fixture.id, action: action,
      transaction: service.state(), httpRequests: transport?.requests ?? 0, httpBytes: transport?.bytesSent ?? 0,
      sourceMode: fixture.manifestUrl === undefined ? 'loopback' : 'https',
      downloadBytes: service.snapshot().bytesDone, downloadTotal: service.snapshot().bytesTotal,
      error: '', finishedAt: Date.now() }));
  } catch (error) {
    SideloadFiles.write(resultPath, JSON.stringify({ schema: 1, fixtureId: fixture.id, action: action,
      transaction: service?.state(), httpRequests: transport?.requests ?? 0, httpBytes: transport?.bytesSent ?? 0,
      sourceMode: fixture.manifestUrl === undefined ? 'loopback' : 'https',
      downloadBytes: service?.snapshot().bytesDone ?? 0, downloadTotal: service?.snapshot().bytesTotal ?? 0,
      error: (error as Error).message, finishedAt: Date.now() }));
  }
  finally { SideloadUpdateTestSession.clear(); await transport?.close(); }
}

/** 只观测产品事务，不执行任何下载/签名/安装逻辑；UI独占订阅不被测试替换。 */
function waitForProductFlow(service: SideloadUpdateService, previous: string): Promise<void> {
  return new Promise<void>((resolve, reject): void => {
    const started = Date.now();
    const timer = setInterval((): void => {
      const state = service.state();
      if (state !== undefined && (state.id !== previous || state.createdAt >= started - 2000) &&
        (state.phase === SideloadUpdatePhase.Installing || state.phase === SideloadUpdatePhase.Verified ||
          state.phase === SideloadUpdatePhase.Failed || state.phase === SideloadUpdatePhase.Cancelled ||
          state.phase === SideloadUpdatePhase.ConfirmationPending || state.phase === SideloadUpdatePhase.StorageBlocked || state.phase === SideloadUpdatePhase.AwaitingRestart)) {
        clearInterval(timer); resolve();
      } else if (Date.now() - started > 15 * 60 * 1000) {
        clearInterval(timer); reject(new Error('产品更新页面未在期限内结束'));
      }
    }, 500);
  });
}
