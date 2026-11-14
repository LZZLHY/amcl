"""安装组合回归的小型真实ZIP。只生成数据，不执行启动器或访问用户目录。"""
import hashlib
import io
import json
import pathlib
import sys
import zipfile

def archive(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as target:
        for name, value in entries.items():
            target.writestr(name, json.dumps(value) if isinstance(value, dict) else value)
    return stream.getvalue()

if sys.argv[1] == 'extract':
    with zipfile.ZipFile(sys.argv[2]) as source:
        source.extractall(sys.argv[3])
    raise SystemExit(0)
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
mr = {'formatVersion': 1, 'game': 'minecraft', 'name': 'Author', 'versionId': '1',
      'dependencies': {'minecraft': '1.20.1', 'fabric-loader': '0.16.0'}, 'files': []}
cf = {'manifestType': 'minecraftModpack', 'manifestVersion': 1, 'name': 'CF Author',
      'minecraft': {'version': '1.20.1'}, 'files': [], 'overrides': 'overrides'}
content = {'overrides/mods/content.jar': 'MOD', 'overrides/config/pack.cfg': 'CONFIG'}
leaf = archive({'modrinth.index.json': mr, **content})
bad_leaf = archive({'modrinth.index.json': {**mr, 'name': 'Broken', 'dependencies': {}}, **content})
def version(name):
    return {'id': name, 'clientVersion': '1.20.1', 'mainClass': 'net.fabricmc.loader.impl.launch.knot.KnotClient',
            'libraries': [{'name': 'net.fabricmc:fabric-loader:0.16.0'}]}
full = {'.minecraft/versions/Pack/Pack.json': version('Pack'), '.minecraft/versions/Pack/Pack.jar': 'PC-JAR',
        '.minecraft/versions/Pack/mods/content.jar': 'MOD', '.minecraft/versions/Pack/config/pack.cfg': 'CONFIG',
        '.minecraft/versions/Pack/user_jvm_args.txt': '-Dunsafe.desktop=true',
        '.minecraft/launcher_accounts.json': 'PRIVATE', 'PCL.exe': 'PASSIVE'}
cases = {
    'standard': {'modrinth.index.json': mr, **content, 'PCL.exe': 'PASSIVE'},
    'pcl': {'Plain Craft Launcher.exe': 'PASSIVE', 'modpack.mrpack': leaf},
    'hmcl-main': {'HMCL-custom.jar': 'PASSIVE', '.hmcl/modpack/modpack.zip': leaf},
    'multiple-archives': {'First.mrpack': leaf, 'Second.mrpack': leaf},
    'bad-and-good': {'Bad.mrpack': bad_leaf, 'Good.mrpack': leaf},
    'deep': {'Outer/Inner/Pack/' + key: value for key, value in {'modrinth.index.json': mr, **content}.items()},
    'full': full,
    'full-wrapped': {key.replace('/Pack/mods/', '/Pack/.minecraft/mods/').replace('/Pack/config/', '/Pack/.minecraft/config/'): value for key, value in full.items()},
    'full-multiple': {**full, '.minecraft/versions/Other/Other.json': version('Other'), '.minecraft/versions/Other/mods/other.jar': 'OTHER'},
    'data-choice': {**full, '.minecraft/mods/shared.jar': 'SHARED'},
    'overrides-dot': {'manifest.json': {**cf, 'overrides': './'}, 'mods/content.jar': 'MOD', 'config/pack.cfg': 'CONFIG', 'PCL.exe': 'PASSIVE'},
    'overrides-slash': {'manifest.json': {**cf, 'overrides': './overrides/'}, **content},
    'minecraft-layer': {'manifest.json': cf, 'overrides/.minecraft/mods/content.jar': 'MOD', 'overrides/.minecraft/config/pack.cfg': 'CONFIG'},
    'ambiguous-layer': {'manifest.json': cf, 'overrides/.minecraft/mods/content.jar': 'MOD', 'overrides/CustomModData/data.bin': 'UNIQUE'},
    'missing-layer': {'manifest.json': cf, 'mods/content.jar': 'MOD'},
    'empty-overrides': {'manifest.json': cf},
    'duplicate-cf': {'manifest.json': {**cf, 'files': [{'projectID': 1, 'fileID': 2, 'required': False}, {'projectID': 1, 'fileID': 2, 'required': True}]}},
    'multimc': {'mmc-pack.json': {'formatVersion': 1, 'components': [{'uid': 'net.minecraft', 'version': '1.20.1'}]},
                'instance.cfg': 'name=MMC\nPreLaunchCommand=never', '.minecraft/mods/content.jar': 'MOD'},
    'mcbbs': {'mcbbs.packmeta': {'manifestType': 'minecraftModpack', 'manifestVersion': 2, 'name': 'MCBBS',
        'addons': [{'id': 'game', 'version': '1.20.1'}, {'id': 'fabric', 'version': '0.16.0'}],
        'files': [{'type': 'addon', 'path': 'mods/content.jar', 'hash': hashlib.sha1(b'MOD').hexdigest()}]},
        'manifest.json': cf, **content},
}
for name, entries in cases.items():
    (out / (name + '.zip')).write_bytes(archive(entries))
