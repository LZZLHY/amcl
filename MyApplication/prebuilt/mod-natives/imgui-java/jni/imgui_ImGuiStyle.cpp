#include <imgui_ImGuiStyle.h>

//@line:19

        #include "_common.h"

        #define IMGUI_STYLE ((ImGuiStyle*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImGuiStyle_nCreate(JNIEnv* env, jobject object) {


//@line:30

        return (intptr_t)(new ImGuiStyle());
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getAlpha(JNIEnv* env, jobject object) {


//@line:37

        return IMGUI_STYLE->Alpha;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setAlpha(JNIEnv* env, jobject object, jfloat alpha) {


//@line:44

        IMGUI_STYLE->Alpha = alpha;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getDisabledAlpha(JNIEnv* env, jobject object) {


//@line:51

        return IMGUI_STYLE->DisabledAlpha;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setDisabledAlpha(JNIEnv* env, jobject object, jfloat disabledAlpha) {


//@line:58

        IMGUI_STYLE->DisabledAlpha = disabledAlpha;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getWindowPadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:74

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->WindowPadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowPaddingX(JNIEnv* env, jobject object) {


//@line:81

        return IMGUI_STYLE->WindowPadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowPaddingY(JNIEnv* env, jobject object) {


//@line:88

        return IMGUI_STYLE->WindowPadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:95

        IMGUI_STYLE->WindowPadding.x = x;
        IMGUI_STYLE->WindowPadding.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowRounding(JNIEnv* env, jobject object) {


//@line:104

        return IMGUI_STYLE->WindowRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowRounding(JNIEnv* env, jobject object, jfloat windowRounding) {


//@line:112

        IMGUI_STYLE->WindowRounding = windowRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowBorderSize(JNIEnv* env, jobject object) {


//@line:119

        return IMGUI_STYLE->WindowBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowBorderSize(JNIEnv* env, jobject object, jfloat windowBorderSize) {


//@line:126

        IMGUI_STYLE->WindowBorderSize = windowBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getWindowMinSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:142

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->WindowMinSize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowMinSizeX(JNIEnv* env, jobject object) {


//@line:149

        return IMGUI_STYLE->WindowMinSize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowMinSizeY(JNIEnv* env, jobject object) {


//@line:156

        return IMGUI_STYLE->WindowMinSize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowMinSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:163

        IMGUI_STYLE->WindowMinSize.x = x;
        IMGUI_STYLE->WindowMinSize.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getWindowTitleAlign(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:180

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->WindowTitleAlign, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowTitleAlignX(JNIEnv* env, jobject object) {


//@line:187

        return IMGUI_STYLE->WindowTitleAlign.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getWindowTitleAlignY(JNIEnv* env, jobject object) {


//@line:194

        return IMGUI_STYLE->WindowTitleAlign.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowTitleAlign(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:201

        IMGUI_STYLE->WindowTitleAlign.x = x;
        IMGUI_STYLE->WindowTitleAlign.y = y;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiStyle_getWindowMenuButtonPosition(JNIEnv* env, jobject object) {


//@line:209

        return (int)IMGUI_STYLE->WindowMenuButtonPosition;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setWindowMenuButtonPosition(JNIEnv* env, jobject object, jint windowMenuButtonPosition) {


//@line:216

        IMGUI_STYLE->WindowMenuButtonPosition = windowMenuButtonPosition;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getChildRounding(JNIEnv* env, jobject object) {


//@line:223

        return IMGUI_STYLE->ChildRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setChildRounding(JNIEnv* env, jobject object, jfloat childRounding) {


//@line:230

        IMGUI_STYLE->ChildRounding = childRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getChildBorderSize(JNIEnv* env, jobject object) {


//@line:237

        return IMGUI_STYLE->ChildBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setChildBorderSize(JNIEnv* env, jobject object, jfloat childBorderSize) {


//@line:244

        IMGUI_STYLE->ChildBorderSize = childBorderSize;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getPopupRounding(JNIEnv* env, jobject object) {


//@line:251

        return IMGUI_STYLE->PopupRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setPopupRounding(JNIEnv* env, jobject object, jfloat popupRounding) {


//@line:258

        IMGUI_STYLE->PopupRounding = popupRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getPopupBorderSize(JNIEnv* env, jobject object) {


//@line:265

        return IMGUI_STYLE->PopupBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setPopupBorderSize(JNIEnv* env, jobject object, jfloat popupBorderSize) {


//@line:272

        IMGUI_STYLE->PopupBorderSize = popupBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getFramePadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:288

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->FramePadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getFramePaddingX(JNIEnv* env, jobject object) {


//@line:295

        return IMGUI_STYLE->FramePadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getFramePaddingY(JNIEnv* env, jobject object) {


//@line:302

        return IMGUI_STYLE->FramePadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setFramePadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:309

        IMGUI_STYLE->FramePadding.x = x;
        IMGUI_STYLE->FramePadding.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getFrameRounding(JNIEnv* env, jobject object) {


//@line:317

        return IMGUI_STYLE->FrameRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setFrameRounding(JNIEnv* env, jobject object, jfloat frameRounding) {


//@line:324

        IMGUI_STYLE->FrameRounding = frameRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getFrameBorderSize(JNIEnv* env, jobject object) {


//@line:331

        return IMGUI_STYLE->FrameBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setFrameBorderSize(JNIEnv* env, jobject object, jfloat frameBorderSize) {


//@line:338

        IMGUI_STYLE->FrameBorderSize = frameBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getItemSpacing(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:354

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->ItemSpacing, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getItemSpacingX(JNIEnv* env, jobject object) {


//@line:361

        return IMGUI_STYLE->ItemSpacing.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getItemSpacingY(JNIEnv* env, jobject object) {


//@line:368

        return IMGUI_STYLE->ItemSpacing.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setItemSpacing(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:375

        IMGUI_STYLE->ItemSpacing.x = x;
        IMGUI_STYLE->ItemSpacing.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getItemInnerSpacing(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:392

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->ItemInnerSpacing, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getItemInnerSpacingX(JNIEnv* env, jobject object) {


//@line:399

        return IMGUI_STYLE->ItemInnerSpacing.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getItemInnerSpacingY(JNIEnv* env, jobject object) {


//@line:406

        return IMGUI_STYLE->ItemInnerSpacing.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setItemInnerSpacing(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:413

        IMGUI_STYLE->ItemInnerSpacing.x = x;
        IMGUI_STYLE->ItemInnerSpacing.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getCellPadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:430

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->CellPadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getCellPaddingX(JNIEnv* env, jobject object) {


//@line:437

        return IMGUI_STYLE->CellPadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getCellPaddingY(JNIEnv* env, jobject object) {


//@line:444

        return IMGUI_STYLE->CellPadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setCellPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:451

        IMGUI_STYLE->CellPadding.x = x;
        IMGUI_STYLE->CellPadding.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getTouchExtraPadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:470

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->TouchExtraPadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getTouchExtraPaddingX(JNIEnv* env, jobject object) {


//@line:478

        return IMGUI_STYLE->TouchExtraPadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getTouchExtraPaddingY(JNIEnv* env, jobject object) {


//@line:486

        return IMGUI_STYLE->TouchExtraPadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setTouchExtraPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:494

        IMGUI_STYLE->TouchExtraPadding.x = x;
        IMGUI_STYLE->TouchExtraPadding.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getIndentSpacing(JNIEnv* env, jobject object) {


//@line:502

        return IMGUI_STYLE->IndentSpacing;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setIndentSpacing(JNIEnv* env, jobject object, jfloat indentSpacing) {


//@line:509

        IMGUI_STYLE->IndentSpacing = indentSpacing;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getColumnsMinSpacing(JNIEnv* env, jobject object) {


//@line:516

        return IMGUI_STYLE->ColumnsMinSpacing;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColumnsMinSpacing(JNIEnv* env, jobject object, jfloat columnsMinSpacing) {


//@line:523

        IMGUI_STYLE->ColumnsMinSpacing = columnsMinSpacing;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getScrollbarSize(JNIEnv* env, jobject object) {


//@line:530

        return IMGUI_STYLE->ScrollbarSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setScrollbarSize(JNIEnv* env, jobject object, jfloat scrollbarSize) {


//@line:537

        IMGUI_STYLE->ScrollbarSize = scrollbarSize;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getScrollbarRounding(JNIEnv* env, jobject object) {


//@line:544

        return IMGUI_STYLE->ScrollbarRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setScrollbarRounding(JNIEnv* env, jobject object, jfloat scrollbarRounding) {


//@line:551

        IMGUI_STYLE->ScrollbarRounding = scrollbarRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getGrabMinSize(JNIEnv* env, jobject object) {


//@line:558

        return IMGUI_STYLE->GrabMinSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setGrabMinSize(JNIEnv* env, jobject object, jfloat grabMinSize) {


//@line:565

        IMGUI_STYLE->GrabMinSize = grabMinSize;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getGrabRounding(JNIEnv* env, jobject object) {


//@line:572

        return IMGUI_STYLE->GrabRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setGrabRounding(JNIEnv* env, jobject object, jfloat grabRounding) {


//@line:579

        IMGUI_STYLE->GrabRounding = grabRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getLogSliderDeadzone(JNIEnv* env, jobject object) {


//@line:586

        return IMGUI_STYLE->LogSliderDeadzone;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setLogSliderDeadzone(JNIEnv* env, jobject object, jfloat logSliderDeadzone) {


//@line:593

        IMGUI_STYLE->LogSliderDeadzone = logSliderDeadzone;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getTabRounding(JNIEnv* env, jobject object) {


//@line:600

        return IMGUI_STYLE->TabRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setTabRounding(JNIEnv* env, jobject object, jfloat tabRounding) {


//@line:607

        IMGUI_STYLE->TabRounding = tabRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getTabBorderSize(JNIEnv* env, jobject object) {


//@line:614

        return IMGUI_STYLE->TabBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setTabBorderSize(JNIEnv* env, jobject object, jfloat tabBorderSize) {


//@line:621

        IMGUI_STYLE->TabBorderSize = tabBorderSize;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getTabMinWidthForCloseButton(JNIEnv* env, jobject object) {


//@line:629

        return IMGUI_STYLE->TabMinWidthForCloseButton;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setTabMinWidthForCloseButton(JNIEnv* env, jobject object, jfloat tabMinWidthForCloseButton) {


//@line:637

        IMGUI_STYLE->TabMinWidthForCloseButton = tabMinWidthForCloseButton;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiStyle_getColorButtonPosition(JNIEnv* env, jobject object) {


//@line:644

        return IMGUI_STYLE->ColorButtonPosition;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColorButtonPosition(JNIEnv* env, jobject object, jint colorButtonPosition) {


//@line:651

        IMGUI_STYLE->ColorButtonPosition = colorButtonPosition;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getButtonTextAlign(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:667

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->ButtonTextAlign, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getButtonTextAlignX(JNIEnv* env, jobject object) {


//@line:674

        return IMGUI_STYLE->ButtonTextAlign.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getButtonTextAlignY(JNIEnv* env, jobject object) {


//@line:681

        return IMGUI_STYLE->ButtonTextAlign.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setButtonTextAlign(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:688

        IMGUI_STYLE->ButtonTextAlign.x = x;
        IMGUI_STYLE->ButtonTextAlign.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getSelectableTextAlign(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:707

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->SelectableTextAlign, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getSelectableTextAlignX(JNIEnv* env, jobject object) {


//@line:715

        return IMGUI_STYLE->SelectableTextAlign.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getSelectableTextAlignY(JNIEnv* env, jobject object) {


//@line:723

        return IMGUI_STYLE->SelectableTextAlign.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setSelectableTextAlign(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:731

        IMGUI_STYLE->SelectableTextAlign.x = x;
        IMGUI_STYLE->SelectableTextAlign.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getDisplayWindowPadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:748

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->DisplayWindowPadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getDisplayWindowPaddingX(JNIEnv* env, jobject object) {


//@line:755

        return IMGUI_STYLE->DisplayWindowPadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getDisplayWindowPaddingY(JNIEnv* env, jobject object) {


//@line:762

        return IMGUI_STYLE->DisplayWindowPadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setDisplayWindowPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:769

        IMGUI_STYLE->DisplayWindowPadding.x = x;
        IMGUI_STYLE->DisplayWindowPadding.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getDisplaySafeAreaPadding(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:788

        Jni::ImVec2Cpy(env, &IMGUI_STYLE->DisplaySafeAreaPadding, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getDisplaySafeAreaPaddingX(JNIEnv* env, jobject object) {


//@line:796

        return IMGUI_STYLE->DisplaySafeAreaPadding.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getDisplaySafeAreaPaddingY(JNIEnv* env, jobject object) {


//@line:804

        return IMGUI_STYLE->DisplaySafeAreaPadding.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setDisplaySafeAreaPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:812

        IMGUI_STYLE->DisplaySafeAreaPadding.x = x;
        IMGUI_STYLE->DisplaySafeAreaPadding.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getMouseCursorScale(JNIEnv* env, jobject object) {


//@line:820

        return IMGUI_STYLE->MouseCursorScale;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setMouseCursorScale(JNIEnv* env, jobject object, jfloat mouseCursorScale) {


//@line:827

        IMGUI_STYLE->MouseCursorScale = mouseCursorScale;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiStyle_getAntiAliasedLines(JNIEnv* env, jobject object) {


//@line:834

        return IMGUI_STYLE->AntiAliasedLines;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setAntiAliasedLines(JNIEnv* env, jobject object, jboolean antiAliasedLines) {


//@line:841

        IMGUI_STYLE->AntiAliasedLines = antiAliasedLines;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiStyle_getAntiAliasedLinesUseTex(JNIEnv* env, jobject object) {


//@line:850

        return IMGUI_STYLE->AntiAliasedLinesUseTex;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setAntiAliasedLinesUseTex(JNIEnv* env, jobject object, jboolean antiAliasedLinesUseTex) {


//@line:859

        IMGUI_STYLE->AntiAliasedLinesUseTex = antiAliasedLinesUseTex;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiStyle_getAntiAliasedFill(JNIEnv* env, jobject object) {


//@line:867

        return IMGUI_STYLE->AntiAliasedFill;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setAntiAliasedFill(JNIEnv* env, jobject object, jboolean antiAliasedFill) {


//@line:875

        IMGUI_STYLE->AntiAliasedFill = antiAliasedFill;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getCurveTessellationTol(JNIEnv* env, jobject object) {


//@line:883

        return IMGUI_STYLE->CurveTessellationTol;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setCurveTessellationTol(JNIEnv* env, jobject object, jfloat curveTessellationTol) {


//@line:891

        IMGUI_STYLE->CurveTessellationTol = curveTessellationTol;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStyle_getCircleTessellationMaxError(JNIEnv* env, jobject object) {


//@line:899

        return IMGUI_STYLE->CircleTessellationMaxError;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setCircleTessellationMaxError(JNIEnv* env, jobject object, jfloat circleTessellationMaxError) {


//@line:907

        IMGUI_STYLE->CircleTessellationMaxError = circleTessellationMaxError;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getColors(JNIEnv* env, jobject object, jobjectArray buff) {


//@line:920

        for (int i = 0; i < ImGuiCol_COUNT; i++) {
            jfloatArray jColors = (jfloatArray)env->GetObjectArrayElement(buff, i);
            jfloat* jBuffColor = env->GetFloatArrayElements(jColors, 0);

            jBuffColor[0] = IMGUI_STYLE->Colors[i].x;
            jBuffColor[1] = IMGUI_STYLE->Colors[i].y;
            jBuffColor[2] = IMGUI_STYLE->Colors[i].z;
            jBuffColor[3] = IMGUI_STYLE->Colors[i].w;

            env->ReleaseFloatArrayElements(jColors, jBuffColor, 0);
            env->DeleteLocalRef(jColors);
        }
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColors(JNIEnv* env, jobject object, jobjectArray colors) {


//@line:938

        for (int i = 0; i < ImGuiCol_COUNT; i++) {
            jfloatArray jColors = (jfloatArray)env->GetObjectArrayElement(colors, i);
            jfloat* jColor = env->GetFloatArrayElements(jColors, 0);

            IMGUI_STYLE->Colors[i].x = jColor[0];
            IMGUI_STYLE->Colors[i].y = jColor[1];
            IMGUI_STYLE->Colors[i].z = jColor[2];
            IMGUI_STYLE->Colors[i].w = jColor[3];

            env->ReleaseFloatArrayElements(jColors, jColor, 0);
            env->DeleteLocalRef(jColors);
        }
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_getColor(JNIEnv* env, jobject object, jint imGuiCol, jobject dstImVec4) {


//@line:959

        Jni::ImVec4Cpy(env, IMGUI_STYLE->Colors[imGuiCol], dstImVec4);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColor__IFFFF(JNIEnv* env, jobject object, jint imGuiCol, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:963

        IMGUI_STYLE->Colors[imGuiCol] = ImColor((float)r, (float)g, (float)b, (float)a);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColor__IIIII(JNIEnv* env, jobject object, jint imGuiCol, jint r, jint g, jint b, jint a) {


//@line:967

        IMGUI_STYLE->Colors[imGuiCol] = ImColor((int)r, (int)g, (int)b, (int)a);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_setColor__II(JNIEnv* env, jobject object, jint imGuiCol, jint col) {


//@line:971

        IMGUI_STYLE->Colors[imGuiCol] = ImColor(col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStyle_scaleAllSizes(JNIEnv* env, jobject object, jfloat scaleFactor) {


//@line:975

        IMGUI_STYLE->ScaleAllSizes(scaleFactor);
    

}

