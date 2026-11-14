"""包装发现回归的独立 ZIP 边界。只写测试所有者传入的目录，不运行包内程序。"""
import io
import json
import pathlib
import stat
import sys
import zipfile


def archive(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as target:
        for name, value in entries.items():
            target.writestr(name, value)
    return stream.getvalue()


mode = sys.argv[1]
if mode == 'extract':
    with zipfile.ZipFile(sys.argv[2]) as source:
        source.extractall(sys.argv[3])
    raise SystemExit(0)

out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
mr = json.dumps({'formatVersion': 1, 'game': 'minecraft', 'name': 'Tiny Pack',
                 'dependencies': {'minecraft': '1.20.1', 'fabric-loader': '0.16.0'}, 'files': []})
cf = json.dumps({'manifestType': 'minecraftModpack', 'manifestVersion': 1, 'name': 'Tiny CF',
                 'minecraft': {'version': '1.20.1'}, 'files': [], 'overrides': 'overrides'})
mcbbs = json.dumps({'manifestType': 'minecraftModpack', 'manifestVersion': 2, 'name': 'Tiny MCBBS',
                    'addons': [{'id': 'game', 'version': '1.20.1'}], 'files': []})
payload = archive({'modrinth.index.json': mr, 'overrides/config/a.txt': 'author'})
version = json.dumps({'id': 'A', 'mainClass': 'net.minecraft.client.main.Main', 'libraries': []})
cases = {
    'standard-exe': {'modrinth.index.json': mr, 'overrides/config/a.txt': 'author', 'PCL2.exe': 'never execute'},
    'pcl': {'Plain Craft Launcher.exe': 'never execute', 'modpack.mrpack': payload},
    'hmcl-stable': {'HMCL.jar': 'never execute', '.hmcl/config/launcher-settings.json': '{}', 'modpack.mrpack': payload},
    'hmcl-main': {'HMCL.jar': 'never execute', '.hmcl/modpack/modpack.mrpack': payload},
    'deep': {'Outer/Inner/Pack/modrinth.index.json': mr},
    'dual': {'mcbbs.packmeta': mcbbs, 'manifest.json': cf, 'overrides/config/a.txt': 'author'},
    'legacy-mcbbs': {'manifest.json': mcbbs},
    'hmcl-legacy': {'modpack.json': json.dumps({'name': 'Legacy', 'version': '1'}),
                    'minecraft/pack.json': json.dumps({'id': '1.12.2', 'mainClass': 'net.minecraft.client.main.Main'})},
    'multimc': {'Pack/mmc-pack.json': '{"formatVersion":1,"components":[]}', 'Pack/instance.cfg': '[General]\nname=Pack'},
    'full': {'.minecraft/versions/A/A.json': version, '.minecraft/versions/B/B.json': version,
             '.minecraft/versions/A/mods/a.jar': 'mod', '.minecraft/versions/B/mods/b.jar': 'mod'},
    'mixed': {'manifest.json': cf, '.minecraft/versions/A/A.json': version, '.minecraft/versions/A/mods/a.jar': 'mod'},
    'ignore-mods': {'modrinth.index.json': mr, 'mods/foreign.mrpack': payload, 'resourcepacks/modpack.zip': payload},
    'multiple': {'First.mrpack': payload, 'Second.mrpack': payload},
    'nested-choices': {'modpack.mrpack': archive({'First.mrpack': payload, 'Second.mrpack': payload})},
    'unrelated-zip': {'HMCL.jar': 'never execute', 'photos.zip': archive({'picture.txt': 'no package'})},
    'traversal': {'../outside.txt': 'escape', 'modrinth.index.json': mr},
    'false-manifest': {'manifest.json': '{"name":"unrelated metadata"}', 'Pack/modrinth.index.json': mr},
    'broken-manifest': {'manifest.json': '{broken launcher configuration', 'Pack/modrinth.index.json': mr},
    'broken-manifest-inner': {'manifest.json': '{broken launcher configuration', 'modpack.mrpack': payload},
    'only-broken-manifest': {'manifest.json': '{broken genuine manifest'},
    'two-deep': {'One/Deep/modrinth.index.json': mr, 'Two/Deep/modrinth.index.json': mr},
    'implicit-parent-payloads': {'First.mrpack': archive({'Nested/modrinth.index.json': mr}),
                               'Second.mrpack': archive({'Nested/modrinth.index.json': mr})},
    'implicit-parent-chain': {'modpack.mrpack': archive({'L1/L2/modpack.mrpack':
                              archive({'Nested/modrinth.index.json': mr})})},
    'too-many': {'.minecraft/versions/V{0}/V{0}.json'.format(i): version for i in range(65)},
    'too-many-payloads': {'Pack{0:02}.mrpack'.format(i): payload for i in range(17)},
}
nested = payload
for i in range(5):
    nested = archive({'modpack.mrpack': nested})
cases['nested-too-deep'] = {'modpack.mrpack': nested}
for name, entries in cases.items():
    (out / (name + '.zip')).write_bytes(archive(entries))
# Unix symlink 的中央目录模式可在实际解压前独立判定，不依赖宿主能否创建链接。
with zipfile.ZipFile(out / 'symlink.zip', 'w') as target:
    info = zipfile.ZipInfo('link')
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    target.writestr(info, '../outside')
with zipfile.ZipFile(out / 'duplicate.zip', 'w') as target:
    target.writestr('modrinth.index.json', mr)
    target.writestr('modrinth.index.json', mr)
print(json.dumps({'generated': len(cases) + 2}))
