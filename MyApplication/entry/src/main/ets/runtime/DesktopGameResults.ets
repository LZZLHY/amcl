import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { AppLogger, LOG_DOMAIN_LAUNCH } from 'commons'
import { getDownloadHistoryStore, ActivityRecord, ActivityStatus, ActivityCategory } from 'feature_core'

/** The launcher owns history Preferences; the isolated game only writes its journal. */
export class DesktopGameResults {
  private static imported: Set<string> = new Set<string>()

  static queue(context: common.Context, record: ActivityRecord): void {
    const directory: string = context.filesDir + '/desktop-results'
    try { fs.mkdirSync(directory, true) } catch (_) {}
    const path: string = directory + '/' + record.startedAt + '.json'
    let file: fs.File | undefined = undefined
    try {
      file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, JSON.stringify(record))
      fs.closeSync(file)
      file = undefined
      fs.renameSync(path + '.tmp', path)
    } catch (e) {
      AppLogger.error('DesktopGameResults', 'Cannot journal game launch failure', e, LOG_DOMAIN_LAUNCH)
    } finally {
      if (file !== undefined) { try { fs.closeSync(file) } catch (_) {} }
    }
  }

  private static importing: Promise<string> | undefined = undefined
  static importPending(context: common.Context): Promise<string> {
    const current: Promise<string> | undefined = DesktopGameResults.importing
    if (current !== undefined) return current
    const job: Promise<string> = DesktopGameResults.importInternal(context)
    DesktopGameResults.importing = job
    job.then((): void => { DesktopGameResults.importing = undefined },
      (): void => { DesktopGameResults.importing = undefined })
    return job
  }
  private static async importInternal(context: common.Context): Promise<string> {
    const directory: string = context.filesDir + '/desktop-results'
    let names: string[] = []
    try { names = fs.listFileSync(directory) } catch (_) { return '' }
    const store = getDownloadHistoryStore()
    await store.init(context)
    let message: string = ''
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i]
      if (!new RegExp('^[0-9]+[.]json$').test(name) || DesktopGameResults.imported.has(name)) continue
      const path: string = directory + '/' + name
      try {
        if (fs.statSync(path).size > 65536) continue
        const record = JSON.parse(fs.readTextSync(path)) as ActivityRecord
        if (record === undefined || record === null || !Number.isFinite(record.startedAt) || record.startedAt <= 0 ||
            record.category !== ActivityCategory.LAUNCH || record.status !== ActivityStatus.FAILED ||
            typeof record.versionName !== 'string') continue
        // Existing before this process imported the journal means the previous
        // Preferences flush survived a restart. Only then remove the journal.
        if (store.findByStartedAt(record.startedAt) !== null) { fs.unlinkSync(path); continue }
        await store.add(record)
        DesktopGameResults.imported.add(name)
        message = record.errorMessage ?? '游戏启动失败'
      } catch (e) {
        AppLogger.warn('DesktopGameResults', 'Cannot import game result ' + name, e, LOG_DOMAIN_LAUNCH)
      }
    }
    return message
  }
}
