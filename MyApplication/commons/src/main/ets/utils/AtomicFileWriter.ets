/**
 * 原子文件写入的公共基础能力：写完真实字节、同步文件、替换目标、同步父目录。
 * 更新事务、加密保险库和证据元数据共用此实现，避免各自忽略短写或吞掉提交边界。
 * 输入路径必须由调用域收敛到可信私有目录；本类不接受网页路径，也不创建父目录。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { stringToUtf8 } from './Base64Util';

/** rename 前没有发布新目标；rename 后失败则目标可能已替换，不能伪装安全回滚。 */
export type AtomicWriteFailureKind = 'not-committed' | 'durability-unknown';

/** 不包含文件正文或第三方异常回显的持久化错误，供事务层阻止后续副作用。 */
export class AtomicWriteError extends Error {
  readonly kind: AtomicWriteFailureKind;
  readonly published: boolean;

  constructor(published: boolean) {
    super(published ? '文件保存失败：目标已替换但持久化尚未确认，请重新核实存储状态' : '文件保存失败：尚未提交，请检查存储后重试');
    this.name = 'AtomicWriteError';
    this.kind = published ? 'durability-unknown' : 'not-committed';
    this.published = published;
  }
}

export class AtomicFileWriter {
  /**
   * 成功返回只表示完整 durable；任何失败抛 AtomicWriteError，不能直接触发安装或重生成密钥。
   * 使用独占临时文件和64KiB块，循环处理成功短写；Uint8Array子视图只写其自身范围。
   * 临时文件清理仅针对本次名称；已发布目标在目录同步异常后保留供 Repository 重新核实。
   */
  static write(path: string, data: string | Uint8Array): void {
    let temporary: string = '';
    let temporaryDirectory: string = '';
    let directoryOwned: boolean = false;
    let opened: fs.File | undefined = undefined;
    let parent: fs.File | undefined = undefined;
    let published: boolean = false;
    try {
      const slash: number = path.lastIndexOf('/');
      if (slash <= 0 || slash === path.length - 1 || new RegExp('[\\r\\n\\x00]').test(path)) {
        throw new Error('原子写入路径无效');
      }
      // 公共FileIO没有O_EXCL标志。以mkdir的原子EEXIST语义独占唯一临时命名空间，
      // 只有创建目录成功的调用方才打开其固定内容文件，碰撞不会覆写或清理他人的现场。
      temporaryDirectory = path + '.' + util.generateRandomUUID() + '.pending-dir';
      fs.mkdirSync(temporaryDirectory);
      directoryOwned = true;
      temporary = temporaryDirectory + '/content.pending';
      opened = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      const bytes: Uint8Array = typeof data === 'string' ? stringToUtf8(data) : data;
      let position: number = 0;
      while (position < bytes.byteLength) {
        const chunk: Uint8Array = bytes.slice(position, Math.min(position + 65536, bytes.byteLength));
        const written: number = fs.writeSync(opened.fd, chunk.buffer as ArrayBuffer);
        if (!Number.isInteger(written) || written <= 0 || written > chunk.byteLength) {
          throw new Error('文件写入未取得有效字节数');
        }
        position += written;
      }
      fs.fsyncSync(opened.fd);
      fs.closeSync(opened); opened = undefined;
      fs.renameSync(temporary, path);
      published = true;
      parent = fs.openSync(path.substring(0, slash), fs.OpenMode.READ_ONLY);
      fs.fsyncSync(parent.fd);
      fs.closeSync(parent); parent = undefined;
      // 空临时目录仅是本轮命名空间，清理失败不撤销已经完成的目标提交。
      try { fs.rmdirSync(temporaryDirectory); } catch (_) { /* 留给本域启动清理。 */ }
    } catch (_) {
      if (opened !== undefined) { try { fs.closeSync(opened); } catch (_) { /* 保留原始提交分类。 */ } }
      if (parent !== undefined) { try { fs.closeSync(parent); } catch (_) { /* 关闭失败不伪装已持久化。 */ } }
      if (!published && directoryOwned && temporary.length > 0) {
        try { fs.unlinkSync(temporary); } catch (_) { /* 可能未创建或已被本次失败清理。 */ }
      }
      if (directoryOwned) { try { fs.rmdirSync(temporaryDirectory); } catch (_) { /* 只清本次空目录，不扩大范围。 */ } }
      throw new AtomicWriteError(published);
    }
  }
}
