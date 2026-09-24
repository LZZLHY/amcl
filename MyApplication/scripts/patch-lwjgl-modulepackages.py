#!/usr/bin/env python3
"""
patch-lwjgl-modulepackages.py — 给 LWJGL jar 的 module-info 补一个完整的 ModulePackages 属性。

背景（2026-06-28 真机闪退根因）：
  MC 1.21.6 + NeoForge 21.6 跑在 JDK 25 上时，LWJGL 走多版本 jar 的 versions/25 视图，
  org.lwjgl.system.JNI.<clinit> → FFM.<clinit> → 引用 org.lwjgl.system.ffm.mapping.Mapping。
  NeoForge 的 cpw securejarhandler 把 LWJGL 当具名 JPMS 模块加载。该 jar 的
  versions/25/module-info.class 【没有 ModulePackages 属性】，只有 Module 属性（仅列出
  导出包）。org.lwjgl.system.ffm.mapping 是【隐藏包（未导出）】且仅存在于 versions/25，
  cpw 不像标准 JDK 那样扫描 jar 补全隐藏包 → 该包不属于模块 → Mapping 类
  NoClassDefFoundError → 渲染线程闪退。
  （Fabric 把 LWJGL 放 classpath = 未命名模块，不校验包归属，故 Fabric 在 JDK 25 正常。）

修法：扫描 jar 里实际存在 .class 的全部包，给每个 module-info.class（根 + 各 versions/N）
  补一个【完整的 ModulePackages 属性】（已有则补齐缺失项）。这样 cpw 无需扫描即可获得
  完整包集合，Mapping 正常加载。幂等。

实现：纯字节码手术（无需 ASM/JDK）。新常量追加到常量池末尾（不移动既有索引）；
  ModulePackages 若不存在则作为新属性追加到 class 文件末尾（attributes 是 class 文件最后一段）。

用法: python patch-lwjgl-modulepackages.py <lwjgl.jar> [...]
"""
import sys, os, struct, zipfile, shutil, tempfile

FIXED = {3:4,4:4,7:2,8:2,9:4,10:4,11:4,12:4,15:3,16:2,17:4,18:4,19:2,20:2}
WIDE = {5:8, 6:8}


def walk_cp(data):
    """返回 (cp_end, cp_count, utf8_idx->str, str->utf8_idx, pkgname->package_const_idx)。"""
    cp_count = struct.unpack('>H', data[8:10])[0]
    off = 10; idx = 1
    utf8 = {}; utf8_rev = {}; pkg_const = {}; pkg_const_pending = {}
    while idx < cp_count:
        tag = data[off]; off += 1
        if tag == 1:
            ln = struct.unpack('>H', data[off:off+2])[0]
            s = data[off+2:off+2+ln].decode('utf-8', 'replace')
            utf8[idx] = s; utf8_rev[s] = idx
            off += 2 + ln; idx += 1
        elif tag == 20:  # Package -> name_index
            ni = struct.unpack('>H', data[off:off+2])[0]
            pkg_const_pending[idx] = ni
            off += 2; idx += 1
        elif tag in WIDE:
            off += WIDE[tag]; idx += 2
        else:
            off += FIXED[tag]; idx += 1
    for pidx, ni in pkg_const_pending.items():
        name = utf8.get(ni)
        if name is not None:
            pkg_const[name] = pidx
    return off, cp_count, utf8, utf8_rev, pkg_const


def locate_attrs(data, cp_end):
    """返回 (ac_off, attrs_start, attrs_count)。ac_off=attributes_count 字段偏移。"""
    off = cp_end + 2 + 2 + 2  # access_flags, this_class, super_class
    ic = struct.unpack('>H', data[off:off+2])[0]; off += 2 + ic*2
    off += 2  # fields_count (=0)
    off += 2  # methods_count (=0)
    ac_off = off
    ac = struct.unpack('>H', data[off:off+2])[0]; off += 2
    return ac_off, off, ac


def find_modulepackages(data, attrs_start, ac, utf8):
    off = attrs_start
    for _ in range(ac):
        ni = struct.unpack('>H', data[off:off+2])[0]
        al = struct.unpack('>I', data[off+2:off+6])[0]
        if utf8.get(ni) == 'ModulePackages':
            return (off, off+2, off+6, al)  # attr_off, len_off, info_off(=package_count_off), attr_len
        off += 6 + al
    return None


def scan_packages(z):
    pkgs = set()
    for n in z.namelist():
        if not n.endswith('.class') or n.endswith('module-info.class'):
            continue
        p = n
        if p.startswith('META-INF/versions/'):
            parts = p.split('/', 3)
            if len(parts) < 4:
                continue
            p = parts[3]
        i = p.rfind('/')
        if i < 0:
            continue
        pkgs.add(p[:i])
    return pkgs


def patch_module_info(data, want_pkgs):
    cp_end, cp_count, utf8, utf8_rev, pkg_const = walk_cp(data)
    ac_off, attrs_start, ac = locate_attrs(data, cp_end)
    mp = find_modulepackages(data, attrs_start, ac, utf8)

    # 现有 ModulePackages 中已声明的包
    have = set()
    if mp is not None:
        _, _, info_off, _ = mp
        cnt = struct.unpack('>H', data[info_off:info_off+2])[0]
        o = info_off + 2
        for _ in range(cnt):
            pi = struct.unpack('>H', data[o:o+2])[0]
            # 反查 package const -> name
            for nm, idx in pkg_const.items():
                if idx == pi:
                    have.add(nm); break
            o += 2
    # ModulePackages 应包含模块里所有包；目标 = want_pkgs 全集
    target = set(want_pkgs)
    missing = sorted(target - have)
    if not missing:
        return data, []

    # 准备新常量（追加到 cp 末尾）。先确保 "ModulePackages" Utf8（仅新建属性时需要）。
    new_consts = bytearray()
    next_idx = cp_count

    def ensure_utf8(s):
        nonlocal next_idx
        if s in utf8_rev:
            return utf8_rev[s]
        i = next_idx; next_idx += 1
        enc = s.encode('utf-8')
        new_consts.extend(bytes([1]) + struct.pack('>H', len(enc)) + enc)
        utf8_rev[s] = i
        return i

    def ensure_package(name):
        nonlocal next_idx
        if name in pkg_const:
            return pkg_const[name]
        ui = ensure_utf8(name)
        i = next_idx; next_idx += 1
        new_consts.extend(bytes([20]) + struct.pack('>H', ui))
        pkg_const[name] = i
        return i

    mp_name_idx = None
    if mp is None:
        mp_name_idx = ensure_utf8('ModulePackages')

    add_indices = [ensure_package(p) for p in missing]
    new_cp_count = next_idx

    out = bytearray()
    out += data[0:8]
    out += struct.pack('>H', new_cp_count)
    out += data[10:cp_end]
    out += new_consts

    if mp is not None:
        # 在既有属性中追加包索引
        attr_off, len_off, info_off, attr_len = mp
        pkg_count = struct.unpack('>H', data[info_off:info_off+2])[0]
        info_end = info_off + 2 + pkg_count*2
        out += data[cp_end:len_off]
        out += struct.pack('>I', attr_len + 2*len(add_indices))
        out += struct.pack('>H', pkg_count + len(add_indices))
        out += data[info_off+2:info_end]
        for pi in add_indices:
            out += struct.pack('>H', pi)
        out += data[info_end:]
    else:
        # 新建 ModulePackages 属性：先把 attributes_count +1，再在文件末尾追加属性体
        out += data[cp_end:ac_off]
        out += struct.pack('>H', ac + 1)
        out += data[ac_off+2:]   # 既有属性（Module 等）原样
        # 追加新属性： name_index(2) length(4) package_count(2) indices...
        attr_body = struct.pack('>H', len(add_indices))
        for pi in add_indices:
            attr_body += struct.pack('>H', pi)
        out += struct.pack('>H', mp_name_idx)
        out += struct.pack('>I', len(attr_body))
        out += attr_body

    return bytes(out), missing


def patch_jar(path):
    with zipfile.ZipFile(path, 'r') as z:
        want = scan_packages(z)
        items = [(info, z.read(info.filename)) for info in z.infolist()]
    if not any(i.filename.endswith('module-info.class') for i, _ in items):
        return ('skip-no-modinfo', [])
    changed = {}; report = []
    for info, content in items:
        if info.filename.endswith('module-info.class'):
            try:
                nb, added = patch_module_info(content, want)
            except Exception as e:
                report.append('  %s: ERROR %s' % (info.filename, e)); continue
            if added:
                changed[info.filename] = nb
                report.append('  %s: +%d %s' % (info.filename, len(added), added))
            else:
                report.append('  %s: ok' % info.filename)
    if not changed:
        return ('no-change', report)
    fd, tmp = tempfile.mkstemp(suffix='.jar', dir=os.path.dirname(path)); os.close(fd)
    with zipfile.ZipFile(tmp, 'w') as out:
        for info, content in items:
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.internal_attr = info.internal_attr
            zi.create_system = info.create_system
            out.writestr(zi, changed.get(info.filename, content))
    shutil.move(tmp, path)
    return ('patched', report)


def main():
    if len(sys.argv) < 2:
        print('usage: patch-lwjgl-modulepackages.py <lwjgl.jar> [...]'); sys.exit(2)
    for p in sys.argv[1:]:
        if not os.path.isfile(p):
            print('skip (not a file): ' + p); continue
        status, report = patch_jar(p)
        print('%-10s %s' % (status, p))
        for line in report:
            print(line)


if __name__ == '__main__':
    main()
