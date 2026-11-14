#!/usr/bin/env python3
"""把最终重链 JLI/应用 ABI 闭包同步到 java.base.jmod，保证 jlink 能消费同一实现。

模块描述符和其他条目保留原字节；只替换已知 native/许可条目。不在目标设备执行
宿主工具，也不以外层 image 正确推定 JMOD 正确。替换前后完整读回，临时文件仅在
调用者显式 image 内创建，失败保留原模块，成功原子发布。
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

MAGIC = b'JM\x01\x00'
NATIVE = ('lib/libjli.so', 'lib/server/libjvm.so', 'lib/libcxxabi_shim.so', 'lib/libc++_shared.so')


def module_payloads(image):
    """明确附加库的模块归属；字体服务与其许可必须跟随 java.desktop 一起被 jlink 选择。"""
    base = {name: (image / name).read_bytes() for name in NATIVE}
    base['legal/amcl-native/NOTICE.txt'] = (image / 'legal/amcl-native/NOTICE.txt').read_bytes()
    result = {'java.base.jmod': base}
    if (image / 'lib/libfontconfig.so').is_file():
        desktop_names = ('lib/libfontconfig.so', 'lib/libfreetype.so', 'lib/libfontmanager.so',
                         'legal/amcl-fontconfig/COPYING', 'legal/amcl-expat/COPYING',
                         'legal/amcl-freetype-completion/NOTICE.txt')
        result['java.desktop.jmod'] = {name: (image / name).read_bytes() for name in desktop_names}
    return result


def verify(image: Path):
    """逐字节确认模块闭包和已交付 image 一致，并拒绝重复 ZIP 名字。"""
    for name, replacements in module_payloads(image).items():
        module = image / 'jmods' / name
        with module.open('rb') as stream:
            if stream.read(4) != MAGIC: raise ValueError(name + ' 头部不是支持的 JMOD 1.0')
        with zipfile.ZipFile(module) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)): raise ValueError(name + ' 包含重复条目')
            for relative, expected in replacements.items():
                if archive.read(relative) != expected:
                    raise ValueError('JMOD native/许可与最终 image 不一致：' + name + '/' + relative)


def sync_module(module: Path, replacements):
    """重建 ZIP 主体，再加标准四字节 JMOD 前缀，保持 ZIP 内相对偏移符合上游格式。"""
    if any(not data for data in replacements.values()):
        raise ValueError('JMOD 闭包含空输入')
    with module.open('rb') as stream:
        if stream.read(4) != MAGIC:
            raise ValueError('不支持的 JMOD 头部')
    descriptor_before = None
    # TemporaryDirectory 只管理本轮亲建目录，不递归删除 image 或共享构建父目录。
    with tempfile.TemporaryDirectory(prefix='.amcl-jmod-', dir=module.parent) as temporary:
        zip_path, candidate = Path(temporary) / 'body.zip', Path(temporary) / 'java.base.jmod'
        with zipfile.ZipFile(module) as old, zipfile.ZipFile(zip_path, 'w') as new:
            if len(old.namelist()) != len(set(old.namelist())):
                raise ValueError('原 JMOD 存在重复名字')
            descriptor_before = old.read('classes/module-info.class')
            new.comment = old.comment
            written = set()
            for info in old.infolist():
                new.writestr(info, replacements.get(info.filename, old.read(info)))
                written.add(info.filename)
            for name, data in replacements.items():
                if name not in written:
                    info = zipfile.ZipInfo(name)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = 0o100644 << 16
                    new.writestr(info, data)
        with candidate.open('wb') as output, zip_path.open('rb') as payload:
            output.write(MAGIC)
            shutil.copyfileobj(payload, output)
            output.flush()
            os.fsync(output.fileno())
        with zipfile.ZipFile(candidate) as check:
            if check.testzip() is not None or check.read('classes/module-info.class') != descriptor_before:
                raise ValueError('JMOD 重建 CRC 或原模块描述符改变')
            for name, data in replacements.items():
                if check.read(name) != data:
                    raise ValueError('JMOD 重建输入回读失败：' + name)
        os.chmod(candidate, module.stat().st_mode)
        os.replace(candidate, module)
    return hashlib.sha256(module.read_bytes()).hexdigest()


def sync(image: Path):
    """逐模块完成独占候选/完整回读；结果绑定所有实际变化的模块与追加原生输入。"""
    image = image.resolve()
    payloads = module_payloads(image)
    modules = {name: sync_module(image / 'jmods' / name, replacements)
               for name, replacements in payloads.items()}
    verify(image)
    return {'java.base.jmod': modules['java.base.jmod'], 'modules': modules,
            'native': {module: {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
                       for module, contents in payloads.items()}}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        verify(args.image)
    else:
        import json
        print(json.dumps(sync(args.image), sort_keys=True))
