import { common } from '@kit.AbilityKit'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import { unifiedDataChannel, uniformDataStruct } from '@kit.ArkData'
import { util } from '@kit.ArkTS'

/** Materialize user-authorized drag URIs as paths accessible to the JVM. */
export class DesktopFileDrop {
  static async stage(context: common.UIAbilityContext, data: unifiedDataChannel.UnifiedData): Promise<string[]> {
    const records: unifiedDataChannel.UnifiedRecord[] = data.getRecords()
    if (records.length === 0 || records.length > 32) throw new Error('一次最多拖入 32 个文件')
    const directory: string = context.filesDir + '/desktop-drop/' + util.generateRandomUUID()
    fs.mkdirSync(directory, true)
    const paths: string[] = []
    try {
      for (let i = 0; i < records.length; i++) {
        const record: unifiedDataChannel.UnifiedRecord = records[i]
        let uri: string = ''
        if (record.getTypes().includes('general.file-uri')) {
          const file = record.getEntry('general.file-uri') as uniformDataStruct.FileUri
          if (file && typeof file.oriUri === 'string') uri = file.oriUri
        } else if (record instanceof unifiedDataChannel.File) {
          uri = (record as unifiedDataChannel.File).uri
        }
        if (!uri.startsWith('file://')) continue
        const name: string = new fileUri.FileUri(uri).name
        if (!name || name === '.' || name === '..' || new RegExp('[\\\\/\\x00]').test(name)) throw new Error('文件名无效')
        const destination: string = directory + '/' + i + '-' + name
        const source: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY)
        paths.push(destination)
        try {
          const info: fs.Stat = fs.statSync(source.fd)
          if (!info.isFile() || info.size > 1024 * 1024 * 1024) throw new Error('仅支持不超过 1 GB 的普通文件')
          await fs.copyFile(source.fd, destination)
        } finally { fs.closeSync(source) }
      }
      if (paths.length === 0) throw new Error('拖入内容不包含可读取的文件')
      return paths
    } catch (error) {
      DesktopFileDrop.discard(context, paths)
      throw error as Error
    }
  }
  static discard(context: common.UIAbilityContext, paths: string[]): void {
    for (const path of paths) {
      if (path.startsWith(context.filesDir + '/desktop-drop/')) {
        try { fs.unlinkSync(path) } catch (_) {}
      }
    }
  }
  /** Called by the launcher only after the OS game-process lock is absent. */
  static async clearPrevious(context: common.UIAbilityContext): Promise<void> {
    const root: string = context.filesDir + '/desktop-drop'
    let names: string[] = []
    try { names = fs.listFileSync(root) } catch (_) { return }
    for (const name of names) {
      if (!new RegExp('^[0-9a-f-]{36}$', 'i').test(name)) continue
      const directory: string = root + '/' + name
      try {
        if (!fs.lstatSync(directory).isDirectory()) continue
        for (const file of fs.listFileSync(directory)) {
          const path: string = directory + '/' + file
          if (!fs.lstatSync(path).isDirectory()) await fs.unlink(path)
        }
        if (fs.listFileSync(directory).length === 0) await fs.rmdir(directory)
      } catch (_) {}
    }
  }
}
