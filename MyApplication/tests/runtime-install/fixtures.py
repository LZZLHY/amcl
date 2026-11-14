"""构建独立 ZIP 对抗输入；每个文件保留在本次外置输出，不修改源码或既有样本。"""
import io
import base64
import hashlib
import json
import pathlib
import struct
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
tool = pathlib.Path(sys.argv[2]).read_bytes()
library = pathlib.Path(sys.argv[3]).read_bytes()

# 固定真实旧发行字节作为窄兼容回归。元数据不能重标其它helper，生产侧仍独立核固定SHA；
# 这里只生成测试输入，不执行Linux解释器工具，也不把它升级为完整OHOS能力证明。
legacy_meta = json.loads((pathlib.Path(__file__).parent / 'fixtures/legacy-jdk17-v5-helper.json').read_text(encoding='utf-8'))
legacy = base64.b64decode(legacy_meta['base64'], validate=True)
assert len(legacy) == legacy_meta['size'] == 18624
assert hashlib.sha256(legacy).hexdigest() == legacy_meta['sha256'] == '8c1507458c7de60c16acae78a131f779941d2ab1c4a4f83466d05ac295c6ef96'
(root / 'legacy17-helper.bin').write_bytes(legacy)


def archive(name, entries, method=zipfile.ZIP_DEFLATED, force64=False):
    """使用标准库生成基础格式，损坏字段在生成后分别变异，避免复制被测解析器。"""
    with zipfile.ZipFile(root / (name + '.zip'), 'w', compression=method) as z:
        for filename, data, mode in entries:
            item = zipfile.ZipInfo(filename)
            item.compress_type = method
            item.external_attr = mode << 16
            with z.open(item, 'w', force_zip64=force64) as output:
                output.write(data)


normal = [('bin/java', tool, 0o100666), ('lib/jspawnhelper', tool, 0o100666),
          ('lib/libfixture.so', library, 0o100644), ('conf/中文 空格.txt', b'configuration\n', 0o100644)]
archive('good', normal)
archive('stored', normal, zipfile.ZIP_STORED)
archive('zip64', normal, force64=True)
archive('directory', [('lib/', b'', 0o40755)] + normal)
archive('wrapper', [('jdk-custom/' + p, b, m) for p, b, m in normal])
archive('traversal', [('../outside-sentinel', b'changed', 0o100644)])
archive('absolute', [('/outside-sentinel', b'changed', 0o100644)])
archive('backslash', [('dir\\outside-sentinel', b'changed', 0o100644)])
archive('duplicate', [('same', b'one', 0o100644), ('same', b'two', 0o100644)])
archive('conflict', [('lib', b'file', 0o100644), ('lib/nested', b'two', 0o100644)])
archive('component-order-conflict', [('a', b'file', 0o100644), ('a-', b'noise', 0o100644), ('a/child', b'two', 0o100644)])
archive('symlink', [('link', b'../', 0o120777), ('link/outside-sentinel', b'changed', 0o100644)])
archive('fifo', [('pipe', b'', 0o10600)])
archive('depth', [('/'.join(['d'] * 65) + '/file', b'a', 0o100644)])
archive('missing-helper', [('lib/libfixture.so', library, 0o100644)])
archive('wrong-interpreter', [('lib/jspawnhelper', tool.replace(b'ld-musl-aarch64', b'xx-musl-aarch64'), 0o100644), ('lib/libfixture.so', library, 0o100644)])
archive('missing-dependency', [('lib/jspawnhelper', tool, 0o100644)])
archive('truncated-helper', [('lib/jspawnhelper', tool[:100], 0o100644), ('lib/libfixture.so', library, 0o100644)])
archive('crc-base', [('payload', b'unchanged', 0o100644)], zipfile.ZIP_STORED)
data = bytearray((root / 'crc-base.zip').read_bytes())
at = data.index(b'unchanged')
data[at] ^= 1
(root / 'bad-crc.zip').write_bytes(data)
data = bytearray((root / 'good.zip').read_bytes())
data[30] ^= 1  # 本地名称与中央目录分离。
(root / 'local-mismatch.zip').write_bytes(data)
data = bytearray((root / 'crc-base.zip').read_bytes())
central = data.index(b'PK\1\2')
struct.pack_into('<I', data, central + 24, 0xfffffff0)
struct.pack_into('<I', data, 22, 0xfffffff0)
(root / 'declared-bomb.zip').write_bytes(data)
archive('stream-bomb-base', [('payload', b'A' * 1024 * 1024, 0o100644)])
data = bytearray((root / 'stream-bomb-base.zip').read_bytes())
central = data.index(b'PK\1\2')
struct.pack_into('<I', data, central + 24, 1)
struct.pack_into('<I', data, 22, 1)
(root / 'actual-bomb.zip').write_bytes(data)

# 不可 seek 的标准 writer 生成带 descriptor 的真实样本。
class Pipe(io.BytesIO):
    def seekable(self): return False
    def seek(self, *args): raise OSError('not seekable')

output = Pipe()
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('中文/descriptor', b'descriptor-content' * 100)
(root / 'descriptor.zip').write_bytes(output.getvalue())
archive('deep-path-metadata', [('/'.join([f'p{i:05d}'] + ['d' * 55] * 62 + ['leaf']), b'', 0o100644)
                               for i in range(3000)], zipfile.ZIP_STORED)
print('ZIP fixture files:', len(list(root.glob('*.zip'))))
