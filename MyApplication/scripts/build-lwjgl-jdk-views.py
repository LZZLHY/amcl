"""从已锁定的 OHOS modern 槽派生 JDK 专用 MR 视图，并审核磁盘或 HAP 的最终内容。

默认只读核验：原始槽、配方、生成的 ETS/JSON、派生资产必须全部匹配。
--update-lock 是维护者审查后显式更新锁定制品的入口；常规构建不能自动接受未知摘要。
保留的类/资源不重编译，变更仅限未来 MR 子树和对应的 JarIndex 目录项。
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE_MANIFEST = ROOT / 'prebuilt/lwjgl3/modern-slot.manifest.json'
VIEW_ROOT = ROOT / 'prebuilt/lwjgl3/jdk-views'
VIEW_MANIFEST = VIEW_ROOT / 'manifest.json'
RAW_ROOT = ROOT / 'entry/src/main/resources/rawfile'
ETS = ROOT / 'launch/src/main/ets/LwjglJdkViews.ets'
POLICY = 'cap-future-mr-v1'
FEATURES = (17, 21, 25)
VERSION_PREFIX = 'META-INF/versions/'


def require(condition, message):
    """所有输入/身份错误均拒绝生成，不以删除不明类或降低约束来掩盖异常。"""
    if not condition:
        raise RuntimeError(message)


def sha(data):
    """统一计算实际字节的 SHA-256，避免把 ZIP 大小或 PK 文件头当内容身份。"""
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    """身份对象采用固定排序的紧凑 JSON，不包含时间或自身摘要。"""
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('utf-8')


def mr_layer(name):
    """解析合法 MR 路径；标准忽略的非法目录也可能被 ZIP 扫描器解析，故输入时拒绝。"""
    if not name.startswith(VERSION_PREFIX) or name == VERSION_PREFIX:
        return 0
    match = re.match(r'^META-INF/versions/([1-9][0-9]*)/(.*)$', name)
    require(match is not None and int(match[1]) >= 9, '非法 MR 路径：' + name)
    require(not match[2].startswith('META-INF/'), 'META-INF 服务/签名元数据不能版本化：' + name)
    return int(match[1])


def cap_jar(data, feature):
    """裁掉高于所选 Java feature 的完整版本子树，返回输出、层集合和 major 上限。

    无需裁剪时复用源 ZIP 原字节。有变化时使用排序后的固定 ZIP 元数据及无压缩存储，
    排除 Python/zlib 版本导致的压缩字节差异；外层 HAP 仍可正常压缩这些资产。
    只有 INDEX.LIST 的失效目录行允许改变；保留的 manifest、类和资源完全不变。
    """
    kept = []
    layers = set()
    majors = []
    changed = False
    with zipfile.ZipFile(io.BytesIO(data)) as source:
        names = source.namelist()
        require(len(names) == len(set(names)), '源 JAR 包含重复 ZIP 项')
        require(source.testzip() is None, '源 JAR CRC 校验失败')
        manifest = source.read('META-INF/MANIFEST.MF').decode('utf-8')
        require(re.search(r'(?im)^Multi-Release:\s*true\s*$', manifest) is not None,
                'modern 源 JAR 缺少 Multi-Release 声明')
        for item in sorted(source.infolist(), key=lambda entry: entry.filename):
            name = item.filename
            require('..' not in name.split('/') and not name.startswith('/') and '\\' not in name,
                    '非法归档路径：' + name)
            require(not (name.startswith('META-INF/') and
                         (name.upper().endswith(('.SF', '.RSA', '.DSA', '.EC')) or
                          name.upper().startswith('META-INF/SIG-'))), '签名输入需要单独审核：' + name)
            layer = mr_layer(name)
            if layer > feature:
                changed = True
                continue
            content = source.read(item)
            if name == 'META-INF/INDEX.LIST':
                index = []
                for line in content.splitlines(keepends=True):
                    match = re.match(rb'^META-INF/versions/([1-9][0-9]*)(?:/|\s|$)', line)
                    if match and int(match[1]) > feature:
                        changed = True
                    else:
                        index.append(line)
                content = b''.join(index)
            if name.endswith('.class'):
                require(len(content) >= 8 and content[:4] == b'\xca\xfe\xba\xbe', '无效类头：' + name)
                major = struct.unpack('>H', content[6:8])[0]
                minor = struct.unpack('>H', content[4:6])[0]
                require(minor != 65535, '不交付预览字节码：' + name)
                require(major <= feature + 44 and (not layer or major <= layer + 44),
                        '保留类超出 JVM/MR 层版本：' + name)
                majors.append(major)
                if layer:
                    layers.add(layer)
            kept.append((name, content, item.is_dir()))
    if not changed:
        return data, sorted(layers), max(majors)
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as target:
        for name, content, directory in kept:
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (0o40755 if directory else 0o100644) << 16
            if directory:
                entry.external_attr |= 0x10
            target.writestr(entry, content)
    return output.getvalue(), sorted(layers), max(majors)


def make_views(root=ROOT):
    """先验证全部源 JAR 的最终大小/摘要，派生身份同时关联源 manifest 与 native 清单。"""
    source_bytes = (root / 'prebuilt/lwjgl3/modern-slot.manifest.json').read_bytes()
    source = json.loads(source_bytes)
    require(source['schema'] == 1 and source['slot'] == 'modern', '源槽身份无效')
    natives_sha = sha(canonical(source['natives']))
    assets = {}
    views = []
    for feature in FEATURES:
        jars = []
        for item in sorted(source['jars'], key=lambda jar: jar['name']):
            data = (root / 'prebuilt/lwjgl3/jars' / item['name']).read_bytes()
            require(len(data) == item['size'] and sha(data) == item['sha256'], '源槽 JAR 身份不匹配：' + item['name'])
            derived, layers, max_major = cap_jar(data, feature)
            digest = sha(derived)
            resource = 'lwjgl/' + item['name']
            if derived != data:
                resource = 'lwjgl-jdk/' + digest + '.jar'
                assets[digest + '.jar'] = derived
            jars.append({'name': item['name'], 'size': len(derived), 'sha256': digest,
                         'resourcePath': resource, 'mrLayers': layers, 'maxClassMajor': max_major})
        identity = {'schema': 1, 'slot': 'modern', 'version': source['version'],
                    # 源清单内容采用规范化 JSON 身份，避免 Windows/Linux checkout 的
                    # CRLF/LF 或无语义排版差异使同一组源 JAR/native 产生不同视图。
                    'sourceManifestSha256': sha(canonical(source)),
                    'sourceSlotIdentity': source['manifestEntrySha256'], 'nativesSha256': natives_sha,
                    'javaFeature': feature, 'policy': POLICY, 'jars': jars}
        identity['manifestSha256'] = sha(canonical(identity))
        views.append(identity)
    return {'schema': 1, 'policy': POLICY, 'views': views}, assets


def render_ets(manifest):
    """从同一锁定 JSON 生成 ArkTS 常量；所有运行时消费者共用该清单，无手写摘要副本。"""
    lines = ['/** 构建期生成的 modern JDK 视图契约。由 build-lwjgl-jdk-views.py --update-lock 更新。',
             ' * 只裁剪未来 MR 层；资源路径指向已锁定 rawfile，设备不改写 ZIP。请勿手工修改。 */',
             'export interface LwjglViewJar {', '  name: string;', '  size: number;',
             '  sha256: string;', '  resourcePath: string;', '}',
             '/** 单一视图的来源、目标 Java feature、输出摘要和完整 JAR 白名单。 */',
             'export interface LwjglJdkView {', '  javaFeature: number;', '  sourceSlotIdentity: string;',
             '  manifestSha256: string;', '  marker: string;', '  jars: LwjglViewJar[];', '}',
             'export const LWJGL_JDK_VIEWS: LwjglJdkView[] = [']
    for view in manifest['views']:
        marker = ('amcl.lwjgl.jdk-view\nversion=' + view['version'] + '\njdk=' + str(view['javaFeature'])
                  + '\npolicy=' + POLICY + '\nsource=' + view['sourceManifestSha256']
                  + '\nmanifest=' + view['manifestSha256'] + '\n')
        lines += [f"  {{ javaFeature: {view['javaFeature']}, sourceSlotIdentity: '{view['sourceSlotIdentity']}',",
                  f"    manifestSha256: '{view['manifestSha256']}',", f"    marker: {json.dumps(marker)}, jars: ["]
        for jar in view['jars']:
            lines += [f"      {{ name: '{jar['name']}', size: {jar['size']}, sha256: '{jar['sha256']}',",
                      f"        resourcePath: '{jar['resourcePath']}' }},"]
        lines += ['    ] },']
    lines += ['];', '']
    return '\n'.join(lines).encode('utf-8')


def check_or_update(update=False, hap=None):
    """审核磁盘与 HAP；显式更新仅写必要锁定制品，不删除未知旧资产或历史证据。"""
    manifest, assets = make_views()
    manifest_bytes = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
    expected = {VIEW_MANIFEST: manifest_bytes, ETS: render_ets(manifest),
                RAW_ROOT / 'lwjgl-jdk/manifest.json': manifest_bytes}
    for name, data in assets.items():
        expected[VIEW_ROOT / name] = data
        expected[RAW_ROOT / 'lwjgl-jdk' / name] = data
    for path, data in expected.items():
        if update:
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_bytes() != data:
                path.write_bytes(data)
        else:
            require(path.exists() and path.read_bytes() == data, '派生锁定制品不匹配：' + str(path))
    if hap:
        with zipfile.ZipFile(hap) as package:
            require(package.read('resources/rawfile/lwjgl-jdk/manifest.json') == manifest_bytes, 'HAP 派生清单不匹配')
            for view in manifest['views']:
                for jar in view['jars']:
                    data = package.read('resources/rawfile/' + jar['resourcePath'])
                    require(len(data) == jar['size'] and sha(data) == jar['sha256'], 'HAP 派生 JAR 身份不匹配：' + jar['name'])
    print('[lwjgl-jdk-views] PASS ' + ', '.join(str(v['javaFeature']) for v in manifest['views'])
          + '; source/recipe/ETS/rawfile' + ('/HAP' if hap else ''))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update-lock', action='store_true')
    parser.add_argument('--hap')
    arguments = parser.parse_args()
    require(not (arguments.update_lock and arguments.hap), '更新锁定与 HAP 只读审核不能同时进行')
    check_or_update(arguments.update_lock, arguments.hap)
