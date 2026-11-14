/* 仅宿主资格 libjsound 的固定故障控制；不进入目标后端或正式 JDK patch。 */
#include <jni.h>
void amcl_mock_failure(const char *name);
void amcl_mock_stats(int *values);
void amcl_mock_delay_frames(int frames);

JNIEXPORT void JNICALL Java_com_sun_media_sound_DaudioTimelineJniRegression_setDelayFrames(
    JNIEnv *env, jclass type, jint frames)
{ (void)env; (void)type; amcl_mock_delay_frames(frames); }

JNIEXPORT void JNICALL Java_com_sun_media_sound_DaudioJniRegression_setFault(
    JNIEnv *env, jclass type, jstring name)
{
    const char *text;
    (void)type;
    text = (*env)->GetStringUTFChars(env, name, NULL);
    if (!text) return;
    amcl_mock_failure(text);
    (*env)->ReleaseStringUTFChars(env, name, text);
}

JNIEXPORT jintArray JNICALL Java_com_sun_media_sound_DaudioJniRegression_stats(JNIEnv *env, jclass type)
{
    jintArray result;
    int values[4];
    (void)type;
    amcl_mock_stats(values);
    result = (*env)->NewIntArray(env, 4);
    if (!result) return NULL;
    (*env)->SetIntArrayRegion(env, result, 0, 4, values);
    return result;
}
