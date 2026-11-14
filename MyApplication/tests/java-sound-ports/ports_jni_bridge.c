/* 宿主资格用RegisterNatives连接真实补后PortMixer类与同一生产JNI函数。
 * 不伪装产品装载：结果明确标记此绑定是测试注入；目标JDK链接/装载仍另验。 */
#include "../../entry/src/main/cpp/javasound/ports_jni.c"
#include "ports_fake_device.h"

JNIEXPORT void JNICALL Java_com_sun_media_sound_PortsJavaTest_setScenario(JNIEnv*env,jclass cls,jint scenario)
{ (void)env;(void)cls;ports_fake_scenario(scenario); }
JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortsJavaTest_activeHandles(JNIEnv*env,jclass cls)
{ (void)env;(void)cls;return (jint)amcl_ports_test_handles(); }
JNIEXPORT jint JNICALL Java_com_sun_media_sound_PortsJavaTest_activeArrays(JNIEnv*env,jclass cls)
{ (void)env;(void)cls;return ports_fake_arrays(); }
JNIEXPORT jlong JNICALL Java_com_sun_media_sound_PortsJavaTest_handleSequence(JNIEnv*env,jclass cls)
{ (void)env;(void)cls;return (jlong)amcl_ports_test_handle_sequence(); }
JNIEXPORT void JNICALL Java_com_sun_media_sound_PortsJavaTest_clearCache(JNIEnv*env,jclass cls)
{ (void)env;(void)cls;amcl_ports_test_reset(); }

/* 明确旧能力负控：保持同一物理输入，但注册旧USE_PORTS=FALSE的零设备边界。 */
#ifdef AMCL_PORTS_OLD_STUB
static jint old_zero_devices(JNIEnv*env,jclass cls){(void)env;(void)cls;return 0;}
#define COUNT_FUNCTION old_zero_devices
#else
#define COUNT_FUNCTION Java_com_sun_media_sound_PortMixerProvider_nGetNumDevices
#endif

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM*vm,void*reserved)
{
    JNIEnv*env=NULL;jclass provider,mixer;int ok;(void)reserved;
    JNINativeMethod p[]={
      {"nGetNumDevices","()I",(void*)COUNT_FUNCTION},
      {"nGetGeneration","()J",(void*)Java_com_sun_media_sound_PortMixerProvider_nGetGeneration},
      {"nNewPortMixerInfo","(I)Lcom/sun/media/sound/PortMixerProvider$PortMixerInfo;",(void*)Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfo},
      {"nNewPortMixerInfoSnapshot","(IJ)Lcom/sun/media/sound/PortMixerProvider$PortMixerInfo;",(void*)Java_com_sun_media_sound_PortMixerProvider_nNewPortMixerInfoSnapshot}
    };
    JNINativeMethod m[]={
      {"nOpen","(I)J",(void*)Java_com_sun_media_sound_PortMixer_nOpen},
      {"nOpenSnapshot","(J)J",(void*)Java_com_sun_media_sound_PortMixer_nOpenSnapshot},
      {"nClose","(J)V",(void*)Java_com_sun_media_sound_PortMixer_nClose},
      {"nGetPortCount","(J)I",(void*)Java_com_sun_media_sound_PortMixer_nGetPortCount},
      {"nGetPortType","(JI)I",(void*)Java_com_sun_media_sound_PortMixer_nGetPortType},
      {"nGetPortName","(JI)Ljava/lang/String;",(void*)Java_com_sun_media_sound_PortMixer_nGetPortName},
      {"nGetControls","(JILjava/util/Vector;)V",(void*)Java_com_sun_media_sound_PortMixer_nGetControls},
      {"nControlSetIntValue","(JI)V",(void*)Java_com_sun_media_sound_PortMixer_nControlSetIntValue},
      {"nControlGetIntValue","(J)I",(void*)Java_com_sun_media_sound_PortMixer_nControlGetIntValue},
      {"nControlSetFloatValue","(JF)V",(void*)Java_com_sun_media_sound_PortMixer_nControlSetFloatValue},
      {"nControlGetFloatValue","(J)F",(void*)Java_com_sun_media_sound_PortMixer_nControlGetFloatValue}
    };
    if((*vm)->GetEnv(vm,(void**)&env,JNI_VERSION_1_8)!=JNI_OK)return JNI_ERR;
    /* FindClass可能初始化平台类并重入其Java静态方法；显式检查异常，不能只看非空返回。 */
    provider=(*env)->FindClass(env,"com/sun/media/sound/PortMixerProvider");
    if(!provider||(*env)->ExceptionCheck(env))return JNI_ERR;
    mixer=(*env)->FindClass(env,"com/sun/media/sound/PortMixer");
    if(!mixer||(*env)->ExceptionCheck(env)){(*env)->DeleteLocalRef(env,provider);return JNI_ERR;}
    ok=(*env)->RegisterNatives(env,provider,p,(jint)(sizeof(p)/sizeof(p[0])));
    if(ok==0&&!(*env)->ExceptionCheck(env))ok=(*env)->RegisterNatives(env,mixer,m,(jint)(sizeof(m)/sizeof(m[0])));
    if((*env)->ExceptionCheck(env))ok=-1;
    (*env)->DeleteLocalRef(env,mixer);(*env)->DeleteLocalRef(env,provider);
    return ok==0?JNI_VERSION_1_8:JNI_ERR;
}
