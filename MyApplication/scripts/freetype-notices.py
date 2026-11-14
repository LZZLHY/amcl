#!/usr/bin/env python3
"""从原冻结补全补丁保全新增 FreeType 文件的原版权/许可，生成派生分发材料。

该材料不改变编译输入，也不是法律解释。逐个新增文件先从完整新增 hunk 恢复
原文并匹配锁定 SHA，再复制包含版权/许可的原注释和对应版本的完整许可文件。
编译控制文件不是新增上游文件，不混入本 notice 的文件列表。
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha(data):
    """所有输入与输出都绑定原始字节，不按文件名或版本字符串替代身份。"""
    return hashlib.sha256(data).hexdigest()


def imported_sources(patch, item):
    """只解析已审核 generator 产生的整文件新增 hunk；正文或集合漂移立即拒绝。"""
    if sha(patch) != item['patchSha256']:
        raise ValueError('FreeType completion patch identity mismatch')
    targets = {record['target']: name for name, record in item['importedFiles'].items()}
    sources = {}
    for section in re.split(rb'(?m)(?=^diff --git )', patch.replace(b'\r\n', b'\n')):
        hit = re.search(rb'^\+\+\+ b/([^\n]+)$', section, re.M)
        if hit and b'--- /dev/null\n' in section and hit[1].decode() not in targets:
            raise ValueError('FreeType patch contains an undeclared added source file')
        if not hit or hit[1].decode() not in targets:
            continue
        name = targets[hit[1].decode()]
        if name in sources or b'--- /dev/null\n' not in section:
            raise ValueError('FreeType imported file is not a unique complete addition')
        hunk = re.search(rb'^@@ -0,0 \+1,(\d+) @@\n', section, re.M)
        if not hunk:
            raise ValueError('FreeType added file lacks one complete source hunk')
        lines = section[hunk.end():].splitlines(keepends=True)
        if len(lines) != int(hunk[1]) or any(not line.startswith(b'+') for line in lines):
            raise ValueError('FreeType addition has incomplete or unexpected hunk content')
        content = b''.join(line[1:] for line in lines)
        if sha(content) != item['importedFiles'][name]['sha256']:
            raise ValueError('FreeType imported source differs from locked upstream: ' + name)
        sources[name] = content
    if set(sources) != set(item['importedFiles']):
        raise ValueError('FreeType notice source set is incomplete')
    return sources


def original_notices(content):
    """保留含版权/明确许可的完整 C 注释块，不翻译、裁剪或合并作者与免责声明。"""
    blocks = [match[0] for match in re.finditer(rb'/\*.*?\*/', content, re.S)
              if re.search(rb'copyright|permission is hereby', match[0], re.I)]
    if not blocks:
        raise ValueError('Imported FreeType file has no original copyright/permission block')
    return blocks


def notice_bytes(major, completion, patch, licenses):
    """确定性生成一个 notice，附完整文件列表及版本匹配许可证原文。"""
    item = completion['runtimes'][str(major)]
    sources = imported_sources(patch, item)
    header = ('AMCL FreeType completion: original source notices\n'
              'Derived distribution supplement; not an original compiler input.\n'
              f'JDK major: {major}\nFreeType version: {item["version"]}\n'
              f'Upstream repository: {completion["repository"]}\nUpstream commit: {item["commit"]}\n'
              f'Completion patch: {item["patch"]}\n'
              'The exact added-file list, original notice text and matching license text follow.\n')
    pieces = [header.encode()]
    records = {}
    for name, content in sorted(sources.items()):
        blocks = original_notices(content)
        pieces.append(f'\n[Added source file] {name}\nSHA-256: {sha(content)}\n\n'.encode())
        for block in blocks:
            pieces.extend((block, b'\n'))
        records[name] = {'sha256': sha(content), 'target': item['importedFiles'][name]['target'],
                         'noticeBlocksSha256': [sha(block) for block in blocks]}
    if set(licenses) != set(item['licenses']):
        raise ValueError('FreeType notice license set differs from locked completion manifest')
    for name, data in sorted(licenses.items()):
        if sha(data) != item['licenses'][name]['sha256']:
            raise ValueError('FreeType original license identity mismatch: ' + name)
        pieces.extend((f'\n[Upstream license file] {name}\nSHA-256: {sha(data)}\n\n'.encode(), data, b'\n'))
    return b''.join(pieces), records


def verify_record(major, completion_raw, patch, licenses, record, actual):
    """从编译时来源重新计算 notice；派生清单单独声明不能替代正文核验。"""
    completion = json.loads(completion_raw)
    item = completion['runtimes'][str(major)]
    expected, files = notice_bytes(major, completion, patch, licenses)
    if (record['jdkCommit'] != item['jdkCommit'] or record['commit'] != item['commit']
            or record['version'] != item['version'] or record['patch'] != item['patch']
            or record['patchSha256'] != item['patchSha256'] or record['sourceFiles'] != files
            or record['licenses'] != item['licenses'] or actual != expected
            or record['sha256'] != sha(actual) or record['bytes'] != len(actual)):
        raise ValueError('FreeType derived notice differs from exact compiled source/license inputs')


def main():
    """输出为独立 derived manifest；绝不改 freetype-completion.json 或历史构建收据。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--major', nargs='+', choices=('17', '21', '25'), default=['17', '21', '25'],
                        help='公开单代源包只需选择其主版本；维护工作区默认生成全部三代')
    args = parser.parse_args()
    source_path = args.project_root / 'prebuilt/fontconfig/freetype-completion.json'
    completion_raw = source_path.read_bytes()
    completion = json.loads(completion_raw)
    manifest = {'schemaVersion': 1, 'kind': 'version-matched-freetype-notices',
                'scope': 'derived-distribution-supplement', 'compiledInput': False,
                'completionManifestSha256': sha(completion_raw),
                'generatorSha256': sha(Path(__file__).read_bytes()), 'runtimes': {}}
    args.output.mkdir(parents=True, exist_ok=False)
    for major in dict.fromkeys(args.major):
        item = completion['runtimes'][major]
        patch = (args.project_root / item['patch']).read_bytes()
        licenses = {name: (args.project_root / record['path']).read_bytes() for name, record in item['licenses'].items()}
        content, sources = notice_bytes(major, completion, patch, licenses)
        path = args.output / ('jdk' + major + '-NOTICE.txt')
        path.write_bytes(content)
        record = {name: item[name] for name in ('jdkCommit', 'commit', 'version', 'patch', 'patchSha256', 'licenses')}
        record.update(file=path.name, sha256=sha(content), bytes=len(content), sourceFiles=sources)
        verify_record(major, completion_raw, patch, licenses, record, content)
        manifest['runtimes'][major] = record
    (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(args.output), 'manifestSha256': sha((args.output / 'manifest.json').read_bytes()),
                      'sourceFileCounts': {major: len(item['sourceFiles']) for major, item in manifest['runtimes'].items()}}, ensure_ascii=False))


if __name__ == '__main__':
    main()
