"""Compile regression harnesses with verbatim production functions, including SDL's ordered patches."""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'entry/src/main/cpp/tests/host'
UNKNOWN = '#error AMCL_UNAVAILABLE_PATCH_CONTEXT'
SDL_PHONE_CLIPBOARD_SOURCES = ('SDL_amclphoneclipboard.c', 'SDL_amclphoneclipboard.h')
SDL_REVIEW_UNCHANGED_SOURCES = ('src/events/SDL_windowevents.c',)
SDL_DESKTOP_REVIEW_SOURCES = (
    'SDL_openharmonyopengl.c', 'SDL_openharmonywindow.c', 'SDL_openharmonyamcl.c', 'SDL_amcldesktop.c',
    'SDL_amclgraphicsruntime.h', 'graphics_runtime_abi.h', 'graphics_context_abi.h', 'sdl_aux_runtime_abi.h',
    'SDL_egl.c', 'SDL_video.c', 'SDL_openharmonywindow.h', 'SDL_amclgraphicsobservation.h',
    'control_delivery.h', 'control_delivery_client.h', 'SDL_inputdelivery_c.h',
    'SDL_keyboard.c', 'SDL_keyboard_c.h', 'SDL_mouse.c', 'SDL_mouse_c.h', 'SDL_events.c', 'SDL_events_c.h',
    'SDL_windowevents.c',
    'SDL_amclinputcontrol_c.h', 'SDL_amclinputhostpolicy.h', 'SDL_dynapi.sym', 'SDL_dynapi.exports',
)


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


def patch_sources(selected_sources=SDL_DESKTOP_REVIEW_SOURCES, *, applied_repo=None, originals=None):
    """Apply unified hunks to a sparse original; never invent missing upstream lines."""
    folder = ROOT / 'prebuilt/sdl3/patches'
    files = {name: originals[name] for name in SDL_REVIEW_UNCHANGED_SOURCES
             if originals is not None and name in originals and Path(name).name in selected_sources}
    for name in (folder / 'series').read_text(encoding='utf-8').splitlines():
        if not name.strip() or name.startswith('#'):
            continue
        patch = (folder / name.strip()).read_text(encoding='utf-8')
        for section in re.split(r'^diff --git ', patch, flags=re.M)[1:]:
            match = re.search(r'^\+\+\+ b/(.+)$', section, re.M)
            if not match:
                continue
            filename = match[1]
            if Path(filename).name not in selected_sources:
                continue
            # 显式锁定仓验证直接从该路径的原始 blob 定位，支持合法的 hunk 行号偏移。
            if filename not in files and originals is not None:
                files[filename] = originals.get(filename, [])
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
                if originals is None and len(old) < start + count:
                    old.extend([None] * (start + count - len(old)))
                start = locate_hunk(old, before, start, cursor, f'{name}: {filename}:{start + 1}')
                output.extend(old[cursor:start])
                output.extend(after)
                cursor = start + count
            output.extend(old[cursor:])
            files[filename] = output
    # 对真实重放树按补丁的仓内路径核对；events、dynapi、video 等目录可有不同布局。
    # 有完整基线时连未被补丁触及的原文、行数一并核实。
    if applied_repo is not None:
        for name, lines in files.items():
            actual = Path(applied_repo) / name
            if not actual.is_file():
                raise ValueError(f'Applied SDL file missing: {actual}')
            actual_lines = actual.read_text(encoding='utf-8').splitlines()
            if originals is not None and len(lines) != len(actual_lines):
                raise ValueError(f'Applied SDL differs from test recipe: {name} line count')
            for index, line in enumerate(lines):
                if line is not None and (index >= len(actual_lines) or line != actual_lines[index]):
                    raise ValueError(f'Applied SDL differs from test recipe: {name}:{index+1}')
    return {Path(name).name: '\n'.join(line if line is not None else UNKNOWN for line in lines) + '\n'
            for name, lines in files.items()}


def originals_from_applied(applied_repo, scratch):
    """独立 CLI 可传已应用的普通源码目录。在自有输出旁的临时副本反推原文，无须另备 Git 仓。"""
    folder = ROOT / 'prebuilt/sdl3/patches'
    patches = [folder / name for line in (folder / 'series').read_text(encoding='utf-8').splitlines()
               if (name := line.strip()) and not name.startswith('#')]
    paths = sorted(set(SDL_REVIEW_UNCHANGED_SOURCES) | {name for patch in patches
                    for name in re.findall(r'^\+\+\+ b/(.+)$', patch.read_text(encoding='utf-8'), re.M)
                    if Path(name).name in SDL_DESKTOP_REVIEW_SOURCES})
    # 只回退正在核查的文件，原始输入目录不参与写操作；任一上下文不匹配直接失败。
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        private = Path(temporary)
        for name in paths:
            dest = (private / name).resolve()
            if not dest.is_relative_to(private.resolve()):
                raise ValueError(f'Patch path outside temporary directory: {name}')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(applied_repo) / name, dest)
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(private.resolve().parent))
        for patch in reversed(patches):
            subprocess.run(['git', 'apply', '--reverse',
                            *('--include=' + name for name in paths), str(patch)], cwd=private, env=env, check=True)
        return {name: (private / name).read_text(encoding='utf-8').splitlines()
                for name in paths if (private / name).is_file()}


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
    match = re.search(r'^(?:static )?(?:bool|void|int|SDL_DisplayID|SDL_MouseButtonFlags|SDL_GLContext|GLFWwindow\*|const SDL_DisplayMode \*)\s*' + re.escape(name) + r'\([^;{}]*\)\s*\{', source, re.M)
    if not match:
        raise ValueError(f'Production function missing: {name}')
    return block(source, match.start())


def generate_glfw_context(output):
    """独立抽取当前 GLFW 生产函数；SDL 全量补丁回归仍由原 generate 路径严格校验。"""
    glfw = (ROOT / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    production = '\n\n'.join(function(glfw, name) for name in
                             ['glfwGraphicsRestartRequired', 'recordGlfwEglFailure', 'clearEglContextOwnershipAfterDetach', 'clearEglTlsAfterPartialDetach',
                              'makeGlfwContextCurrent', 'glfwMakeContextCurrent', 'glfwOHOS_MakeContextCurrentChecked',
                              'glfwSwapBuffers', 'glfwSwapInterval'])
    template = (HOST / 'desktop_review/glfw_context.cpp.in').read_text(encoding='utf-8')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'glfw_context.cpp').write_text(template.replace('@PRODUCTION@', production),
                                            encoding='utf-8', newline='\n')
    print('GLFW context regression generated from current production functions; SDL recipe not evaluated')


def generate_sdl_phone_clipboard(output):
    """重建剪贴板补丁新增的完整 C/H 文件，测试直接编译其生产正文。"""
    sources = patch_sources(SDL_PHONE_CLIPBOARD_SOURCES)
    for name in SDL_PHONE_CLIPBOARD_SOURCES:
        if name not in sources or UNKNOWN in sources[name]:
            raise ValueError(f'SDL phone clipboard regression requires complete production source: {name}')
    output.mkdir(parents=True, exist_ok=True)
    for name in SDL_PHONE_CLIPBOARD_SOURCES:
        (output / name).write_text(sources[name], encoding='utf-8', newline='\n')


def generate(output, sdl_repo=None, *, originals=None):
    if sdl_repo is not None and originals is None:
        output.parent.mkdir(parents=True, exist_ok=True)
        originals = originals_from_applied(sdl_repo, output.parent)
    sdl = patch_sources(applied_repo=sdl_repo, originals=originals)
    glfw = (ROOT / 'entry/src/main/cpp/glfw/glfw_compat.cpp').read_text(encoding='utf-8')
    callbacks = (ROOT / 'entry/src/main/cpp/glfw/glfw_callbacks.cpp').read_text(encoding='utf-8')
    gl = sdl['SDL_openharmonyopengl.c']
    window = sdl['SDL_openharmonywindow.c']
    amcl = sdl['SDL_openharmonyamcl.c']
    desktop = sdl['SDL_amcldesktop.c']
    units = {
        'glfw_context': [function(glfw, name) for name in ['glfwGraphicsRestartRequired', 'recordGlfwEglFailure', 'clearEglContextOwnershipAfterDetach',
            'clearEglTlsAfterPartialDetach', 'makeGlfwContextCurrent', 'glfwMakeContextCurrent',
            'glfwOHOS_MakeContextCurrentChecked', 'glfwSwapBuffers', 'glfwSwapInterval']],
        'glfw_monitor': [function(callbacks, 'glfwOHOS_ApplyInitialMonitor')],
        'sdl_profile': [function(gl, name) for name in ['OPENHARMONY_GLES_NativeGlRequired',
            'OPENHARMONY_GLES_EnsureUsableProfile', 'OPENHARMONY_GLES_TryPinConfig']],
        'sdl_hide': [function(desktop, 'Presented'), function(desktop, 'OPENHARMONY_DesktopCommand'), function(window, 'OPENHARMONY_HideWindow')],
        'sdl_owner': [function(gl, 'OPENHARMONY_GLES_SetCurrentCache'), function(gl, 'OPENHARMONY_GLES_RestorePreviousBinding'),
                      function(amcl, 'OPENHARMONY_AMCL_CommitCurrentCache')],
    }
    fullscreen_state = re.search(r'^static struct \{\n[^}]+\} fullscreen_request;', desktop, re.M)
    if not fullscreen_state:
        raise ValueError('SDL fullscreen request state missing from production')
    units['sdl_fullscreen'] = [fullscreen_state[0]] + [function(desktop, name) for name in (
        'Presented', 'FullscreenMatches', 'FullscreenRequestBelongsTo', 'ObserveFullscreenCompletion',
        'RestoreConfirmedFullscreenMode', 'OPENHARMONY_DesktopFullscreen',
        'ReconcileFullscreen', 'SyncDesktopWindow', 'OPENHARMONY_DesktopPump',
    )] + [function(amcl, 'OPENHARMONY_GlobalMouseState')]
    fullscreen_public = ''
    display_changed_cases = ['', '']
    moved_cases = ['', '']
    if sdl_repo is not None:
        video = sdl['SDL_video.c']
        fullscreen_public = '#define SDL_REPLAYED_FULLSCREEN_API 1\n' + '\n\n'.join(function(video, name) for name in (
            'SDL_WindowUsesHostFullscreen', 'SDL_GetDisplayForWindow', 'SDL_GetWindowFullscreenMode',
            'SDL_UpdateFullscreenMode', 'SDL_SetWindowFullscreenMode', 'SDL_SetWindowFullscreen', 'SDL_SyncWindow',
            'DisplayModeChanged', 'SDL_SetDesktopDisplayMode', 'SDL_CheckWindowDisplayChanged',
            'SDL_OnWindowMoved', 'SDL_OnWindowDisplayChanged',
        ))
        # 事件系统只替换监听者/队列，两个事件的状态更新和回调分发取锁定 SDL 正文。
        window_events = sdl['SDL_windowevents.c']
        display_changed_cases = re.findall(
            r'^ +case SDL_EVENT_WINDOW_DISPLAY_CHANGED:\n(?:[^\n]*\n)*?^ +break;', window_events, re.M)
        moved_cases = re.findall(
            r'^ +case SDL_EVENT_WINDOW_MOVED:\n(?:[^\n]*\n)*?^ +break;', window_events, re.M)
        if len(display_changed_cases) != 2 or len(moved_cases) != 2:
            raise ValueError('SDL move/display changed update and dispatch unavailable')
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
    output.mkdir(parents=True, exist_ok=True)
    (output / 'graphics_runtime_abi.h').write_text(sdl['graphics_runtime_abi.h'], encoding='utf-8', newline='\n')
    (output / 'graphics_context_abi.h').write_text(sdl['graphics_context_abi.h'], encoding='utf-8', newline='\n')
    (output / 'sdl_aux_runtime_abi.h').write_text(sdl['sdl_aux_runtime_abi.h'], encoding='utf-8', newline='\n')
    (output / 'desktop_host_api.h').write_bytes((ROOT / 'entry/src/main/cpp/platform/desktop_host_api.h').read_bytes())
    for unit, parts in units.items():
        template = (HOST / 'desktop_review' / (unit + '.cpp.in')).read_text(encoding='utf-8')
        generated = template.replace('@PRODUCTION@', '\n\n'.join(parts))
        if unit == 'sdl_fullscreen':
            generated = generated.replace('@CORE_FULLSCREEN_API@', fullscreen_public)
            generated = generated.replace('@WINDOW_GEOMETRY_STATE@', '\n'.join((moved_cases[0], display_changed_cases[0])))
            generated = generated.replace('@WINDOW_GEOMETRY_DISPATCH@', '\n'.join((moved_cases[1], display_changed_cases[1])))
        (output / (unit + '.cpp')).write_text(generated, encoding='utf-8', newline='\n')
    print('Desktop review regression sources generated from current production and ordered SDL patches')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sdl-repo', type=Path)
    source_subset = parser.add_mutually_exclusive_group()
    source_subset.add_argument('--glfw-context-only', action='store_true',
                               help='仅抽取 GLFW 生产函数，不运行或宣称通过 SDL 补丁回归')
    source_subset.add_argument('--sdl-phone-clipboard-only', action='store_true',
                               help='从锁定补丁序列生成完整的 SDL 手机剪贴板实现')
    args = parser.parse_args()
    if args.glfw_context_only:
        if args.sdl_repo:
            parser.error('--glfw-context-only cannot validate --sdl-repo')
        generate_glfw_context(args.out)
    elif args.sdl_phone_clipboard_only:
        if args.sdl_repo:
            parser.error('--sdl-phone-clipboard-only cannot validate --sdl-repo')
        generate_sdl_phone_clipboard(args.out)
    else:
        generate(args.out, args.sdl_repo)
