#!/usr/bin/env python3
"""在锁定原文上逐份重放0001..0026，再生成Ports0027草稿并逐字节验证重放。
不写series，不改活跃音频/MIDI配方；共享Makefile和8显式导出表只写进本模块新补丁。
"""
import argparse,difflib,hashlib,importlib.util,json,re,shutil,subprocess,sys
from datetime import datetime
from pathlib import Path

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def once(text,old,new):
    if text.count(old)!=1:raise ValueError('expected unique build anchor: '+old[:100])
    return text.replace(old,new,1)

def main():
    sys.dont_write_bytecode=True
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--write-patches',action='store_true')
    args=parser.parse_args();tests=Path(__file__).resolve().parent;root=tests.parents[1]
    output=args.output.resolve()
    if root==output or root in output.parents:raise ValueError('output must be outside source checkout')
    output.mkdir(parents=True,exist_ok=False)
    reference=tests/'reference';records=json.loads((reference/'source.json').read_text())['files']
    for row in records:assert sha(reference/row['file'])==row['sha256'],row['file']
    spec=importlib.util.spec_from_file_location('ports_java_patch',tests/'patch-java.py')
    patcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(patcher)
    native=root/'entry/src/main/cpp/javasound';names=('ports_ohos.c','ports_ohos.h','ports_jni.c')
    identities={name:sha(native/name) for name in names}
    receipt={'schemaVersion':1,'startedAt':datetime.now().astimezone().isoformat(),
             'scope':'four locked-source patch replays; full JDK and target device qualification remain separate',
             'nativeInputs':identities,'majors':[]}
    for major in ('8','17','21','25'):
        work=output/major;before=work/'before';after=work/'after';before.mkdir(parents=True)
        selected=[row for row in records if row['major']==major];paths={row['path'] for row in selected}
        for row in selected:
            target=before/row['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(reference/row['file'],target)
        patchdir=root/'prebuilt/jdk'/major/'patches'
        predecessors=[]
        listed=[line.strip() for line in (patchdir/'series').read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#') and int(line[:4])<=26]
        midi='0026-ohos-javasound-native-midi.patch'
        if midi not in listed:listed.append(midi)
        for name in listed:
            patch=patchdir/name;identity=sha(patch)
            predecessors.append({'name':name,'sha256':identity})
            included=sorted(paths&set(re.findall(r'^\+\+\+ b/(.+)$',patch.read_text(),re.M)))
            if included:
                argv=['git','-c','core.autocrlf=false','apply','--whitespace=nowarn',*['--include='+p for p in included],str(patch)]
                result=subprocess.run(argv,cwd=before,capture_output=True)
                (work/(name+'.apply.log')).write_bytes(result.stdout+result.stderr)
                if result.returncode:raise RuntimeError('predecessor apply failed '+major+'/'+name)
            assert sha(patch)==identity,'predecessor changed during replay'
        shutil.copytree(before,after)
        java='jdk/src/share/classes/com/sun/media/sound' if major=='8' else 'src/java.desktop/share/classes/com/sun/media/sound'
        provider,mixer=patcher.transform((after/java/'PortMixerProvider.java').read_text(),(after/java/'PortMixer.java').read_text())
        for name,text in [('PortMixerProvider.java',provider),('PortMixer.java',mixer)]:
            (after/java/name).write_text(text,encoding='utf-8',newline='\n')
        share='jdk/src/share/native/com/sun/media/sound' if major=='8' else 'src/java.desktop/share/native/libjsound'
        generic=after/share/'PortMixerProvider.c'
        generic.write_text(generic.read_text()+'''
/* AMCL：非OHOS沿用原平台端口索引/缓存；0只选择旧实现，不表示系统零设备。
 * OHOS排除本编译单元，ports_jni.c返回真实快照代次和稳定设备token。 */
JNIEXPORT jlong JNICALL Java_com_sun_media_sound_PortMixerProvider_nGetGeneration(JNIEnv *env, jclass cls) {
    (void)env; (void)cls; return 0;
}
''',encoding='utf-8',newline='\n')
        target_native='jdk/src/solaris/native/com/sun/media/sound' if major=='8' else 'src/java.desktop/linux/native/libjsound'
        (after/target_native).mkdir(parents=True,exist_ok=True)
        for name in names:
            data=(native/name).read_bytes()
            if b'\r' in data:raise ValueError('native source must be LF: '+name)
            (after/target_native/name).write_bytes(data)
        buildpath='jdk/make/lib/SoundLibraries.gmk' if major=='8' else 'make/modules/java.desktop/Lib.gmk'
        build=(after/buildpath).read_text()
        if major=='8':
            build=once(build,'-DUSE_DAUDIO=TRUE -DUSE_PORTS=FALSE','-DUSE_DAUDIO=TRUE -DUSE_PORTS=TRUE')
            anchor='    LIBJSOUND_SRC_FILES += $(LIBJSOUND_DAUDIOFILES) ohos_daudio.c midi_api.c midi_core.c midi_stream.c midi_ump.c midi_jdk.c'
            build=once(build,anchor,anchor+' ports_ohos.c ports_jni.c')
            platform=after/share/'Platform.c';text=platform.read_text()
            text=once(text,'    /* AMCL：DAUDIO 真实位于主 libjsound；尚未实现的 MIDI/Ports 不伪装设备。 */',
                      '    /* AMCL：DAUDIO、MIDI及真实设备Ports的JNI都位于主libjsound，各自平台能力独立。 */')
            anchor='    if (feature == com_sun_media_sound_Platform_FEATURE_MIDIIO) return com_sun_media_sound_Platform_LIB_MAIN;'
            text=once(text,anchor,anchor+'\n    if (feature == com_sun_media_sound_Platform_FEATURE_PORTS) return com_sun_media_sound_Platform_LIB_MAIN;')
            platform.write_text(text,encoding='utf-8',newline='\n')
            # 8的local:*会隐藏新增JNI；主jsound导出全部OHOS入口，ALSA只需要兼容0代次入口。
            for library in ('libjsound','libjsoundalsa'):
                mapfile=after/'jdk/make/mapfiles'/library/'mapfile-vers';text=mapfile.read_text()
                added=['Java_com_sun_media_sound_PortMixerProvider_nGetGeneration']
                if library=='libjsound':added+=['Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot','Java_com_sun_media_sound_PortMixer_nOpenSnapshot']
                anchor='            Java_com_sun_media_sound_PortMixerProvider_nGetNumDevices;'
                text=once(text,anchor,anchor+''.join('\n            '+symbol+';' for symbol in added))
                mapfile.write_text(text,encoding='utf-8',newline='\n')
        else:
            anchor='  LIBJSOUND_EXCLUDE_FILES := ohos_daudio.c midi_api.c midi_core.c midi_stream.c midi_ump.c midi_jdk.c'
            build=once(build,anchor,anchor+' ports_ohos.c ports_jni.c')
            build=once(build,'-DUSE_PORTS=FALSE -DUSE_PLATFORM_MIDI_OUT=TRUE','-DUSE_PORTS=TRUE -DUSE_PLATFORM_MIDI_OUT=TRUE')
            anchor='    LIBJSOUND_EXCLUDE_FILES := $(notdir $(wildcard $(TOPDIR)/src/java.desktop/linux/native/libjsound/PLATFORM_API_LinuxOS_ALSA*.c)) MidiInDevice.c MidiOutDevice.c MidiInDeviceProvider.c MidiOutDeviceProvider.c PlatformMidi.c'
            build=once(build,anchor,anchor+' PortMixer.c PortMixerProvider.c')
        (after/buildpath).write_text(build,encoding='utf-8',newline='\n')
        changes=[]
        for path in sorted(p.relative_to(after).as_posix() for p in after.rglob('*') if p.is_file()):
            old=(before/path).read_text(encoding='utf-8') if (before/path).is_file() else ''
            new=(after/path).read_text(encoding='utf-8')
            if old!=new:changes+=difflib.unified_diff(old.splitlines(True),new.splitlines(True),
                'a/'+path if (before/path).is_file() else '/dev/null','b/'+path)
        name='0027-ohos-javasound-device-ports.patch';patch=work/name
        patch.write_text(''.join(changes),encoding='utf-8',newline='\n')
        replay=work/'replay';shutil.copytree(before,replay)
        result=subprocess.run(['git','-c','core.autocrlf=false','apply','--whitespace=nowarn',str(patch)],cwd=replay,capture_output=True)
        (work/'candidate-replay.log').write_bytes(result.stdout+result.stderr)
        if result.returncode:raise RuntimeError('candidate replay failed '+major)
        for file in after.rglob('*'):
            if file.is_file():assert sha(file)==sha(replay/file.relative_to(after)),str(file)
        if args.write_patches:shutil.copyfile(patch,patchdir/name)
        receipt['majors'].append({'major':major,'patch':str(patch),'patchSha256':sha(patch),
            'predecessors':predecessors,'postimage':{p.relative_to(after).as_posix():sha(p) for p in after.rglob('*') if p.is_file()}})
        print('PASS Ports 0027 exact replay '+major,flush=True)
    assert identities=={name:sha(native/name) for name in names},'production source changed during replay'
    receipt['finishedAt']=datetime.now().astimezone().isoformat()
    (output/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
