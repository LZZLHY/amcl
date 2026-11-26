"""从已锁 LWJGL ZIP 取 JInput API、公有许可与两个上游消费者，编译 OHOS 专用实现。"""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import zipfile


def gamepad_members(root, archive, commit, jdk, base, output):
    """只投递平台中立 JInput API，排除桌面 native/plugin；Java6 字节码兼容旧 Forge。"""
    scratch = output / 'gamepad'
    scratch.mkdir()
    prefix = 'lwjgl-' + commit + '/'
    with zipfile.ZipFile(archive) as upstream:
        binary = upstream.read(prefix + 'libs/jinput.jar')
        if hashlib.sha256(binary).hexdigest() != '36b6fbede7a2d2f00949a87b9de83007a1c6b4ce5a96978279c0cc612a9adef5':
            raise ValueError('Unexpected JInput in pinned LWJGL distribution')
        license_text = upstream.read(prefix + 'doc/3rdparty/jinput_license.txt')
        for leaf in ('Controllers.java', 'JInputController.java'):
            path = scratch / 'src/java/org/lwjgl/input' / leaf
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(upstream.read(prefix + 'src/java/org/lwjgl/input/' + leaf))
    subprocess.run(['git', 'apply', '--no-index', str(root / 'prebuilt/lwjgl2/patches/gamepad-hotplug.patch')],
                   cwd=scratch, check=True)
    jinput = scratch / 'jinput.jar'
    jinput.write_bytes(binary)
    classes = scratch / 'classes'
    classes.mkdir()
    javac = jdk / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac')
    sources = sorted((scratch / 'src').rglob('*.java'))
    sources.append(root / 'prebuilt/lwjgl2/gamepad/DefaultControllerEnvironment.java')
    subprocess.run([str(javac), '-encoding', 'UTF-8', '-source', '1.6', '-target', '1.6', '-cp',
                    os.pathsep.join(map(str, (jinput, base))), '-d', str(classes), *map(str, sources)], check=True)
    names = {'AbstractComponent', 'AbstractController', 'Component', 'Controller', 'ControllerEnvironment',
             'ControllerEvent', 'ControllerListener', 'Event', 'EventQueue', 'Keyboard', 'Mouse', 'Rumbler', 'Version'}
    members = {'META-INF/licenses/jinput.txt': license_text}
    with zipfile.ZipFile(io.BytesIO(binary)) as compiled:
        for name in compiled.namelist():
            path = Path(name)
            if (name.startswith('net/java/games/input/') and path.suffix == '.class'
                    and path.stem.split('$')[0] in names):
                members[name] = compiled.read(name)
    for path in classes.rglob('*.class'):
        members[path.relative_to(classes).as_posix()] = path.read_bytes()
    return members


def package(base, target, members):
    """保留原 ZIP 每个未改成员的内容及属性，新成员使用固定时间和顺序，复建可逐字比对。"""
    with zipfile.ZipFile(base) as original, zipfile.ZipFile(target, 'w') as result:
        if len(original.namelist()) != len(set(original.namelist())):
            raise ValueError('Duplicate LWJGL input ZIP member')
        for item in original.infolist():
            result.writestr(item, members[item.filename] if item.filename in members else original.read(item))
        for name in sorted(members.keys() - set(original.namelist())):
            entry = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.create_system = 3
            entry.external_attr = 0o644 << 16
            result.writestr(entry, members[name])
    with zipfile.ZipFile(base) as original, zipfile.ZipFile(target) as result:
        if set(result.namelist()) != set(original.namelist()) | members.keys():
            raise ValueError('Unexpected LWJGL slot membership')
        for name in result.namelist():
            expected = members[name] if name in members else original.read(name)
            if result.read(name) != expected:
                raise ValueError('Unexpected LWJGL slot bytes: ' + name)
