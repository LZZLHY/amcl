#!/usr/bin/env python3
"""锁定上游五个Java类的最小OHOS快照/线程生命周期分支；其它平台走原native路径。"""
import re


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('expected one source anchor: ' + old[:100])
    return text.replace(old, new, 1)


def class_locked(text, pattern):
    """静态Provider缓存由同一个Class锁保护，包含读取、重排和获取device的整个事务。"""
    expression = re.compile(r'(?ms)(' + pattern + r'\n)(.*?)(^    \})')
    text, count = expression.subn(lambda m: m[1] + '        synchronized (getClass()) {\n' +
        ''.join('    ' + line if line.strip() else line for line in m[2].splitlines(keepends=True)) +
        '        }\n' + m[3], text, count=1)
    if count != 1:
        raise ValueError('missing method for class lock: ' + pattern)
    return text


OHOS_INPUT = '''    // AMCL：OHOS输入线程绑定本次不复用的native handle；旧Receiver阻塞后返回，
    // 不能读取刚重新打开的新handle，也不能清除新线程的引用。
    private final java.util.concurrent.atomic.AtomicReference<Thread> ohosInputThread =
        new java.util.concurrent.atomic.AtomicReference<Thread>();

    private void openOhos() throws MidiUnavailableException {
        final long opened = nOpen(((AbstractMidiDeviceProvider.Info)getDeviceInfo()).getNativeIndex());
        if (opened == 0) throw new MidiUnavailableException("Unable to open OH_MIDI device");
        id = opened;
        Thread created = null;
        try {
            // 先完成平台启动再启动读取者；失败路径始终释放已经获得的native资源。
            nStart(opened);
            created = JSSecurityManager.createThread(new Runnable() {
                public void run() { runOhos(opened); }
            }, "Java Sound MidiInDevice Thread", false, -1, false);
            if (created == null) throw new OutOfMemoryError("MIDI input thread");
            ohosInputThread.set(created);
            created.start();
        } catch (MidiUnavailableException | RuntimeException | Error failure) {
            id = 0;
            ohosInputThread.compareAndSet(created, null);
            try { nStop(opened); } catch (RuntimeException | Error cleanup) { if (cleanup != failure) failure.addSuppressed(cleanup); }
            try { nClose(opened); } catch (RuntimeException | Error cleanup) { if (cleanup != failure) failure.addSuppressed(cleanup); }
            throw failure;
        }
    }

    private void closeOhos() {
        final long opened = id;
        id = 0;
        Throwable failure = null;
        try { super.implClose(); } catch (RuntimeException | Error problem) { failure = problem; }
        try { nStop(opened); } catch (RuntimeException | Error problem) { failure = appendFailure(failure, problem); }
        Thread reader = ohosInputThread.getAndSet(null);
        if (reader != null && reader != Thread.currentThread()) {
            try { reader.join(1000); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }
        // native持有者负责在途Receiver的真实寿命，join超时不能当作可直接free的证明。
        try { nClose(opened); } catch (RuntimeException | Error problem) { failure = appendFailure(failure, problem); }
        if (failure instanceof RuntimeException) throw (RuntimeException)failure;
        if (failure instanceof Error) throw (Error)failure;
    }

    private static Throwable appendFailure(Throwable first, Throwable next) {
        if (first == null) return next;
        if (first != next) first.addSuppressed(next);
        return first;
    }

    private void runOhos(final long opened) {
        try {
            while (id == opened && opened != 0) {
                nGetMessages(opened);
                if (id == opened) {
                    try { Thread.sleep(1); } catch (InterruptedException interrupted) { /* 下轮检查本次handle。 */ }
                }
            }
        } catch (RuntimeException | Error failure) {
            // 用户Receiver异常仍送到原线程uncaught handler；先撤回这个设备的资源，
            // 不误关已重新打开的handle，也不覆盖原始异常。
            if (id == opened) try { close(); } catch (RuntimeException | Error cleanup) { if (cleanup != failure) failure.addSuppressed(cleanup); }
            throw failure;
        } finally {
            ohosInputThread.compareAndSet(Thread.currentThread(), null);
        }
    }

'''


def transform(sources):
    """返回新的五份源码；输入保留完整上游许可正文，锚点变化立即失败而不是模糊替换。"""
    changed = dict(sources)
    base = sources['AbstractMidiDeviceProvider.java']
    base = once(base, '    final synchronized void readDeviceInfos() {', '''    final void readDeviceInfos() {
        synchronized (getClass()) { readDeviceInfosLocked(); }
    }

    private void readDeviceInfosLocked() {''')
    base = once(base, '        int oldNumDevices = (infos==null)?-1:infos.length;',
        '''        // AMCL：OHOS一次JNI返回同代次完整Info数组；null仍表示原上游平台。
        Info[] snapshot = getPlatformDeviceInfos();
        int oldNumDevices = (infos==null)?-1:infos.length;''')
    base = once(base, '        int newNumDevices = getNumDevices();', '        int newNumDevices = snapshot == null ? getNumDevices() : snapshot.length;')
    base = once(base, '        if (oldNumDevices != newNumDevices) {', '        if (snapshot != null || oldNumDevices != newNumDevices) {')
    base = once(base, '                Info newInfo = createInfo(i);', '                Info newInfo = snapshot == null ? createInfo(i) : snapshot[i];')
    base = once(base, '        private int index;', '''        private int index;
        // 数组位置可重排，真实端点token不可变；-1保留非OHOS的原索引合同。
        private final int nativeIndex;''')
    base = once(base, '''        Info(String name, String vendor, String description, String version, int index) {
            super(name, vendor, description, version);
            this.index = index;
        }''', '''        Info(String name, String vendor, String description, String version, int index) {
            this(name, vendor, description, version, index, -1);
        }

        Info(String name, String vendor, String description, String version, int index, int nativeIndex) {
            super(name, vendor, description, version);
            this.index = index;
            this.nativeIndex = nativeIndex;
        }

        final int getNativeIndex() { return nativeIndex < 0 ? index : nativeIndex; }
        final boolean isPlatformSnapshot() { return nativeIndex >= 0; }''')
    base = once(base, '                         && getName().equals(info.getName())',
        '                         && nativeIndex == info.nativeIndex\n                         && getName().equals(info.getName())')
    base = once(base, '    abstract int getNumDevices();', '''    // 普通平台继续使用原枚举与缓存；OHOS提供统一完整快照，数量相等也能识别换设备。
    Info[] getPlatformDeviceInfos() { return null; }

    abstract int getNumDevices();''')
    base = class_locked(base, r'    public final MidiDevice.Info\[\] getDeviceInfo\(\) \{')
    base = class_locked(base, r'    public final MidiDevice getDevice\((?:final )?MidiDevice.Info info\) \{')
    changed['AbstractMidiDeviceProvider.java'] = base
    for direction in ('In', 'Out'):
        name = 'Midi' + direction + 'DeviceProvider.java'
        provider = sources[name]
        provider = once(provider, '    private static native int nGetNumDevices();',
            '''    // AMCL：同一次返回真实端点标识及完整UTF-16名称；非OHOS native返回null。
    @Override
    Info[] getPlatformDeviceInfos() { return nGetDeviceInfos(); }

    private static native Info[] nGetDeviceInfos();
    private static native int nGetNumDevices();''')
        anchor = '        private final Class'
        pos = provider.index(anchor)
        end = provider.index('\n', pos)
        addition = '''

        private MidiDIRECTIONDeviceInfo(String name, String vendor, String description, String version,
                                       int index, int nativeIndex) {
            super(name, vendor, description, version, index, nativeIndex);
            this.providerClass = MidiDIRECTIONDeviceProvider.class;
        }'''.replace('DIRECTION', direction)
        provider = provider[:end] + addition + provider[end:]
        changed[name] = provider
    output = sources['MidiOutDevice.java']
    output = once(output, 'getDeviceInfo()).getIndex();', 'getDeviceInfo()).getNativeIndex();')
    changed['MidiOutDevice.java'] = output
    input_source = sources['MidiInDevice.java']
    input_source = once(input_source, '    private volatile Thread midiInThread;', '    private volatile Thread midiInThread;\n\n' + OHOS_INPUT)
    input_source = once(input_source, '    protected synchronized void implOpen() throws MidiUnavailableException {',
        '''    protected synchronized void implOpen() throws MidiUnavailableException {
        if (((AbstractMidiDeviceProvider.Info)getDeviceInfo()).isPlatformSnapshot()) { openOhos(); return; }''')
    input_source = once(input_source, '    protected synchronized void implClose() {',
        '''    protected synchronized void implClose() {
        if (((AbstractMidiDeviceProvider.Info)getDeviceInfo()).isPlatformSnapshot()) { closeOhos(); return; }''')
    changed['MidiInDevice.java'] = input_source
    return changed
