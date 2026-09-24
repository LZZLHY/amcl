/**
 * Stub libjcocoa.so for HarmonyOS — replaces macOS libjcocoa.dylib
 *
 * java-objc-bridge's RuntimeUtils has 3 native methods:
 *   - private static native void init()
 *   - public static native long createProxy(Recipient)
 *   - public static native Recipient getJavaPeer(long)
 *
 * On non-macOS, these are no-ops. The original jar's NativeUtils is patched
 * to call System.loadLibrary("jcocoa") instead of extracting .dylib from jar.
 */
// Minimal JNI types — OHOS NDK doesn't ship jni.h
// We only need basic types for the 3 stub functions
typedef void* JNIEnv;
typedef void* jclass;
typedef void* jobject;
typedef long long jlong;
#define JNIEXPORT __attribute__((visibility("default")))
#define JNICALL

// JNI name: ca.weblite.objc.RuntimeUtils.init()V
JNIEXPORT void JNICALL Java_ca_weblite_objc_RuntimeUtils_init(JNIEnv *env, jclass cls) {
    // No-op on non-macOS
}

// JNI name: ca.weblite.objc.RuntimeUtils.createProxy(Lca/weblite/objc/Recipient;)J
JNIEXPORT jlong JNICALL Java_ca_weblite_objc_RuntimeUtils_createProxy(JNIEnv *env, jclass cls, jobject recipient) {
    return 0; // Return null pointer
}

// JNI name: ca.weblite.objc.RuntimeUtils.getJavaPeer(J)Lca/weblite/objc/Recipient;
JNIEXPORT jobject JNICALL Java_ca_weblite_objc_RuntimeUtils_getJavaPeer(JNIEnv *env, jclass cls, jlong peer) {
    return 0; // Return null
}
