"""Compile regression harnesses with verbatim production functions, including SDL's ordered patches."""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'entry/src/main/cpp/tests/host'
UNKNOWN = '#error AMCL_UNAVAILABLE_PATCH_CONTEXT'


def locate_hunk(old, before, declared_start, cursor, label):
    """定位旧正文：声明位置不冲突时保留稀疏重建；错位只接受完整已知正文的唯一精确匹配。

    unified diff 的行号允许随前序补丁变化，不能把合法 offset 当内容冲突。回退查找不
    丢弃上下文、不修剪空白，也不把 None 当通配符；未知稀疏行不能证明某个位置匹配。
    重复候选、正文变化或回退到已消费范围均拒绝，避免悄悄生成另一份“看起来能编译”的实现。
    """
    declared = old[declared_start:declared_start + len(before)]
    if len(declared) != len(before):
        raise ValueError(f'{label}: sparse extent missing')
    if declared_start >= cursor and all(actual is None or actual == expected
           for actual, expected in zip(declared, before)):
        return declared_start
    if not before:
        raise ValueError(f'{label}: empty old body cannot establish an offset')
    matches = [start for start in range(cursor, len(old) - len(before) + 1)
               if old[start:start + len(before)] == before]
    if len(matches) != 1:
        raise ValueError(f'{label}: context mismatch; complete exact old-body matches={len(matches)}')
    return matches[0]


def patch_sources():
    """Apply unified hunks to a sparse original; never invent missing upstream lines."""
    folder = ROOT / 'prebuilt/sdl3/patches'
    files = {}
    for name in (folder / 'series').read_text(encoding='utf-8').splitlines():
        if not name.strip() or name.startswith('#'):
            continue
        patch = (folder / name.strip()).read_text(encoding='utf-8')
        for section in re.split(r'^diff --git ', patch, flags=re.M)[1:]:
            match = re.search(r'^\+\+\+ b/(.+)$', section, re.M)
            if not match:
                continue
            filename = match[1]
            if Path(filename).name not in ['SDL_openharmonyopengl.c', 'SDL_openharmonywindow.c', 'SDL_openharmonyamcl.c', 'SDL_amcldesktop.c',
                'SDL_amclgraphicsruntime.h', 'graphics_runtime_abi.h', 'graphics_context_abi.h',
                'SDL_egl.c', 'SDL_openharmonywindow.h', 'SDL_amclgraphicsobservation.h']:
                continue
            old = files.get(filename, [])[:]
            output, cursor = [], 0
            hunks = list(re.finditer(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', section, re.M))
            for i, hunk in enumerate(hunks):
                count = int(hunk[2] or 1)
                start = int(hunk[1]) - (1 if count else 0)
                body = section[hunk.end():hunks[i+1].start() if i+1 < len(hunks) else len(section)]
                before, after = [], []
                for line in body.splitlines():
                    if len(before) == count and len(after) == int(hunk[4] or 1):
                        break
                    if not line:
                        line = ' '  # git accepts an empty context line without its leading space.
                    if line.startswith((' ', '-')):
                        before.append(line[1:])
                    if line.startswith((' ', '+')):
                        after.append(line[1:])
                if len(before) != count or len(after) != int(hunk[4] or 1):
                    raise ValueError(f'{name}: incomplete hunk {filename}')
                # 首次见到上游文件时仍保留未知行占位；仅用完整旧正文确定实际偏移，
                # 不以 hunk 行号强制拒绝 git apply 可以精确应用的前序改动。
                if len(old) < start + count:
                    old.extend([None] * (start + count - len(old)))
                start = locate_hunk(old, before, start, cursor, f'{name}: {filename}:{start + 1}')
                output.extend(old[cursor:start])
                output.extend(after)
                cursor = start + count
            output.extend(old[cursor:])
            files[filename] = output
    return {Path(name).name: '\n'.join(line if line is not None else UNKNOWN for line in lines) + '\n'
            for name, lines in files.items()}


def block(source, start):
    # Preserve the code, masking only comments/literals while counting braces.
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda m: ' ' * len(m[0]), source)
    brace = masked.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (masked[end] == '{') - (masked[end] == '}')
        end += 1
    result = source[start:end]
    if UNKNOWN in result:
        raise ValueError('Regression requires production lines absent from the patch recipe')
    return result


def function(source, name):
    match = re.search(r'^(?:static )?(?:bool|void|int|SDL_GLContext|GLFWwindow\*)\s+' + re.escape(name) + r'\([^;{}]*\)\s*\{', source, re.M)
    if not match:
        raise ValueError(f'Production function missing: {name}')
    return block(source, match.start())


def generate_glfw_context(output):
    """独立抽取当前 GLFW 生产函数；SDL 全量补丁回归仍由原 generate 路径严格校验。"""
    glfw = (ROOT / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    production = '\n\n'.join(function(glfw, name) for name in
                             ['clearEglContextOwnershipAfterDetach', 'clearEglTlsAfterPartialDetach',
                              'glfwMakeContextCurrent', 'glfwSwapBuffers'])
    template = (HOST / 'desktop_review/glfw_context.cpp.in').read_text(encoding='utf-8')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'glfw_context.cpp').write_text(template.replace('@PRODUCTION@', production),
                                            encoding='utf-8', newline='\n')
    print('GLFW context regression generated from current production functions; SDL recipe not evaluated')


def generate(output, sdl_repo=None):
    sdl = patch_sources()
    glfw = (ROOT / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    callbacks = (ROOT / 'entry/src/main/cpp/glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
    gl = sdl['SDL_openharmonyopengl.c']
    window = sdl['SDL_openharmonywindow.c']
    amcl = sdl['SDL_openharmonyamcl.c']
    desktop = sdl['SDL_amcldesktop.c']
    units = {
        'glfw_context': [function(glfw, name) for name in ['clearEglContextOwnershipAfterDetach',
            'clearEglTlsAfterPartialDetach', 'glfwMakeContextCurrent', 'glfwSwapBuffers']],
        'glfw_monitor': [function(callbacks, 'glfwOHOS_ApplyInitialMonitor')],
        'sdl_profile': [function(gl, name) for name in ['OPENHARMONY_GLES_NativeGlRequired',
            'OPENHARMONY_GLES_EnsureUsableProfile', 'OPENHARMONY_GLES_TryPinConfig']],
        'sdl_hide': [function(desktop, 'Presented'), function(desktop, 'OPENHARMONY_DesktopCommand'), function(window, 'OPENHARMONY_HideWindow')],
        'sdl_owner': [function(gl, 'OPENHARMONY_GLES_SetCurrentCache'), function(gl, 'OPENHARMONY_GLES_RestorePreviousBinding'),
                      function(amcl, 'OPENHARMONY_AMCL_CommitCurrentCache')],
    }
    pump = function(desktop, 'OPENHARMONY_DesktopPump')
    visibility = block(pump, pump.index('    if (visibility_pending &&'))
    units['sdl_hide'].append('void Reconcile(SDL_VideoDevice* device, SDL_Window* window, const Snapshot& f) {\n' + visibility + '\n}')
    make = function(gl, 'OPENHARMONY_GLES_MakeCurrent')
    release = block(make, make.index('    if (!window || !context) {'))
    units['sdl_owner'].append('bool Release(SDL_VideoDevice* _this, SDL_Window* window, SDL_GLContext context) {\n' + release + '\nreturn false;\n}')
    for source, fname, probe in [(amcl, 'OPENHARMONY_AMCL_SyncBrokerWindow', 'RecoveryBlocked'),
                                 (window, 'OPENHARMONY_ApplyPendingAuxiliaryResize', 'ResizeBlocked')]:
        body = function(source, fname)
        start = re.search(r'    if \(data->(?:is_current|owner_thread)', body).start()
        guard = body[start + len('    if ('):body.index(') {', start)]
        units['sdl_owner'].append('bool ' + probe + '(SDL_WindowData* data, int current_thread) { return ' + guard + '; }')
    # The initial request must participate in the real create transaction.
    creation = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', function(glfw, 'glfwCreateWindow'))
    if 'if (monitor && !glfwOHOS_ApplyInitialMonitor(win, monitor, width, height))' not in creation:
        raise ValueError('Initial monitor request disconnected from glfwCreateWindow')
    if sdl_repo:
        for filename, source in sdl.items():
            actual = Path(sdl_repo) / ('src/video' if filename == 'SDL_egl.c' else 'src/video/openharmony') / filename
            if not actual.exists():
                raise ValueError(f'Applied SDL file missing: {actual}')
            actual_lines = actual.read_text(encoding='utf-8').splitlines()
            for index, line in enumerate(source.splitlines()):
                if line != UNKNOWN and (index >= len(actual_lines) or line != actual_lines[index]):
                    raise ValueError(f'Applied SDL differs from test recipe: {filename}:{index+1}')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'graphics_runtime_abi.h').write_text(sdl['graphics_runtime_abi.h'], encoding='utf-8', newline='\n')
    (output / 'graphics_context_abi.h').write_text(sdl['graphics_context_abi.h'], encoding='utf-8', newline='\n')
    for unit, parts in units.items():
        template = (HOST / 'desktop_review' / (unit + '.cpp.in')).read_text(encoding='utf-8')
        (output / (unit + '.cpp')).write_text(template.replace('@PRODUCTION@', '\n\n'.join(parts)), encoding='utf-8', newline='\n')
    print('Desktop review regression sources generated from current production and ordered SDL patches')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sdl-repo', type=Path)
    parser.add_argument('--glfw-context-only', action='store_true',
                        help='仅抽取 GLFW 生产函数，不运行或宣称通过 SDL 补丁回归')
    args = parser.parse_args()
    if args.glfw_context_only:
        if args.sdl_repo:
            parser.error('--glfw-context-only cannot validate --sdl-repo')
        generate_glfw_context(args.out)
    else:
        generate(args.out, args.sdl_repo)
