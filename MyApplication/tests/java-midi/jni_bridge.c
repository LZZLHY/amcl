/* 只在测试中通过RegisterNatives绑定同源生产JNI到真实四代上游类。平台API仍由
 * 生产dlopen/dlsym解析独立有状态测试库，不用类/符号存在性代替实际收发和生命周期。
 */
#include "../../entry/src/main/cpp/javasound/midi_jdk.c"
int amcl_jvm_is_embedded(void) { return getenv("AMCL_MIDI_TEST_EMBEDDED") != NULL; }
#ifndef AMCL_MIDI_TEST_NO_HOST
const AmclMidiCallbackAbiV1* amcl_javasound_midi_callbacks_v1(void) {
    const char* mode = getenv("AMCL_MIDI_TEST_EMBEDDED");
    static AmclMidiCallbackAbiV1 selected;
    selected = *amcl_midi_local_callbacks_v1();
    if (mode && !strcmp(mode, "bad-layout")) ++selected.layoutVersion;
    if (mode && !strcmp(mode, "foreign-callback")) {
        void* provider = dlopen("libohmidi.so", RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!provider) return NULL;
        selected.onReceived = (OH_MIDIDevice_OnReceived)dlsym(provider, "amcl_fake_foreign_received");
        dlclose(provider);
    }
    return &selected;
}
#endif
static jobjectArray old_zero(JNIEnv* env, jclass cls) {
    (void)cls; jclass info = (*env)->FindClass(env, "com/sun/media/sound/AbstractMidiDeviceProvider$Info");
    return info ? (*env)->NewObjectArray(env, 0, info, NULL) : NULL;
}
static void bind(JNIEnv* env, const char* name, JNINativeMethod* methods, jint count) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass cls = (*env)->FindClass(env, name);
    if (!cls) return;
    (*env)->RegisterNatives(env, cls, methods, count); (*env)->DeleteLocalRef(env, cls);
}
JNIEXPORT void JNICALL Java_com_sun_media_sound_MidiJavaTest_bind(JNIEnv* env, jclass cls) {
    (void)cls;
    JNINativeMethod inProvider[] = {{"nGetDeviceInfos", "()[Lcom/sun/media/sound/AbstractMidiDeviceProvider$Info;", (void*)Java_com_sun_media_sound_MidiInDeviceProvider_nGetDeviceInfos}};
    JNINativeMethod outProvider[] = {{"nGetDeviceInfos", "()[Lcom/sun/media/sound/AbstractMidiDeviceProvider$Info;", (void*)Java_com_sun_media_sound_MidiOutDeviceProvider_nGetDeviceInfos}};
    if (getenv("AMCL_MIDI_TEST_OLD_ZERO")) { inProvider[0].fnPtr = (void*)old_zero; outProvider[0].fnPtr = (void*)old_zero; }
    JNINativeMethod input[] = {
        {"nOpen","(I)J",(void*)Java_com_sun_media_sound_MidiInDevice_nOpen},
        {"nClose","(J)V",(void*)Java_com_sun_media_sound_MidiInDevice_nClose},
        {"nStart","(J)V",(void*)Java_com_sun_media_sound_MidiInDevice_nStart},
        {"nStop","(J)V",(void*)Java_com_sun_media_sound_MidiInDevice_nStop},
        {"nGetMessages","(J)V",(void*)Java_com_sun_media_sound_MidiInDevice_nGetMessages},
        {"nGetTimeStamp","(J)J",(void*)Java_com_sun_media_sound_MidiInDevice_nGetTimeStamp}
    };
    JNINativeMethod output[] = {
        {"nOpen","(I)J",(void*)Java_com_sun_media_sound_MidiOutDevice_nOpen},
        {"nClose","(J)V",(void*)Java_com_sun_media_sound_MidiOutDevice_nClose},
        {"nSendShortMessage","(JIJ)V",(void*)Java_com_sun_media_sound_MidiOutDevice_nSendShortMessage},
        {"nSendLongMessage","(J[BIJ)V",(void*)Java_com_sun_media_sound_MidiOutDevice_nSendLongMessage},
        {"nGetTimeStamp","(J)J",(void*)Java_com_sun_media_sound_MidiOutDevice_nGetTimeStamp}
    };
    bind(env, "com/sun/media/sound/MidiInDeviceProvider", inProvider, 1);
    bind(env, "com/sun/media/sound/MidiOutDeviceProvider", outProvider, 1);
    bind(env, "com/sun/media/sound/MidiInDevice", input, sizeof(input)/sizeof(input[0]));
    bind(env, "com/sun/media/sound/MidiOutDevice", output, sizeof(output)/sizeof(output[0]));
}
JNIEXPORT jlong JNICALL Java_com_sun_media_sound_MidiJavaTest_control(JNIEnv* env, jclass cls, jint mode) {
    (void)cls; void* provider = dlopen("libohmidi.so", RTLD_NOW | RTLD_LOCAL);
    if (!provider) { throw_midi(env, AMCL_MIDI_ABI, 0); return -1; }
    int64_t (*control)(int) = (int64_t(*)(int))dlsym(provider, "amcl_midi_fake_control");
    if (!control) { dlclose(provider); throw_midi(env, AMCL_MIDI_ABI, 0); return -1; }
    int64_t result = control(mode); dlclose(provider); return (jlong)result;
}
