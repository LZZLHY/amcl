#include <imgui_extension_texteditor_TextEditorLanguageDefinition.h>
#include <imgui_extension_texteditor_TextEditor.h>

//@line:8

        #include "_texteditor.h"

        #define TEXT_EDITOR ((TextEditor*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_texteditor_TextEditor_nCreate(JNIEnv* env, jobject object) {


//@line:26

        return (intptr_t)(new TextEditor());
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_nSetLanguageDefinition(JNIEnv* env, jobject object, jlong ptr) {


//@line:34

        TEXT_EDITOR->SetLanguageDefinition(*((TextEditor::LanguageDefinition*)ptr));
    

}

JNIEXPORT jintArray JNICALL Java_imgui_extension_texteditor_TextEditor_getPalette(JNIEnv* env, jobject object) {


//@line:38

        const auto& palette = TEXT_EDITOR->GetPalette();

        jintArray res = env->NewIntArray(palette.size());

        jint arr[palette.size()];
        for (int i = 0; i < palette.size(); i++) {
            arr[i] = palette[i];
        }

        env->SetIntArrayRegion(res, 0, palette.size(), arr);

        return res;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_nSetPalette(JNIEnv* env, jobject object, jintArray obj_palette, jint length) {
	int* palette = (int*)env->GetPrimitiveArrayCritical(obj_palette, 0);


//@line:57

        std::array<ImU32, (unsigned)TextEditor::PaletteIndex::Max> arr;

        for (int i = 0; i < length; i++) {
            arr[i] = palette[i];
        }

        TEXT_EDITOR->SetPalette(arr);
    
	env->ReleasePrimitiveArrayCritical(obj_palette, palette, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_nSetErrorMarkers(JNIEnv* env, jobject object, jintArray obj_keys, jint keysLen, jobjectArray values, jint valuesLen) {
	int* keys = (int*)env->GetPrimitiveArrayCritical(obj_keys, 0);


//@line:74

        std::map<int, std::string> markers;

        for (int i = 0; i < keysLen; i++) {
            int key = keys[i];
            jstring string = (jstring)env->GetObjectArrayElement(values, i);
            const char* value = env->GetStringUTFChars(string, JNI_FALSE);

            markers.emplace(std::pair<int, std::string>(key, std::string(value)));
        }

        TEXT_EDITOR->SetErrorMarkers(markers);
    
	env->ReleasePrimitiveArrayCritical(obj_keys, keys, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_nSetBreakpoints(JNIEnv* env, jobject object, jintArray obj_breakpoints, jint length) {
	int* breakpoints = (int*)env->GetPrimitiveArrayCritical(obj_breakpoints, 0);


//@line:92

        std::unordered_set<int> set;

        for (int i = 0; i < length; i++) {
            set.emplace(breakpoints[i]);
        }

        TEXT_EDITOR->SetBreakpoints(set);
    
	env->ReleasePrimitiveArrayCritical(obj_breakpoints, breakpoints, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_render(JNIEnv* env, jobject object, jstring obj_title) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);


//@line:102

        TEXT_EDITOR->Render(title);
    
	env->ReleaseStringUTFChars(obj_title, title);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setText(JNIEnv* env, jobject object, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:106

        TEXT_EDITOR->SetText(text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT jstring JNICALL Java_imgui_extension_texteditor_TextEditor_getText(JNIEnv* env, jobject object) {


//@line:110

        return env->NewStringUTF(TEXT_EDITOR->GetText().c_str());
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_nSetTextLines(JNIEnv* env, jobject object, jobjectArray lines, jint length) {


//@line:118

        std::vector<std::string> vec;
        vec.reserve(length);

        for (int i = 0; i < length; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(lines, i);
            const char* raw = env->GetStringUTFChars(string, JNI_FALSE);

            vec.emplace_back(std::string(raw));
        }

        TEXT_EDITOR->SetTextLines(vec);
    

}

JNIEXPORT jobjectArray JNICALL Java_imgui_extension_texteditor_TextEditor_getTextLines(JNIEnv* env, jobject object) {


//@line:132

        const auto lines = TEXT_EDITOR->GetTextLines();

        jobjectArray arr = (jobjectArray)env->NewObjectArray(lines.size(),
            env->FindClass("java/lang/String"),
            env->NewStringUTF(""));

        for (int i = 0; i < lines.size(); i++) {
            const auto& str = lines[i];

            env->SetObjectArrayElement(arr, i, env->NewStringUTF(str.c_str()));
        }

        return arr;
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_texteditor_TextEditor_getSelectedText(JNIEnv* env, jobject object) {


//@line:148

       return env->NewStringUTF(TEXT_EDITOR->GetSelectedText().c_str());
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_texteditor_TextEditor_getCurrentLineText(JNIEnv* env, jobject object) {


//@line:152

       return env->NewStringUTF(TEXT_EDITOR->GetCurrentLineText().c_str());
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_texteditor_TextEditor_getTotalLines(JNIEnv* env, jobject object) {


//@line:156

        return TEXT_EDITOR->GetTotalLines();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isOverwrite(JNIEnv* env, jobject object) {


//@line:160

        return TEXT_EDITOR->IsOverwrite();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setReadOnly(JNIEnv* env, jobject object, jboolean value) {


//@line:164

        TEXT_EDITOR->SetReadOnly(value);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isReadOnly(JNIEnv* env, jobject object) {


//@line:168

        return TEXT_EDITOR->IsReadOnly();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isTextChanged(JNIEnv* env, jobject object) {


//@line:172

        return TEXT_EDITOR->IsTextChanged();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isCursorPositionChanged(JNIEnv* env, jobject object) {


//@line:176

        return TEXT_EDITOR->IsCursorPositionChanged();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isColorizerEnabled(JNIEnv* env, jobject object) {


//@line:180

        return TEXT_EDITOR->IsColorizerEnabled();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setColorizerEnable(JNIEnv* env, jobject object, jboolean value) {


//@line:184

        TEXT_EDITOR->SetColorizerEnable(value);
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_texteditor_TextEditor_getCursorPositionLine(JNIEnv* env, jobject object) {


//@line:188

        return TEXT_EDITOR->GetCursorPosition().mLine;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_texteditor_TextEditor_getCursorPositionColumn(JNIEnv* env, jobject object) {


//@line:192

        return TEXT_EDITOR->GetCursorPosition().mColumn;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setCursorPosition(JNIEnv* env, jobject object, jint line, jint column) {


//@line:196

        TEXT_EDITOR->SetCursorPosition({ line, column });
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setHandleMouseInputs(JNIEnv* env, jobject object, jboolean value) {


//@line:200

        TEXT_EDITOR->SetHandleMouseInputs(value);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isHandleMouseInputsEnabled(JNIEnv* env, jobject object) {


//@line:204

        return TEXT_EDITOR->IsHandleMouseInputsEnabled();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setHandleKeyboardInputs(JNIEnv* env, jobject object, jboolean value) {


//@line:208

        TEXT_EDITOR->SetHandleKeyboardInputs(value);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isHandleKeyboardInputsEnabled(JNIEnv* env, jobject object) {


//@line:212

        return TEXT_EDITOR->IsHandleKeyboardInputsEnabled();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setImGuiChildIgnored(JNIEnv* env, jobject object, jboolean value) {


//@line:216

        TEXT_EDITOR->SetImGuiChildIgnored(value);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isImGuiChildIgnored(JNIEnv* env, jobject object) {


//@line:220

        return TEXT_EDITOR->IsImGuiChildIgnored();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setShowWhitespaces(JNIEnv* env, jobject object, jboolean value) {


//@line:224

        TEXT_EDITOR->SetShowWhitespaces(value);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_isShowingWhitespaces(JNIEnv* env, jobject object) {


//@line:228

        return TEXT_EDITOR->IsShowingWhitespaces();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setTabSize(JNIEnv* env, jobject object, jint value) {


//@line:232

        TEXT_EDITOR->SetTabSize(value);
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_texteditor_TextEditor_getTabSize(JNIEnv* env, jobject object) {


//@line:236

        return TEXT_EDITOR->GetTabSize();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_insertText(JNIEnv* env, jobject object, jstring obj_value) {
	char* value = (char*)env->GetStringUTFChars(obj_value, 0);


//@line:240

        TEXT_EDITOR->InsertText(value);
    
	env->ReleaseStringUTFChars(obj_value, value);

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveUp(JNIEnv* env, jobject object, jint amount, jboolean select) {


//@line:244

        TEXT_EDITOR->MoveUp(amount, select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveDown(JNIEnv* env, jobject object, jint amount, jboolean select) {


//@line:248

        TEXT_EDITOR->MoveDown(amount, select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveLeft(JNIEnv* env, jobject object, jint amount, jboolean select, jboolean wordMode) {


//@line:252

        TEXT_EDITOR->MoveLeft(amount, select, wordMode);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveRight(JNIEnv* env, jobject object, jint amount, jboolean select, jboolean wordMode) {


//@line:256

        TEXT_EDITOR->MoveRight(amount, select, wordMode);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveTop(JNIEnv* env, jobject object, jboolean select) {


//@line:260

        TEXT_EDITOR->MoveTop(select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveBottom(JNIEnv* env, jobject object, jboolean select) {


//@line:264

        TEXT_EDITOR->MoveBottom(select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveHome(JNIEnv* env, jobject object, jboolean select) {


//@line:268

        TEXT_EDITOR->MoveHome(select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_moveEnd(JNIEnv* env, jobject object, jboolean select) {


//@line:272

        TEXT_EDITOR->MoveEnd(select);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setSelectionStart(JNIEnv* env, jobject object, jint line, jint column) {


//@line:276

        TEXT_EDITOR->SetSelectionStart({ line, column });
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setSelectionEnd(JNIEnv* env, jobject object, jint line, jint column) {


//@line:280

        TEXT_EDITOR->SetSelectionEnd({ line, column });
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_setSelection(JNIEnv* env, jobject object, jint lineStart, jint columnStart, jint lineEnd, jint columnEnd, jint selectionMode) {


//@line:284

        TEXT_EDITOR->SetSelection({ lineStart, columnStart }, { lineEnd, columnEnd },
            static_cast<TextEditor::SelectionMode>(selectionMode));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_selectWordUnderCursor(JNIEnv* env, jobject object) {


//@line:289

        TEXT_EDITOR->SelectWordUnderCursor();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_selectAll(JNIEnv* env, jobject object) {


//@line:293

        TEXT_EDITOR->SelectAll();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_hasSelection(JNIEnv* env, jobject object) {


//@line:297

        return TEXT_EDITOR->HasSelection();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_copy(JNIEnv* env, jobject object) {


//@line:301

        TEXT_EDITOR->Copy();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_cut(JNIEnv* env, jobject object) {


//@line:305

        TEXT_EDITOR->Cut();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_paste(JNIEnv* env, jobject object) {


//@line:309

        TEXT_EDITOR->Paste();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_delete(JNIEnv* env, jobject object) {


//@line:313

        TEXT_EDITOR->Delete();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_canUndo(JNIEnv* env, jobject object) {


//@line:317

        return TEXT_EDITOR->CanUndo();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_texteditor_TextEditor_canRedo(JNIEnv* env, jobject object) {


//@line:321

        return TEXT_EDITOR->CanRedo();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_undo(JNIEnv* env, jobject object, jint steps) {


//@line:325

        TEXT_EDITOR->Undo(steps);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_texteditor_TextEditor_redo(JNIEnv* env, jobject object, jint steps) {


//@line:329

        TEXT_EDITOR->Redo(steps);
    

}

JNIEXPORT jintArray JNICALL Java_imgui_extension_texteditor_TextEditor_getDarkPalette(JNIEnv* env, jobject object) {


//@line:333

        const auto& palette = TEXT_EDITOR->GetDarkPalette();

        jintArray res = env->NewIntArray(palette.size());

        jint arr[palette.size()];
        for (int i = 0; i < palette.size(); i++) {
            arr[i] = palette[i];
        }

        env->SetIntArrayRegion(res, 0, palette.size(), arr);

        return res;
    

}

JNIEXPORT jintArray JNICALL Java_imgui_extension_texteditor_TextEditor_getLightPalette(JNIEnv* env, jobject object) {


//@line:348

        const auto& palette = TEXT_EDITOR->GetLightPalette();

        jintArray res = env->NewIntArray(palette.size());

        jint arr[palette.size()];
        for (int i = 0; i < palette.size(); i++) {
            arr[i] = palette[i];
        }

        env->SetIntArrayRegion(res, 0, palette.size(), arr);

        return res;
    

}

JNIEXPORT jintArray JNICALL Java_imgui_extension_texteditor_TextEditor_getRetroBluePalette(JNIEnv* env, jobject object) {


//@line:363

        const auto& palette = TEXT_EDITOR->GetRetroBluePalette();

        jintArray res = env->NewIntArray(palette.size());

        jint arr[palette.size()];
        for (int i = 0; i < palette.size(); i++) {
            arr[i] = palette[i];
        }

        env->SetIntArrayRegion(res, 0, palette.size(), arr);

        return res;
    

}

