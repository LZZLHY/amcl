/** 更新事务的原子文件与流式SHA-256；摘要计算分块await，不把整份HAP加载到ArkTS内存。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AtomicFileWriter } from 'commons';

export class SideloadFiles {
  /** mkdirSync的recursion只负责父目录，已有目标仍可报EEXIST；同域初始化必须可重复调用。 */
  static ensureDirectory(path: string): void {
    if (!fs.accessSync(path)) fs.mkdirSync(path, true);
  }
  /** 公共完整writer成功才提交；其TypedError保留rename前失败与发布后持久性未知的边界。 */
  static write(path: string, data: string | Uint8Array): void {
    AtomicFileWriter.write(path, data);
  }

  /** 文件选择器 URI 只读，有界复制到内部新路径；处理短写，最终摘要拒绝中途被修改的输入。 */
  static async copyBounded(uri: string, destination: string, maximum: number): Promise<number> {
    const source=fs.openSync(uri,fs.OpenMode.READ_ONLY);
    let target: fs.File | undefined = undefined;
    try {
      const size=fs.statSync(source.fd).size;
      if(size<1 || size>maximum) throw new Error('安装包为空或超过大小限制');
      target=fs.openSync(destination,fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      const buffer=new ArrayBuffer(65536); let total=0;
      while(true) {
        const count=await fs.read(source.fd,buffer,{length:buffer.byteLength});
        if(count===0) break;
        total+=count; if(total>maximum || total>size) throw new Error('安装包在读取时发生变化或超过大小限制');
        let written=0;
        while(written<count) {const n=await fs.write(target.fd,buffer.slice(written,count));if(n<=0) throw new Error('无法保存安装包');written+=n;}
      }
      if(total!==size) throw new Error('安装包未完整读取，请重新选择');
      fs.fsyncSync(target.fd); return total;
    } finally { if(target!==undefined) fs.closeSync(target); fs.closeSync(source); }
  }

  /** 输入为应用自己的下载文件，成功返回小写64位摘要；任何读/摘要错误阻止签名。 */
  static async sha256(path: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(65536);
      while (true) {
        // 不指定offset，连续读取由文件描述符维护的当前位置，避免叠加偏移而跳过内容。
        const size = fs.readSync(file.fd, buffer, { length: buffer.byteLength });
        if (size <= 0) break;
        await digest.update({ data: new Uint8Array(buffer.slice(0, size)) });
      }
      const result = await digest.digest();
      let text = '';
      for (const byte of result.data) text += byte.toString(16).padStart(2, '0');
      return text;
    } finally { fs.closeSync(file); }
  }

  /** shell参数只接受内部路径/标识并按POSIX单引号转义，网页和URL不能直接构造命令。 */
  static quote(value: string): string {
    if (new RegExp('[\\r\\n\\x00]').test(value)) throw new Error('无效的更新任务参数');
    return "'" + value.replace(new RegExp("'", 'g'), "'\\''") + "'";
  }
}
