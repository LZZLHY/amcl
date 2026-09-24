#!/usr/bin/env python3
"""
patch-lwjgl-module-info.py — 给 LWJGL jar 补一个根 module-info.class

背景：docker 构建的 LWJGL 3.4.1 jar 是 multi-release，module-info 只在
META-INF/versions/11|25/，根目录没有 module-info.class。旧 Forge（1.20.x 及更早）
的 cpw BootstrapLauncher + securejarhandler 2.1.x 读不到 → org.lwjgl 模块命名失败 →
闪退（FindException: Module org.lwjgl not found, required by org.lwjgl.vulkan）。

修法：把最低版本（versions/11）的 module-info.class 复制到 jar 根目录。这样旧
securejarhandler（读根）与新工具（读版本化）都能正确解析 org.lwjgl 等模块。
versions/11 是 Java 11 基线描述符（无 FFM），最稳。新 Forge（1.21.x）读版本化 module-info
不受影响。

用法: python patch-lwjgl-module-info.py <dir-with-lwjgl-jars> [<dir2> ...]
幂等：已有根 module-info 的 jar 跳过。
"""
import sys, os, re, zipfile, shutil, tempfile

VER_RE = re.compile(r'^META-INF/versions/(\d+)/module-info\.class$')

def pick_lowest_module_info(names):
    best = None
    best_v = None
    for n in names:
        m = VER_RE.match(n)
        if m:
            v = int(m.group(1))
            if best_v is None or v < best_v:
                best_v = v; best = n
    return best

def patch_jar(path):
    with zipfile.ZipFile(path, 'r') as z:
        names = z.namelist()
        if 'module-info.class' in names:
            return ('skip-has-root', None)
        src = pick_lowest_module_info(names)
        if src is None:
            return ('skip-no-modinfo', None)
        data = z.read(src)
        items = []
        for info in z.infolist():
            items.append((info, z.read(info.filename)))
    # 重写整个 jar（保持原压缩方式），追加根 module-info.class
    fd, tmp = tempfile.mkstemp(suffix='.jar', dir=os.path.dirname(path))
    os.close(fd)
    with zipfile.ZipFile(tmp, 'w') as out:
        for info, content in items:
            # 保留原 compress_type
            zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.internal_attr = info.internal_attr
            zi.create_system = info.create_system
            out.writestr(zi, content)
        mi = zipfile.ZipInfo('module-info.class')
        # ZIP 的 version-made-by 高字节随 Python 宿主系统变化。现有锁定制品在
        # Windows 生成，因此将新增条目显式固定为 FAT(0)；原有条目仍保留上游值。
        # 这只统一容器元数据，不改 class 字节、压缩方式或已经发布的 JAR 指纹。
        mi.create_system = 0
        mi.compress_type = zipfile.ZIP_DEFLATED
        out.writestr(mi, data)
    shutil.move(tmp, path)
    return ('patched', src)

def main():
    if len(sys.argv) < 2:
        print('usage: patch-lwjgl-module-info.py <dir> [<dir> ...]'); sys.exit(2)
    total = 0; patched = 0
    for d in sys.argv[1:]:
        if not os.path.isdir(d):
            print('skip (not a dir): ' + d); continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith('.jar'): continue
            p = os.path.join(d, fn)
            total += 1
            status, src = patch_jar(p)
            if status == 'patched':
                patched += 1
                print('PATCHED  %-22s (root <- %s)' % (fn, src))
            else:
                print('%-8s %s' % (status, fn))
    print('--- done: %d patched / %d jars ---' % (patched, total))

if __name__ == '__main__':
    main()
