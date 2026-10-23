/**
 * 直接执行生产 JDK 校验器，用有界内存文件系统覆盖文件内容负例。
 * 不加载测试 ELF；合法样本的头部来自 ELF64/JIMAGE 固定格式，反控改变单一字段。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

let files = new Map();
let handles = new Map();
let nextFd = 1;
const io = {
  OpenMode: { READ_ONLY: 0 },
  statSync: path => {
    const f = files.get(path);
    if (!f) throw new Error('ENOENT');
    return { size: f.size ?? f.bytes.length, isFile: () => f.regular !== false };
  },
  openSync: path => {
    if (!files.has(path)) throw new Error('ENOENT');
    const fd = nextFd++;
    handles.set(fd, path);
    return { fd };
  },
  readSync: (fd, buffer) => {
    const f = files.get(handles.get(fd));
    const bytes = Math.min(buffer.byteLength, f.bytes.length);
    new Uint8Array(buffer).set(f.bytes.subarray(0, bytes));
    return bytes;
  },
  closeSync: file => handles.delete(typeof file === 'number' ? file : file.fd),
  readTextSync: path => files.get(path).bytes.toString('utf8'),
};
const load = makePureEtsLoader({ '@kit.CoreFileKit': { fileIo: io } });
const { validateRuntimeTree } = load('launch/src/main/ets/JdkTreeValidation.ets');
const elf = () => {
  const b = Buffer.alloc(64);
  b.set([127, 69, 76, 70, 2, 1, 1]);
  b.writeUInt16LE(3, 16); b.writeUInt16LE(183, 18); b.writeUInt16LE(64, 52);
  return b;
};
function setup(major = '17', classic = false) {
  files = new Map(); handles = new Map();
  const lib = classic ? '/jdk/jre/lib/aarch64/' : '/jdk/lib/';
  for (const name of ['server/libjvm.so', 'libjava.so', 'libzip.so', 'libverify.so', 'libnet.so', 'libnio.so', classic ? 'jli/libjli.so' : 'libjli.so']) {
    files.set(lib + name, { bytes: elf() });
  }
  files.set(classic ? '/jdk/jre/lib/rt.jar' : '/jdk/lib/modules', {
    bytes: Buffer.from(classic ? [80,75,3,4] : [218,218,254,202]), size: 1000001,
  });
  files.set('/jdk/release', { bytes: Buffer.from(`JAVA_VERSION="${major}.0.1"\n`) });
}
const cases = [];
function test(name, fn) { fn(); assert.equal(handles.size, 0, '每个短文件句柄都已关闭'); cases.push(name); }
for (const major of ['17','21','25','29']) test(`接受有效 JDK${major} 布局夹具`, () => { setup(major); assert.equal(validateRuntimeTree('/jdk', major), ''); });
test('接受无 release 的经典 JDK8', () => { setup('8', true); files.delete('/jdk/release'); assert.equal(validateRuntimeTree('/jdk', '8'), ''); });
for (const size of [0,1,63]) test(`拒绝 ${size} 字节 JVM`, () => { setup(); files.set('/jdk/lib/server/libjvm.so', { bytes: Buffer.alloc(size) }); assert.notEqual(validateRuntimeTree('/jdk','17'), ''); });
test('拒绝 x86_64 ELF', () => { setup(); files.get('/jdk/lib/libjava.so').bytes.writeUInt16LE(62,18); assert.match(validateRuntimeTree('/jdk','17'), /AArch64/); });
test('拒绝可执行文件冒充 DSO', () => { setup(); files.get('/jdk/lib/libjava.so').bytes.writeUInt16LE(2,16); assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
test('拒绝目录冒充库', () => { setup(); files.get('/jdk/lib/libjava.so').regular=false; assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
test('拒绝缺失 libnet', () => { setup(); files.delete('/jdk/lib/libnet.so'); assert.match(validateRuntimeTree('/jdk','17'),/libnet/); });
test('拒绝伪造大 boot 文件', () => { setup(); files.get('/jdk/lib/modules').bytes=Buffer.alloc(4); assert.match(validateRuntimeTree('/jdk','17'),/文件头/); });
test('拒绝小 boot 文件', () => { setup(); files.get('/jdk/lib/modules').size=12; assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
test('拒绝主版本与槽位不一致', () => { setup('21'); assert.match(validateRuntimeTree('/jdk','17'),/不一致/); });
test('拒绝错误经典槽位', () => { setup('8',true); assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
test('拒绝模块化包进入 8 槽', () => { setup(); assert.notEqual(validateRuntimeTree('/jdk','8'),''); });
test('拒绝缺失版本字段', () => { setup(); files.get('/jdk/release').bytes=Buffer.from('invalid'); assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
test('拒绝超大 release', () => { setup(); files.get('/jdk/release').size=65537; assert.notEqual(validateRuntimeTree('/jdk','17'),''); });
console.log(JSON.stringify({ passed: cases.length, cases }, null, 2));
