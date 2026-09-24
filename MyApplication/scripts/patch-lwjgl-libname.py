#!/usr/bin/env python3
"""
patch-lwjgl-libname.py — 改写 LWJGL 模块 jar 里硬编码的 native 库名（字节码常量池级）

背景（LWJGL 多版本方案 C / 改名）：多套 LWJGL 的 native 要共存于同一个签名 HAP libs
扁平目录，必须改名（liblwjgl_opengl.so vs liblwjgl_opengl_v322.so）。但 LWJGL 各模块的
loader 类里把库名【硬编码】成 "lwjgl_opengl" 等（GL.java: mapLibraryNameBundled("lwjgl_opengl")），
core 库名可用 -Dorg.lwjgl.libname 覆盖，模块库名不可配置 → 必须改字节码常量。

做法：class 文件按【常量池索引】引用常量，不用字节偏移，所以把某个 CONSTANT_Utf8 的内容
改长/改短再整体重排常量池是安全的（常量池之后的字节原样复制）。本脚本扫描 jar 内每个
.class，把精确等于 <old> 的 Utf8 常量替换为 <new>，重打 jar（保留压缩方式）。

用法:
  python patch-lwjgl-libname.py <jar> <old1>=<new1> [<old2>=<new2> ...]
例:
  python patch-lwjgl-libname.py lwjgl-opengl.jar lwjgl_opengl=lwjgl_opengl_v322

幂等：若 jar 内已无 <old>（只有 <new>），不改动。
"""
import sys, os, struct, zipfile, shutil, tempfile

# 常量池各 tag 的固定负载长度（Utf8/Long/Double 特殊处理）
FIXED = {3:4, 4:4, 7:2, 8:2, 9:4, 10:4, 11:4, 12:4, 15:3, 16:2, 17:4, 18:4, 19:2, 20:2}

def patch_class(data, mapping):
    """返回 (new_bytes, changed)。mapping: {bytes_old: bytes_new}"""
    if data[:4] != b'\xca\xfe\xba\xbe':
        return data, False
    # header: magic(4) minor(2) major(2) cp_count(2)
    cp_count = struct.unpack('>H', data[8:10])[0]
    pos = 10
    out = bytearray(data[:10])
    changed = False
    i = 1
    while i < cp_count:
        tag = data[pos]
        if tag == 1:  # Utf8
            length = struct.unpack('>H', data[pos+1:pos+3])[0]
            raw = data[pos+3:pos+3+length]
            entry_end = pos+3+length
            new = mapping.get(bytes(raw))
            if new is not None:
                out.append(1)
                out += struct.pack('>H', len(new))
                out += new
                changed = True
            else:
                out += data[pos:entry_end]
            pos = entry_end
            i += 1
        elif tag in (5, 6):  # Long/Double 占两个槽
            out += data[pos:pos+9]
            pos += 9
            i += 2
        else:
            ln = FIXED.get(tag)
            if ln is None:
                raise ValueError('unknown constant tag %d at %d' % (tag, pos))
            out += data[pos:pos+1+ln]
            pos += 1+ln
            i += 1
    # 常量池之后的所有字节（access_flags ... 全部）原样复制
    out += data[pos:]
    return bytes(out), changed

def patch_jar(path, mapping):
    with zipfile.ZipFile(path, 'r') as z:
        items = [(info, z.read(info.filename)) for info in z.infolist()]
    changed_files = 0
    fd, tmp = tempfile.mkstemp(suffix='.jar', dir=os.path.dirname(os.path.abspath(path)))
    os.close(fd)
    with zipfile.ZipFile(tmp, 'w') as out:
        for info, content in items:
            if info.filename.endswith('.class'):
                content2, ch = patch_class(content, mapping)
                if ch:
                    changed_files += 1
                    content = content2
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.internal_attr = info.internal_attr
            zi.create_system = info.create_system
            out.writestr(zi, content)
    shutil.move(tmp, path)
    return changed_files

def main():
    if len(sys.argv) < 3:
        print('usage: patch-lwjgl-libname.py <jar> <old>=<new> [<old>=<new> ...]'); sys.exit(2)
    jar = sys.argv[1]
    mapping = {}
    for spec in sys.argv[2:]:
        old, new = spec.split('=', 1)
        mapping[old.encode()] = new.encode()
    n = patch_jar(jar, mapping)
    print('PATCHED %s : %d class file(s) rewritten %s'
          % (os.path.basename(jar), n, '/'.join('%s->%s' % (k.decode(), v.decode()) for k, v in mapping.items())))

if __name__ == '__main__':
    main()
