/**
 * JDK 目录的共同内容校验：供下载 staging、用户导入和已安装状态查询使用。
 * 只读取短文件头与有界 release 元数据，不加载候选 native，不执行候选 Java。
 * 此校验保证基本文件/架构/版本一致性；完整平台能力由发行清单与运行自测证明。
 */
import { fileIo as fs } from '@kit.CoreFileKit';

/** 读取普通文件的固定长度前缀；失败由调用者转换成具体文件诊断，始终关闭句柄。 */
function readPrefix(path: string, length: number): Uint8Array {
  const st = fs.statSync(path);
  if (!st.isFile() || st.size < length) throw new Error('不是普通文件或文件已截断');
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const buffer = new ArrayBuffer(length);
    if (fs.readSync(file.fd, buffer, { length: length }) !== length) throw new Error('文件头读取不完整');
    return new Uint8Array(buffer);
  } finally {
    fs.closeSync(file);
  }
}

/**
 * 核对共享库 ELF 头：当前产品只消费 AArch64、小端、64 位 ET_DYN。
 * 不把合法 UND 动态导入当错误；依赖解析属于 loader 与发布期依赖图检查。
 */
function validateLibrary(root: string, relative: string): string {
  try {
    const b = readPrefix(root + '/' + relative, 64);
    if (b[0] !== 127 || b[1] !== 69 || b[2] !== 76 || b[3] !== 70) return relative + ' 不是 ELF 原生库';
    if (b[4] !== 2 || b[5] !== 1 || b[6] !== 1) return relative + ' 不是 64 位小端 ELF';
    if (b[16] !== 3 || b[17] !== 0 || b[18] !== 183 || b[19] !== 0) {
      return relative + ' 不是 AArch64 共享库（请使用适配鸿蒙的运行包）';
    }
    if (b[52] !== 64 || b[53] !== 0) return relative + ' 的 ELF 文件头长度无效';
    return '';
  } catch (e) {
    return relative + ' 缺失、不可读或已截断';
  }
}

/**
 * 验证候选目录，返回空串代表基本内容通过；非空是可直接显示的失败原因。
 * expectedMajor 是用户选定/发行配置的槽位，不由包替用户选择。经典布局仅用于 8；
 * 模块化包还需用 release 的真实 Java 主版本与槽位核对，防止把 21 放进 17。
 */
export function validateRuntimeTree(root: string, expectedMajor: string = ''): string {
  let classic = false;
  try { classic = fs.statSync(root + '/jre/lib/aarch64/server/libjvm.so').isFile(); } catch (e) { /* 检查模块化布局。 */ }
  if (classic && expectedMajor.length > 0 && expectedMajor !== '8') return '经典 JDK 8 布局不能安装到 JDK ' + expectedMajor + ' 槽位';
  if (!classic && expectedMajor === '8') return 'JDK 8 槽位需要经典 jre/lib 布局';
  const lib = classic ? 'jre/lib/aarch64/' : 'lib/';
  const libraries: string[] = [lib + 'server/libjvm.so', lib + 'libjava.so', lib + 'libzip.so',
    lib + 'libverify.so', lib + 'libnet.so', lib + 'libnio.so',
    classic ? lib + 'jli/libjli.so' : lib + 'libjli.so'];
  for (const relative of libraries) {
    const error = validateLibrary(root, relative);
    if (error.length > 0) return error;
  }
  const boot = classic ? 'jre/lib/rt.jar' : 'lib/modules';
  try {
    const b = readPrefix(root + '/' + boot, 4);
    if (fs.statSync(root + '/' + boot).size < 1000000) return boot + ' 明显不完整';
    const magicOk = classic
      ? b[0] === 80 && b[1] === 75 && b[2] === 3 && b[3] === 4
      : b[0] === 218 && b[1] === 218 && b[2] === 254 && b[3] === 202;
    if (!magicOk) return boot + ' 文件头无效';
  } catch (e) { return boot + ' 缺失、不可读或已截断'; }
  if (!classic) {
    try {
      const st = fs.statSync(root + '/release');
      if (!st.isFile() || st.size === 0 || st.size > 65536) return 'release 元数据大小或文件类型无效';
      const release = fs.readTextSync(root + '/release');
      const matched = release.match(new RegExp('(?:^|\\n)JAVA_VERSION="([0-9]+)(?:[.\\-+_"].*)?'));
      if (matched === null || matched.length < 2) return 'release 缺少可识别的 JAVA_VERSION';
      if (expectedMajor.length > 0 && matched[1] !== expectedMajor) {
        return '包内 Java ' + matched[1] + ' 与所选 JDK ' + expectedMajor + ' 槽位不一致';
      }
    } catch (e) { return 'release 元数据缺失或不可读'; }
  }
  return '';
}
