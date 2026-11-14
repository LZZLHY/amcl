/**
 * 证据宿主夹具的异步关闭。同步rm不能越过真实后台索引rename/fsync，也不能留下timer
 * 在删除后重建目录。先hold取消尚未运行的timer，再撤销本临时module的维护owner，
 * await当前真实job完成后交给runtime原有绝对路径校验与精确子目录回收。
 * 不启动额外维护、不固定sleep、不重试删除；在途维护失败原样抛出，不把环境故障伪装通过。
 */
export async function closeEvidenceRuntime(runtime) {
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  ledger.ledgerBeginMaintenanceBatch(runtime.directory);
  ledger.configureLedgerMaintenanceOwner(false);
  await ledger.ledgerFlushMaintenanceAsync(runtime.directory);
  runtime.close();
}
