#include <imgui_extension_texteditor_TextEditorLanguageDefinition.h>

//@line:8

        #include "_texteditor.h"

        #define LANG_DEF ((TextEditor::LanguageDefinition*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nCreate(JNIEnv* env, jobject object) {


//@line:26

        return (intptr_t)(new TextEditor::LanguageDefinition());
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setName(JNIEnv* env, jobject object, jstring obj_name) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:30

        LANG_DEF->mName = name;
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nSetKeywords(JNIEnv* env, jobject object, jobjectArray keywords, jint length) {


//@line:38

        std::unordered_set<std::string> set;

        for (int i = 0; i < length; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(keywords, i);
            const char* raw = env->GetStringUTFChars(string, JNI_FALSE);

            set.emplace(std::string(raw));
        }

        LANG_DEF->mKeywords = set;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nSetIdentifiers(JNIEnv* env, jobject object, jobjectArray keys, jint keysLen, jobjectArray decl, jint declLen) {


//@line:58

        std::unordered_map<std::string, TextEditor::Identifier> identifiers;

        for (int i = 0; i < keysLen; i++) {
            jstring string1 = (jstring)env->GetObjectArrayElement(keys, i);
            const char* key = env->GetStringUTFChars(string1, JNI_FALSE);

            jstring string2 = (jstring)env->GetObjectArrayElement(decl, i);
            const char* value = env->GetStringUTFChars(string2, JNI_FALSE);

            TextEditor::Identifier id;
            id.mDeclaration = std::string(value);

            identifiers.insert(std::pair<std::string, TextEditor::Identifier>(std::string(key), id));
        }

        LANG_DEF->mIdentifiers = identifiers;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nSetPreprocIdentifiers(JNIEnv* env, jobject object, jobjectArray keys, jint keysLen, jobjectArray decl, jint declLen) {


//@line:84

        std::unordered_map<std::string, TextEditor::Identifier> preprocIdentifiers;

        for (int i = 0; i < keysLen; i++) {
            jstring string1 = (jstring)env->GetObjectArrayElement(keys, i);
            const char* key = env->GetStringUTFChars(string1, JNI_FALSE);

            jstring string2 = (jstring)env->GetObjectArrayElement(decl, i);
            const char* value = env->GetStringUTFChars(string2, JNI_FALSE);

            TextEditor::Identifier id;
            id.mDeclaration = std::string(value);

            preprocIdentifiers.insert(std::pair<std::string, TextEditor::Identifier>(std::string(key), id));
        }

        LANG_DEF->mPreprocIdentifiers = preprocIdentifiers;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setCommentStart(JNIEnv* env, jobject object, jstring obj_value) {
	char* value = (char*)env->GetStringUTFChars(obj_value, 0);


//@line:103

        LANG_DEF->mCommentStart = value;
    
	env->ReleaseStringUTFChars(obj_value, value);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setCommentEnd(JNIEnv* env, jobject object, jstring obj_value) {
	char* value = (char*)env->GetStringUTFChars(obj_value, 0);


//@line:107

        LANG_DEF->mCommentEnd = value;
    
	env->ReleaseStringUTFChars(obj_value, value);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setSingleLineComment(JNIEnv* env, jobject object, jstring obj_value) {
	char* value = (char*)env->GetStringUTFChars(obj_value, 0);


//@line:111

        LANG_DEF->mSingleLineComment = value;
    
	env->ReleaseStringUTFChars(obj_value, value);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setPreprocChar(JNIEnv* env, jobject object, jchar value) {


//@line:115

        LANG_DEF->mPreprocChar = value;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setAutoIdentation(JNIEnv* env, jobject object, jboolean value) {


//@line:119

        LANG_DEF->mAutoIndentation = value;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nSetTokenRegexStrings(JNIEnv* env, jobject object, jobjectArray keys, jint keysLen, jintArray obj_paletteIndexes, jint paletteIndexesLen) {
	int* paletteIndexes = (int*)env->GetPrimitiveArrayCritical(obj_paletteIndexes, 0);


//@line:130

        std::vector<std::pair<std::string, TextEditor::PaletteIndex>> tokenRegexStrings;

        for (int i = 0; i < keysLen; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(keys, i);
            const char* key = env->GetStringUTFChars(string, JNI_FALSE);

            int value = paletteIndexes[i];

            tokenRegexStrings.emplace_back(std::pair<std::string, TextEditor::PaletteIndex>(std::string(key),
                static_cast<TextEditor::PaletteIndex>(value)));
        }

        LANG_DEF->mTokenRegexStrings = tokenRegexStrings;
    
	env->ReleasePrimitiveArrayCritical(obj_paletteIndexes, paletteIndexes, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_setCaseSensitive(JNIEnv* env, jobject object, jboolean value) {


//@line:146

        LANG_DEF->mCaseSensitive = value;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nCPlusPlus(JNIEnv* env, jclass clazz) {


//@line:178

        return (intptr_t)&TextEditor::LanguageDefinition::CPlusPlus();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nHLSL(JNIEnv* env, jclass clazz) {


//@line:182

        return (intptr_t)&TextEditor::LanguageDefinition::HLSL();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nGLSL(JNIEnv* env, jclass clazz) {


//@line:186

        return (intptr_t)&TextEditor::LanguageDefinition::GLSL();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nC(JNIEnv* env, jclass clazz) {


//@line:190

        return (intptr_t)&TextEditor::LanguageDefinition::C();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nSQL(JNIEnv* env, jclass clazz) {


//@line:194

        return (intptr_t)&TextEditor::LanguageDefinition::SQL();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nAngelScript(JNIEnv* env, jclass clazz) {


//@line:198

        return (intptr_t)&TextEditor::LanguageDefinition::AngelScript();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditorLanguageDefinition_nLua(JNIEnv* env, jclass clazz) {


//@line:202

        return (intptr_t)&TextEditor::LanguageDefinition::Lua();
    

}

