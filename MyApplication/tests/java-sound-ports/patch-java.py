#!/usr/bin/env python3
"""精确修改锁定PortMixer两类的OHOS快照路径；其它平台保留原native调用和缓存语义。"""
import argparse,hashlib,json,re
from pathlib import Path

def once(text,old,new):
    if text.count(old)!=1:raise ValueError('expected unique Java anchor: '+old[:90])
    return text.replace(old,new,1)

INIT='''    private static void init() {
        int numDevices = nGetNumDevices();
        long generation = nGetGeneration();
        if (infos == null || infos.length != numDevices || cacheGeneration != generation) {
            // AMCL：先建完整同代次候选；JNI/OOM失败不发布半份数组。
            PortMixerInfo[] nextInfos = new PortMixerInfo[numDevices];
            PortMixer[] nextDevices = new PortMixer[numDevices];
            for (int i = 0; i < numDevices; i++) {
                nextInfos[i] = generation == 0 ? nNewPortMixerInfo(i) : nNewPortMixerInfoSnapshot(i, generation);
                if (nextInfos[i] == null) throw new IllegalStateException("Missing port descriptor");
            }
            // 真实端口身份未变化时复用Info/Mixer；同数量换设备仍按token更新，旧引用不改指向。
            if (generation != 0 && infos != null) {
                java.util.HashMap<Long, Integer> previous = new java.util.HashMap<Long, Integer>();
                for (int i = 0; i < infos.length; i++) previous.put(infos[i].nativeToken, i);
                for (int i = 0; i < nextInfos.length; i++) {
                    Integer old = previous.get(nextInfos[i].nativeToken);
                    if (old != null) { nextInfos[i] = infos[old]; nextDevices[i] = devices[old]; }
                }
            }
            // 以上全部可能抛异常的操作已完成，才更新现有Info的内部数组位置并发布。
            for (int i = 0; i < nextInfos.length; i++) nextInfos[i].index = i;
            infos = nextInfos; devices = nextDevices; cacheGeneration = generation;
        }
    }'''

INFO='''        private int index;
        // 非OHOS值为0；OHOS绑定具体设备身份，不能用重排后的数组下标打开别的端口。
        private final long nativeToken;

        private PortMixerInfo(int index, String name, String vendor, String description, String version) {
            this(index, 0, name, vendor, description, version);
        }

        private PortMixerInfo(int index, long nativeToken, String name, String vendor, String description, String version) {
            super("Port " + name, vendor, description, version);
            this.index = index;
            this.nativeToken = nativeToken;
        }

        long getNativeToken() { return nativeToken; }'''

def transform(provider,mixer):
    """新方法只有OHOS非零generation/token分支使用；旧平台native签名均不改变。"""
    provider=once(provider,'    private static PortMixer[] devices;','    private static PortMixer[] devices;\n\n    // AMCL：0代表上游平台；非0为OHOS实际设备快照代次。\n    private static long cacheGeneration;')
    provider,count=re.subn(r'(?ms)^    private static void init\(\) \{.*?^    \}',lambda _:INIT,provider,count=1)
    if count!=1:raise ValueError('missing init')
    for signature in ('    public Mixer.Info[] getMixerInfo() {','    public Mixer getMixer(Mixer.Info info) {'):
        provider=once(provider,signature+'\n        synchronized (PortMixerProvider.class) {',
                      signature+'\n        synchronized (PortMixerProvider.class) {\n            // OHOS无后台监听线程，只在显式枚举/取设备时刷新。\n            if (cacheGeneration != 0) init();')
    provider,count=re.subn(r'(?ms)^        private final int index;\n\n        private PortMixerInfo\(int index, String name, String vendor, String description, String version\) \{.*?^        \}',lambda _:INFO,provider,count=1)
    if count!=1:raise ValueError('missing Info constructor')
    provider=once(provider,'    private static native int nGetNumDevices();',
        '    private static native int nGetNumDevices();\n    private static native long nGetGeneration();\n    private static native PortMixerInfo nNewPortMixerInfoSnapshot(int mixerIndex, long generation);')
    if mixer.count('id = nOpen(getMixerIndex());')!=2:raise ValueError('unexpected nOpen count')
    mixer=mixer.replace('id = nOpen(getMixerIndex());','id = openPortMixer();')
    mixer=once(mixer,'    int getMixerIndex() {', '''    // AMCL：打开具体OHOS端口前由native重新确认token仍存在；拒绝下标复用/同id换设备。
    private long openPortMixer() throws LineUnavailableException {
        long token = ((PortMixerProvider.PortMixerInfo) getMixerInfo()).getNativeToken();
        return token == 0 ? nOpen(getMixerIndex()) : nOpenSnapshot(token);
    }

    int getMixerIndex() {''')
    mixer=once(mixer,'    private static native long nOpen(int mixerIndex) throws LineUnavailableException;',
        '    private static native long nOpen(int mixerIndex) throws LineUnavailableException;\n    private static native long nOpenSnapshot(long token) throws LineUnavailableException;')
    mixer=once(mixer,'                    mixer.open(this);\n                    try {',
        '                    try {\n                        mixer.open(this);')
    mixer=once(mixer,'''                    } catch (LineUnavailableException e) {
                        // release mixer resources for this line and then throw the exception
                        mixer.close(this);
                        throw e;
                    }''','''                    } catch (LineUnavailableException | RuntimeException | Error e) {
                        // AMCL：平台拒绝/分配或事件失败都撤回已保留资源，首异常不被清理覆盖。
                        try { setOpen(false); } catch (RuntimeException | Error cleanup) { if (cleanup != e) e.addSuppressed(cleanup); }
                        try { implClose(); } catch (RuntimeException | Error cleanup) { if (cleanup != e) e.addSuppressed(cleanup); }
                        try { mixer.close(this); } catch (RuntimeException | Error cleanup) { if (cleanup != e) e.addSuppressed(cleanup); }
                        throw e;
                    }''')
    return provider,mixer

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--major',choices=('8','17','21','25'),required=True)
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    reference=Path(__file__).with_name('reference');identity=json.loads((reference/'source.json').read_text())
    for row in identity['files']:
        if row['major']==args.major:assert hashlib.sha256((reference/row['file']).read_bytes()).hexdigest()==row['sha256']
    provider,mixer=transform((reference/args.major/'PortMixerProvider.java').read_text(),(reference/args.major/'PortMixer.java').read_text())
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
    for name,text in [('PortMixerProvider.java',provider),('PortMixer.java',mixer)]:
        (output/name).write_text(text,encoding='utf-8',newline='\n')
    print(json.dumps({'major':args.major,'output':str(output)}))

if __name__=='__main__':main()
