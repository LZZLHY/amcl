/* 严格JNI Invocation入口用于宿主资格：每个可能抛异常的查找/调用立即验错，
 * 避免宿主java启动器自身的JNI警告污染待测业务边界。正常JIT优化不作任何修改。
 */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
static int pending(JNIEnv* env) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    (*env)->ExceptionDescribe(env); return 1;
}
int main(int argc, char** argv) {
    if (argc < 4) return 2;
    int count = atoi(argv[1]); if (count < 1 || argc != count + 4) return 2;
    JavaVMOption* options = calloc((size_t)count, sizeof(*options)); if (!options) return 3;
    for (int i=0;i<count;++i) options[i].optionString=argv[i+2];
    JavaVMInitArgs arguments={JNI_VERSION_1_8,count,options,JNI_FALSE};
    JavaVM* vm=NULL;JNIEnv* env=NULL;
    int result=JNI_CreateJavaVM(&vm,(void**)&env,&arguments);free(options);
    if(result!=JNI_OK)return 4;
    int status=1;
    puts("MIDI_INVOCATION_VM_READY");fflush(stdout);
    jclass cls=(*env)->FindClass(env,"com/sun/media/sound/MidiJavaTest");if(pending(env)||!cls)goto done;
    jmethodID mainMethod=(*env)->GetStaticMethodID(env,cls,"main","([Ljava/lang/String;)V");if(pending(env)||!mainMethod)goto done;
    jclass string=(*env)->FindClass(env,"java/lang/String");if(pending(env)||!string)goto done;
    jobjectArray parameters=(*env)->NewObjectArray(env,2,string,NULL);if(pending(env)||!parameters)goto done;
    for(int i=0;i<2;++i){
        jstring value=(*env)->NewStringUTF(env,argv[count+2+i]);if(pending(env)||!value)goto done;
        (*env)->SetObjectArrayElement(env,parameters,i,value);if(pending(env))goto done;
        (*env)->DeleteLocalRef(env,value);
    }
    (*env)->CallStaticVoidMethod(env,cls,mainMethod,parameters);if(pending(env))goto done;
    status=0;
done:
    if((*vm)->DestroyJavaVM(vm)!=JNI_OK)return 5;
    return status;
}
