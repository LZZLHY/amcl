#!/usr/bin/env python3
"""从清单锁定的四代原文生成 OHOS DAUDIO 候选补丁，不修改正式 series 或活动 JDK。

上游原文由独立获取清单逐 SHA 核验，再重放本仓原 0011。平台 C 源只有一个事实源；
Java 改动仅补 start/stop/close 失败时必要的状态与资源清理，不复制整类替代上游。
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def once(text, old, new):
    """锚点必须唯一，避免上游漂移后碰巧替换另一段同名代码。"""
    if text.count(old) != 1:
        raise ValueError('Expected unique anchor: ' + old[:140])
    return text.replace(old, new, 1)


def method(text, signature, body, indent='    '):
    """只替换指定缩进的一整个方法；内部嵌套块具有更深缩进，不能被当作方法结束。"""
    pattern = r'(?ms)^' + re.escape(indent + signature) + r' \{.*?^' + re.escape(indent) + r'\}'
    result, count = re.subn(pattern, body.rstrip(), text, count=1)
    if count != 1:
        raise ValueError('Missing method: ' + signature)
    return result


START = '''    public final void start() {
        // AMCL：implStart 失败时回滚 mixer 和可能已部分开始的 line，首异常不被清理覆盖。
        synchronized (mixer) {
            if (isOpen() && !isStartedRunning()) {
                mixer.start(this);
                try {
                    implStart();
                    running = true;
                } catch (RuntimeException | Error failure) {
                    try { implStop(); } catch (RuntimeException | Error cleanup) {
                        amclCollect(failure, cleanup);
                    }
                    try { mixer.stop(this); } catch (RuntimeException | Error cleanup) {
                        amclCollect(failure, cleanup);
                    }
                    running = false;
                    try { setActive(false); setStarted(false); }
                    catch (RuntimeException | Error cleanup) { amclCollect(failure, cleanup); }
                    synchronized (lock) { lock.notifyAll(); }
                    throw failure;
                }
            }
        }
        synchronized (lock) { lock.notifyAll(); }
    }'''

STOP = '''    public final void stop() {
        // AMCL：底层失败仍完成 Java 停止状态/唤醒和 mixer 所有权清理，再向调用者报首错。
        Throwable failure = null;
        synchronized (mixer) {
            if (isOpen() && isStartedRunning()) {
                try { implStop(); } catch (RuntimeException | Error error) { failure = error; }
                try { mixer.stop(this); } catch (RuntimeException | Error error) {
                    failure = amclCollect(failure, error);
                } finally { running = false; }
                try {
                    setActive(false);
                    setStarted(false);
                } catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
            }
        }
        synchronized (lock) { lock.notifyAll(); }
        amclRethrow(failure);
    }'''

CLOSE = '''    public final void close() {
        // AMCL：stop/事件/native close 任一步失败均不得跳过后续释放；重复 close 保持无操作。
        Throwable failure = null;
        synchronized (mixer) {
            if (isOpen()) {
                try { stop(); } catch (RuntimeException | Error error) { failure = error; }
                try { setOpen(false); } catch (RuntimeException | Error error) {
                    failure = amclCollect(failure, error);
                }
                try { implClose(); } catch (RuntimeException | Error error) {
                    failure = amclCollect(failure, error);
                }
                try { mixer.close(this); } catch (RuntimeException | Error error) {
                    failure = amclCollect(failure, error);
                } finally {
                    running = false;
                    format = defaultFormat;
                    bufferSize = defaultBufferSize;
                }
            }
        }
        amclRethrow(failure);
    }'''

HELPERS = '''
    // AMCL：只汇集本来允许向外传播的未受检异常，正常路径没有异常对象分配。
    static Throwable amclCollect(Throwable first, Throwable next) {
        if (first == null) return next;
        if (first != next) first.addSuppressed(next);
        return first;
    }

    // 所有输入仅来自 RuntimeException|Error 的 catch，不能从 native 偷抛未声明受检异常。
    static void amclRethrow(Throwable failure) {
        if (failure instanceof RuntimeException) throw (RuntimeException) failure;
        if (failure != null) throw (Error) failure;
    }
'''

DIRECT_STOP = '''        void implStop() {
            // AMCL：即使权限/平台停止失败，仍撤销 monitor、doIO 并唤醒写入线程。
            Throwable failure = null;
            try { if (!isSource) JSSecurityManager.checkRecordPermission(); }
            catch (RuntimeException | Error error) { failure = error; }
            try { if (monitoring) getEventDispatcher().removeLineMonitor(this); }
            catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
            finally { monitoring = false; }
            try {
                synchronized (lockNative) { nStop(id, isSource); }
            } catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
            finally {
                synchronized (lock) {
                    doIO = false;
                    setActive(false);
                    try { setStarted(false); }
                    catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
                    finally { lock.notifyAll(); }
                }
                stoppedWritten = false;
            }
            amclRethrow(failure);
        }'''

DIRECT_CLOSE = '''        void implClose() {
            // AMCL：先收回 Java id，再释放原 handle；清理异常不使 native 所有权重复释放。
            Throwable failure = null;
            try { if (!isSource) JSSecurityManager.checkRecordPermission(); }
            catch (RuntimeException | Error error) { failure = error; }
            try { if (monitoring) getEventDispatcher().removeLineMonitor(this); }
            catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
            finally { monitoring = false; }
            doIO = false;
            long oldID = id;
            id = 0;
            try {
                synchronized (lockNative) { nClose(oldID, isSource); }
            } catch (RuntimeException | Error error) { failure = amclCollect(failure, error); }
            finally {
                bytePosition = 0;
                softwareConversionSize = 0;
            }
            amclRethrow(failure);
        }'''


def java_lifecycle(data_line, abstract_line, direct):
    """状态提交次序保留成功行为；失败时先完成必要清理，事件失败不得保持假 open/started。"""
    data_line = method(data_line, 'public final void start()', START)
    data_line = method(data_line, 'public final void stop()', STOP)
    data_line = method(data_line, 'public final void close()', CLOSE)
    data_line = once(data_line, '    abstract void implOpen(', HELPERS + '\n    abstract void implOpen(')
    for variable, name in [('started', 'data'), ('open', 'abstract')]:
        text = data_line if name == 'data' else abstract_line
        old = '        long position = getLongFramePosition();'
        new = '''        long position;
        // AMCL：位置查询失败仍提交关闭/停止状态；成功时事件位置与上游完全相同。
        try { position = getLongFramePosition(); }
        catch (RuntimeException | Error failure) {
            synchronized (this) { this.VAR = VAR; }
            throw failure;
        }'''.replace('VAR', variable)
        text = once(text, old, new)
        if name == 'data': data_line = text
        else: abstract_line = text
    stop, close = DIRECT_STOP, DIRECT_CLOSE
    if 'JSSecurityManager.checkRecordPermission()' not in direct:
        # JDK25 已删除 SecurityManager，不能为共享模板重新引入已退役的 API。
        permission = '''            try { if (!isSource) JSSecurityManager.checkRecordPermission(); }
            catch (RuntimeException | Error error) { failure = error; }
'''
        stop = once(stop, permission, '')
        close = once(close, permission, '')
    direct = method(direct, 'void implStop()', stop, '        ')
    direct = method(direct, 'void implClose()', close, '        ')
    return data_line, abstract_line, direct


def mixer_lifecycle(text):
    """一个 line 停止失败不能截断其它 line 的关闭；最后 line 移除时不递归关闭同 mixer。"""
    text = once(text, '    private boolean manuallyOpened = false;', '''    private boolean manuallyOpened = false;

    // AMCL：只用于同一同步 close 栈的递归保护，不跨线程引入新的所有权模型。
    private boolean amclClosing;''')
    text = once(text, 'sourceLines.isEmpty() && targetLines.isEmpty() && !manuallyOpened',
                'sourceLines.isEmpty() && targetLines.isEmpty() && !manuallyOpened && !amclClosing')
    return method(text, 'public final synchronized void close()', '''    public final synchronized void close() {
        if (amclClosing) return;
        Throwable failure = null;
        amclClosing = true;
        try {
            if (isOpen()) {
                // 即使一个 line 报错，仍处理已复制列表中的其余 native 资源。
                for (Line line : getSourceLines()) {
                    try { line.close(); } catch (RuntimeException | Error error) {
                        failure = AbstractDataLine.amclCollect(failure, error);
                    }
                }
                for (Line line : getTargetLines()) {
                    try { line.close(); } catch (RuntimeException | Error error) {
                        failure = AbstractDataLine.amclCollect(failure, error);
                    }
                }
                try { implClose(); } catch (RuntimeException | Error error) {
                    failure = AbstractDataLine.amclCollect(failure, error);
                }
                try { setOpen(false); } catch (RuntimeException | Error error) {
                    failure = AbstractDataLine.amclCollect(failure, error);
                }
            }
        } finally {
            manuallyOpened = false;
            amclClosing = false;
        }
        AbstractDataLine.amclRethrow(failure);
    }''')


def jni_bridge(text):
    """仅后端构建检查真实状态；位置/close 仍能在失败后进行必要清理。"""
    anchor = '#include "com_sun_media_sound_DirectAudioDevice.h"'
    helper = '''
#if defined(AMCL_OHOS_DAUDIO)
#include "ohos_daudio.h"
/* 返回值丢弃会让 Java 提交并不存在的运行状态；只传播未受检状态异常。
 * stop 的异常由 Java 生命周期 finally 收口，close 自身不再阻断资源释放。 */
static void amcl_daudio_error(JNIEnv *env, int error, const char *operation) {
    if (error && !(*env)->ExceptionCheck(env)) {
        char message[128];
        snprintf(message, sizeof(message), "OHOS JavaSound %s failed (code=%d)", operation, error);
        JNU_ThrowByName(env, "java/lang/IllegalStateException", message);
    }
}
static void amcl_daudio_check(JNIEnv *env, void *handle, const char *operation) {
    amcl_daudio_error(env, AMCL_DAudio_GetError(handle), operation);
}
#endif
'''
    text = once(text, anchor, anchor + '\n' + helper)
    # 原来 OHOS DAUDIO 关闭时从未走此 callback；开启后每次 Java 调用都必须检查异常，
    # 后续格式枚举保留首个 pending exception，不再继续普通 JNI 调用。
    call = '    (*creator->env)->CallStaticVoidMethod(creator->env, creator->directAudioDeviceClass,'
    text = once(text, call, '''#if defined(AMCL_OHOS_DAUDIO)
    if ((*creator->env)->ExceptionCheck(creator->env)) return;
#endif
''' + call)
    end = '                                          channels, sampleRate, encoding, isSigned, bigEndian);'
    text = once(text, end, end + '''
#if defined(AMCL_OHOS_DAUDIO)
    if ((*creator->env)->ExceptionCheck(creator->env)) return;
#endif''')
    for op in ('Start', 'Stop', 'Flush'):
        old = '        DAUDIO_' + op + '(info->handle, (int) isSource);'
        new = '''#if defined(AMCL_OHOS_DAUDIO)
        if (!DAUDIO_OP(info->handle, (int) isSource)) amcl_daudio_check(env, info->handle, "OP");
#else
OLD
#endif'''.replace('OP', op).replace('OLD', old)
        text = once(text, old, new)
    old = '        ret = DAUDIO_StillDraining(info->handle, (int) isSource)?TRUE:FALSE;'
    text = once(text, old, old + '\n#if defined(AMCL_OHOS_DAUDIO)\n        amcl_daudio_check(env, info->handle, "drain");\n#endif')
    old = '''        DAUDIO_Close(info->handle, (int) isSource);
        if (info->conversionBuffer) {
            free(info->conversionBuffer);
        }
        free(info);'''
    new = '''#if defined(AMCL_OHOS_DAUDIO)
        /* 先完成 native 所有权释放，再报告 Release 错误；不能在 free 后读 handle。 */
        int closeError = AMCL_DAudio_Close(info->handle);
#else
        DAUDIO_Close(info->handle, (int) isSource);
#endif
        if (info->conversionBuffer) {
            free(info->conversionBuffer);
        }
        free(info);
#if defined(AMCL_OHOS_DAUDIO)
        amcl_daudio_error(env, closeError, "Close");
#endif'''
    text = once(text, old, new)
    old = '''        ret = DAUDIO_Write(info->handle, (INT8*) convertedData, (int) len);

        // do not commit the native array
        (*env)->ReleaseByteArrayElements(env, jData, (jbyte*) data, JNI_ABORT);'''
    text = once(text, old, old + '''
#if defined(AMCL_OHOS_DAUDIO)
        /* 只传播锁存的真实平台错误；正常 partial/停止返回保持原义。先释放数组，
         * 避免错误后 SoftAudioPusher 把0当成功而失去设备节拍持续空转。 */
        if (ret < 0) amcl_daudio_check(env, info->handle, "write");
#endif''')
    return text


def modern_build(text):
    """只有实际编译旗标含 OHOS 定义才选择新后端；其它平台恢复上游能力。"""
    for flag in ('USE_PORTS', 'USE_DAUDIO', 'USE_PLATFORM_MIDI_OUT', 'USE_PLATFORM_MIDI_IN'):
        text = once(text, '-D' + flag + '=FALSE', '-D' + flag + '=TRUE')
    anchor = '  # OHOS：硬件能力未实现时使用共享 JNI 的无设备分支，排除 ALSA 平台单元。'
    block = '''  # AMCL：依据真实目标编译旗标选择 OHOS，仅平台后端切换，Java/JNI 层仍用上游实现。
  LIBJSOUND_EXCLUDE_FILES := ohos_daudio.c
  LIBJSOUND_LINUX_LIBS := $(ALSA_LIBS)
  ifneq ($(findstring -D__OHOS__,$(CFLAGS_JDKLIB)), )
    LIBJSOUND_CFLAGS := $(filter-out -DUSE_PORTS=TRUE -DUSE_PLATFORM_MIDI_OUT=TRUE -DUSE_PLATFORM_MIDI_IN=TRUE,$(LIBJSOUND_CFLAGS)) \\
        -DUSE_PORTS=FALSE -DUSE_PLATFORM_MIDI_OUT=FALSE -DUSE_PLATFORM_MIDI_IN=FALSE -DAMCL_OHOS_DAUDIO=1
    LIBJSOUND_EXCLUDE_FILES := $(notdir $(wildcard $(TOPDIR)/src/java.desktop/linux/native/libjsound/PLATFORM_API_LinuxOS_ALSA*.c))
    LIBJSOUND_LINUX_LIBS := -lohaudio
  endif'''
    text = once(text, anchor, block)
    text = once(text, 'EXCLUDE_FILES := $(notdir $(wildcard $(TOPDIR)/src/java.desktop/linux/native/libjsound/PLATFORM_API_LinuxOS_ALSA*.c)),',
                'EXCLUDE_FILES := $(LIBJSOUND_EXCLUDE_FILES),')
    return once(text, 'LIBS_linux :=,', 'LIBS_linux := $(LIBJSOUND_LINUX_LIBS),')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-manifest', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    if not args.out.is_absolute() or out.is_relative_to(repo):
        raise ValueError('Candidate output must be an absolute external directory')
    out.mkdir(parents=True, exist_ok=False)
    records = json.loads(args.source_manifest.read_text(encoding='utf-8'))['sources']
    locked = json.loads((repo / 'prebuilt/jdk/build-inputs.json').read_text())['runtimes']
    receipt = {'recordedAt': datetime.datetime.now().astimezone().isoformat(), 'majors': []}
    for major, definition in locked.items():
        tree = out / major; tree.mkdir()
        for entry in [e for e in records if e['major'] == major]:
            if entry['commit'] != definition['commit']:
                raise ValueError('Source commit mismatch')
            data = Path(entry['savedPath']).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError('Source SHA mismatch: ' + entry['savedPath'])
            target = tree / entry['path']; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        patch = repo / 'prebuilt/jdk' / major / 'patches' / (
            '0011-ohos-java-sound-capability.patch' if major == '8' else '0011-ohos-javasound-capabilities.patch')
        env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(out)}
        command = ['git', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', 'apply']
        subprocess.run([*command, '--check', str(patch)], cwd=tree, env=env, check=True)
        subprocess.run([*command, str(patch)], cwd=tree, env=env, check=True)
        before = {p.relative_to(tree).as_posix(): p.read_text(encoding='utf-8') for p in tree.rglob('*') if p.is_file()}
        native = 'jdk/src/share/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/native/libjsound/'
        platform = 'jdk/src/solaris/native/com/sun/media/sound/' if major == '8' else 'src/java.desktop/linux/native/libjsound/'
        java = 'jdk/src/share/classes/com/sun/media/sound/' if major == '8' else 'src/java.desktop/share/classes/com/sun/media/sound/'
        after = dict(before)
        after[native + 'DirectAudioDevice.c'] = jni_bridge(before[native + 'DirectAudioDevice.c'])
        paths = [java + n for n in ('AbstractDataLine.java', 'AbstractLine.java', 'DirectAudioDevice.java')]
        revised = java_lifecycle(*(before[p] for p in paths))
        after.update(zip(paths, revised))
        after[java + 'AbstractMixer.java'] = mixer_lifecycle(before[java + 'AbstractMixer.java'])
        after[platform + 'ohos_daudio.c'] = (repo / 'entry/src/main/cpp/javasound/ohos_daudio.c').read_text(encoding='utf-8')
        after[native + 'ohos_daudio.h'] = (repo / 'entry/src/main/cpp/javasound/ohos_daudio.h').read_text(encoding='utf-8')
        if major != '8':
            path = 'make/modules/java.desktop/Lib.gmk'; after[path] = modern_build(before[path])
        else:
            path = native + 'Platform.c'
            after[path] = before[path].replace('#ifdef __MUSL__', '#if defined(AMCL_OHOS_DAUDIO)')
            after[path] = once(after[path], '    /* JDK8 的库位掩码为零表示该硬件功能不可用，避免触达不存在的 native provider。 */\n    return 0;',
                '    /* AMCL：DAUDIO 真实位于主 libjsound；尚未实现的 MIDI/Ports 不伪装设备。 */\n    return feature == com_sun_media_sound_Platform_FEATURE_DIRECT_AUDIO ?\n        com_sun_media_sound_Platform_LIB_MAIN : 0;')
            path = 'jdk/make/lib/SoundLibraries.gmk'
            after[path] = once(before[path], '  EXTRA_SOUND_JNI_LIBS += jsoundalsa\n  LIBJSOUND_CFLAGS += -DX_PLATFORM=X_LINUX', '''  LIBJSOUND_CFLAGS += -DX_PLATFORM=X_LINUX
  # AMCL：真实 OHOS 编译只切换 DAUDIO 平台实现，不建立依赖 ALSA 的额外库。
  ifneq ($(findstring -D__OHOS__,$(CFLAGS_JDKLIB)), )
    LIBJSOUND_CFLAGS += -DUSE_DAUDIO=TRUE -DUSE_PORTS=FALSE \\
        -DUSE_PLATFORM_MIDI_IN=FALSE -DUSE_PLATFORM_MIDI_OUT=FALSE -DAMCL_OHOS_DAUDIO=1
    LIBJSOUND_SRC_FILES += $(LIBJSOUND_DAUDIOFILES) ohos_daudio.c
    LIBJSOUND_OHOS_LIBS := -lohaudio
  else
    EXTRA_SOUND_JNI_LIBS += jsoundalsa
  endif''')
            after[path] = once(after[path], 'LDFLAGS_SUFFIX_posix := -ljava -ljvm,', 'LDFLAGS_SUFFIX_posix := -ljava -ljvm $(LIBJSOUND_OHOS_LIBS),')
            # 经典 libjsound 的现有 map 已包含 DAUDIO JNI；若上游删去，显式停止而非漏导出。
            if 'Java_com_sun_media_sound_DirectAudioDevice_nOpen' not in before['jdk/make/mapfiles/libjsound/mapfile-vers']:
                raise ValueError('JDK8 libjsound map lacks DAUDIO JNI; explicit export patch required')
        delta = []
        for name, content in sorted(after.items()):
            if before.get(name) == content: continue
            target = tree / name; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding='utf-8', newline='\n')
            delta.extend(difflib.unified_diff(before.get(name, '').splitlines(True), content.splitlines(True),
                fromfile='a/' + name if name in before else '/dev/null', tofile='b/' + name))
        candidate = out / ('jdk' + major + '-ohos-daudio.patch')
        candidate.write_text(''.join(delta), encoding='utf-8', newline='\n')
        subprocess.run([*command, '--reverse', '--check', str(candidate)], cwd=tree, env=env, check=True)
        receipt['majors'].append({'major': major, 'patch': str(candidate),
            'sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'sourceCommit': definition['commit']})
        print('PASS generated and reverse-checked JDK ' + major, flush=True)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
