/* Capture真实Java/JNI资格的固定平台替身控制，不进入生产JDK或HAP。 */
#include <jni.h>
void amcl_mock_capture_configure(int route, int allowed);
void amcl_mock_capture_feed(void *data, int bytes);
void amcl_mock_capture_stats(int *values);
void amcl_mock_failure(const char *name);

JNIEXPORT void JNICALL Java_com_sun_media_sound_DaudioCaptureJniRegression_configure(
    JNIEnv *env, jclass type, jboolean route, jboolean allowed)
{ (void)env; (void)type; amcl_mock_capture_configure(route, allowed); }

JNIEXPORT void JNICALL Java_com_sun_media_sound_DaudioCaptureJniRegression_feed(
    JNIEnv *env, jclass type, jbyteArray pcm)
{
    jsize length;
    jbyte *data;
    (void)type;
    length = (*env)->GetArrayLength(env, pcm);
    if ((*env)->ExceptionCheck(env)) return;
    data = (*env)->GetByteArrayElements(env, pcm, NULL);
    if (!data) return;
    amcl_mock_capture_feed(data, length);
    (*env)->ReleaseByteArrayElements(env, pcm, data, JNI_ABORT);
}

JNIEXPORT void JNICALL Java_com_sun_media_sound_DaudioCaptureJniRegression_fault(
    JNIEnv *env, jclass type, jstring name)
{
    const char *text;
    (void)type;
    text = (*env)->GetStringUTFChars(env, name, NULL);
    if (!text) return;
    amcl_mock_failure(text);
    (*env)->ReleaseStringUTFChars(env, name, text);
}

JNIEXPORT jintArray JNICALL Java_com_sun_media_sound_DaudioCaptureJniRegression_stats(JNIEnv *env, jclass type)
{
    jintArray result;
    int values[3];
    (void)type;
    amcl_mock_capture_stats(values);
    result = (*env)->NewIntArray(env, 3);
    if (!result) return NULL;
    (*env)->SetIntArrayRegion(env, result, 0, 3, values);
    return result;
}
