/* 宿主JNI Invocation测试入口，不使用java程序的主类探测过程。
 * 每次可能抛Java异常的JNI调用后显式检查；测试类/参数与普通java对照完全相同。
 * 本入口只证明被测真实VM+Java/JNI的合同，不能替代目标JDK bin/java CLI资格。 */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failed(JNIEnv *env)
{
    if (!(*env)->ExceptionCheck(env)) return 0;
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return 1;
}

int main(int argc, char **argv)
{
    JavaVM *vm = NULL; JNIEnv *env = NULL;
    JavaVMOption options[2]; JavaVMInitArgs init;
    jclass main_class = NULL, string_class = NULL;
    jmethodID main_method; jobjectArray arguments = NULL; jstring path = NULL;
    char *class_path; size_t capacity; int result = 1; jint status;
    /* argv: major、类目录、内部main类名、可选测试库路径；全部由固定runner生成。 */
    if (argc != 4 && argc != 5) return 2;
    capacity = strlen(argv[2]) + 64;
    class_path = calloc(capacity, 1); if (!class_path) return 2;
    snprintf(class_path, capacity, "%s%s", strcmp(argv[1], "8") == 0 ?
        "-Xbootclasspath/p:" : "--patch-module=java.desktop=", argv[2]);
    memset(&init, 0, sizeof(init)); memset(options, 0, sizeof(options));
    options[0].optionString = "-Xcheck:jni"; options[1].optionString = class_path;
    init.version = JNI_VERSION_1_8; init.nOptions = 2; init.options = options;
    init.ignoreUnrecognized = JNI_FALSE;
    status = JNI_CreateJavaVM(&vm, (void **)&env, &init); free(class_path);
    if (status != JNI_OK || !vm || !env) { fprintf(stderr, "CreateJavaVM=%d\n", status); return 2; }
    fprintf(stderr, "PORTS_INVOCATION_VM_CREATED\n");
    main_class = (*env)->FindClass(env, argv[3]); if (failed(env) || !main_class) goto done;
    main_method = (*env)->GetStaticMethodID(env, main_class, "main", "([Ljava/lang/String;)V");
    if (failed(env) || !main_method) goto done;
    string_class = (*env)->FindClass(env, "java/lang/String"); if (failed(env) || !string_class) goto done;
    arguments = (*env)->NewObjectArray(env, argc == 5 ? 1 : 0, string_class, NULL);
    if (failed(env) || !arguments) goto done;
    if (argc == 5) {
        /* runner只生成ASCII绝对路径，UTF-8设备名由生产JNI另行严格转换。 */
        path = (*env)->NewStringUTF(env, argv[4]); if (failed(env) || !path) goto done;
        (*env)->SetObjectArrayElement(env, arguments, 0, path); if (failed(env)) goto done;
    }
    (*env)->CallStaticVoidMethod(env, main_class, main_method, arguments);
    if (failed(env)) goto done;
    result = 0;
done:
    /* 所有局部引用仍属于当前附着线程；先释放，再依JLI生命周期先Detach后Destroy。 */
    if (path) (*env)->DeleteLocalRef(env, path);
    if (arguments) (*env)->DeleteLocalRef(env, arguments);
    if (string_class) (*env)->DeleteLocalRef(env, string_class);
    if (main_class) (*env)->DeleteLocalRef(env, main_class);
    status = (*vm)->DetachCurrentThread(vm);
    if (status != JNI_OK) { fprintf(stderr, "DetachCurrentThread=%d\n", status); result = 2; }
    status = (*vm)->DestroyJavaVM(vm);
    if (status != JNI_OK) { fprintf(stderr, "DestroyJavaVM=%d\n", status); result = 2; }
    fprintf(stderr, "PORTS_INVOCATION_DESTROYED result=%d\n", result);
    return result;
}
