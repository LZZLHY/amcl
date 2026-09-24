#include <imgui_internal_ImGuiDockNode.h>

//@line:20

        #include "_common.h"
        #include <imgui_internal.h>

        #define IMGUI_DOCK_NODE ((ImGuiDockNode*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getID(JNIEnv* env, jobject object) {


//@line:27

       return IMGUI_DOCK_NODE->ID;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setID(JNIEnv* env, jobject object, jint imGuiID) {


//@line:32

       IMGUI_DOCK_NODE->ID = imGuiID;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getSharedFlags(JNIEnv* env, jobject object) {


//@line:39

       return IMGUI_DOCK_NODE->SharedFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setSharedFlags(JNIEnv* env, jobject object, jint sharedFlags) {


//@line:46

       IMGUI_DOCK_NODE->SharedFlags = sharedFlags;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLocalFlags(JNIEnv* env, jobject object) {


//@line:67

       return IMGUI_DOCK_NODE->LocalFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLocalFlags(JNIEnv* env, jobject object, jint flags) {


//@line:74

       IMGUI_DOCK_NODE->SetLocalFlags(flags);
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLocalFlagsInWindows(JNIEnv* env, jobject object) {


//@line:94

       return IMGUI_DOCK_NODE->LocalFlagsInWindows;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLocalFlagsInWindows(JNIEnv* env, jobject object, jint flags) {


//@line:101

       IMGUI_DOCK_NODE->LocalFlagsInWindows = flags;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getMergedFlags(JNIEnv* env, jobject object) {


//@line:119

        return IMGUI_DOCK_NODE->MergedFlags;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetParentNode(JNIEnv* env, jobject object) {


//@line:128

        return (intptr_t)IMGUI_DOCK_NODE->ParentNode;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetParentNode(JNIEnv* env, jobject object, jlong imGuiDockNodePtr) {


//@line:136

        IMGUI_DOCK_NODE->ParentNode = (ImGuiDockNode*)imGuiDockNodePtr;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetChildNodeFirst(JNIEnv* env, jobject object) {


//@line:148

        return (intptr_t)IMGUI_DOCK_NODE->ChildNodes[0];
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetChildNodeFirst(JNIEnv* env, jobject object, jlong imGuiDockNodePtr) {


//@line:159

        IMGUI_DOCK_NODE->ChildNodes[0] = (ImGuiDockNode*)imGuiDockNodePtr;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetChildNodeSecond(JNIEnv* env, jobject object) {


//@line:171

        return (intptr_t)IMGUI_DOCK_NODE->ChildNodes[1];
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetChildNodeSecond(JNIEnv* env, jobject object, jlong imGuiDockNodePtr) {


//@line:182

        IMGUI_DOCK_NODE->ChildNodes[1] = (ImGuiDockNode*)imGuiDockNodePtr;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetWindowClass(JNIEnv* env, jobject object) {


//@line:199

        return (intptr_t)&IMGUI_DOCK_NODE->WindowClass;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetWindowClass(JNIEnv* env, jobject object, jlong imGuiWindowClassPtr) {


//@line:213

        IMGUI_DOCK_NODE->WindowClass = *((ImGuiWindowClass*)imGuiWindowClassPtr);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_getPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:229

       Jni::ImVec2Cpy(env, &IMGUI_DOCK_NODE->Pos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getPosX(JNIEnv* env, jobject object) {


//@line:236

       return IMGUI_DOCK_NODE->Pos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getPosY(JNIEnv* env, jobject object) {


//@line:243

       return IMGUI_DOCK_NODE->Pos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setPos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:250

       IMGUI_DOCK_NODE->Pos.x = x;
       IMGUI_DOCK_NODE->Pos.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_getSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:267

       Jni::ImVec2Cpy(env, &IMGUI_DOCK_NODE->Size, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getSizeX(JNIEnv* env, jobject object) {


//@line:274

       return IMGUI_DOCK_NODE->Size.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getSizeY(JNIEnv* env, jobject object) {


//@line:281

       return IMGUI_DOCK_NODE->Size.y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:288

       IMGUI_DOCK_NODE->Size.x = x;
       IMGUI_DOCK_NODE->Size.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_getSizeRef(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:305

       Jni::ImVec2Cpy(env, &IMGUI_DOCK_NODE->SizeRef, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getSizeRefX(JNIEnv* env, jobject object) {


//@line:312

       return IMGUI_DOCK_NODE->SizeRef.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGuiDockNode_getSizeRefY(JNIEnv* env, jobject object) {


//@line:319

       return IMGUI_DOCK_NODE->SizeRef.y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setSizeRef(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:326

       IMGUI_DOCK_NODE->SizeRef.x = x;
       IMGUI_DOCK_NODE->SizeRef.y = y;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getSplitAxis(JNIEnv* env, jobject object) {


//@line:334

       return IMGUI_DOCK_NODE->SplitAxis;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setSplitAxis(JNIEnv* env, jobject object, jint splitAxis) {


//@line:341

       IMGUI_DOCK_NODE->SplitAxis = (ImGuiAxis)splitAxis;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getState(JNIEnv* env, jobject object) {


//@line:346

       return IMGUI_DOCK_NODE->State;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setState(JNIEnv* env, jobject object, jint state) {


//@line:351

       IMGUI_DOCK_NODE->State = (ImGuiDockNodeState)state;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetCentralNode(JNIEnv* env, jobject object) {


//@line:365

        return (intptr_t)IMGUI_DOCK_NODE->CentralNode;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetCentralNode(JNIEnv* env, jobject object, jlong imGuiDockNodePtr) {


//@line:376

        IMGUI_DOCK_NODE->CentralNode = (ImGuiDockNode*)imGuiDockNodePtr;
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGuiDockNode_nGetOnlyNodeWithWindows(JNIEnv* env, jobject object) {


//@line:388

        return (intptr_t)IMGUI_DOCK_NODE->OnlyNodeWithWindows;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nSetOnlyNodeWithWindows(JNIEnv* env, jobject object, jlong imGuiDockNodePtr) {


//@line:399

        IMGUI_DOCK_NODE->OnlyNodeWithWindows = (ImGuiDockNode*)imGuiDockNodePtr;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLastFrameAlive(JNIEnv* env, jobject object) {


//@line:406

       return IMGUI_DOCK_NODE->LastFrameAlive;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLastFrameAlive(JNIEnv* env, jobject object, jint lastFrameAlive) {


//@line:413

       IMGUI_DOCK_NODE->LastFrameAlive = lastFrameAlive;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLastFrameActive(JNIEnv* env, jobject object) {


//@line:420

       return IMGUI_DOCK_NODE->LastFrameActive;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLastFrameActive(JNIEnv* env, jobject object, jint lastFrameActive) {


//@line:427

       IMGUI_DOCK_NODE->LastFrameActive = lastFrameActive;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLastFrameFocused(JNIEnv* env, jobject object) {


//@line:434

       return IMGUI_DOCK_NODE->LastFrameFocused;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLastFrameFocused(JNIEnv* env, jobject object, jint lastFrameFocused) {


//@line:441

       IMGUI_DOCK_NODE->LastFrameFocused = lastFrameFocused;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getLastFocusedNodeId(JNIEnv* env, jobject object) {


//@line:448

       return IMGUI_DOCK_NODE->LastFocusedNodeId;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setLastFocusedNodeId(JNIEnv* env, jobject object, jint lastFocusedNodeId) {


//@line:455

       IMGUI_DOCK_NODE->LastFocusedNodeId = lastFocusedNodeId;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getSelectedTabId(JNIEnv* env, jobject object) {


//@line:462

       return IMGUI_DOCK_NODE->SelectedTabId;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setSelectedTabId(JNIEnv* env, jobject object, jint selectedTabId) {


//@line:469

       IMGUI_DOCK_NODE->SelectedTabId = selectedTabId;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getWantCloseTabId(JNIEnv* env, jobject object) {


//@line:476

       return IMGUI_DOCK_NODE->WantCloseTabId;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantCloseTabId(JNIEnv* env, jobject object, jint wantCloseTabId) {


//@line:483

       IMGUI_DOCK_NODE->WantCloseTabId = wantCloseTabId;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getAuthorityForPos(JNIEnv* env, jobject object) {


//@line:488

       return IMGUI_DOCK_NODE->AuthorityForPos;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setAuthorityForPos(JNIEnv* env, jobject object, jint authorityForPos) {


//@line:493

       IMGUI_DOCK_NODE->AuthorityForPos = authorityForPos;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getAuthorityForSize(JNIEnv* env, jobject object) {


//@line:498

       return IMGUI_DOCK_NODE->AuthorityForSize;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setAuthorityForSize(JNIEnv* env, jobject object, jint authorityForSize) {


//@line:503

       IMGUI_DOCK_NODE->AuthorityForSize = authorityForSize;
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGuiDockNode_getAuthorityForViewport(JNIEnv* env, jobject object) {


//@line:508

       return IMGUI_DOCK_NODE->AuthorityForViewport;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setAuthorityForViewport(JNIEnv* env, jobject object, jint authorityForViewport) {


//@line:513

       IMGUI_DOCK_NODE->AuthorityForViewport = authorityForViewport;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getIsVisible(JNIEnv* env, jobject object) {


//@line:520

       return IMGUI_DOCK_NODE->IsVisible;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setIsVisible(JNIEnv* env, jobject object, jboolean isVisible) {


//@line:527

       IMGUI_DOCK_NODE->IsVisible = isVisible;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getIsFocused(JNIEnv* env, jobject object) {


//@line:532

       return IMGUI_DOCK_NODE->IsFocused;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setIsFocused(JNIEnv* env, jobject object, jboolean isFocused) {


//@line:537

       IMGUI_DOCK_NODE->IsFocused = isFocused;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getHasCloseButton(JNIEnv* env, jobject object) {


//@line:542

       return IMGUI_DOCK_NODE->HasCloseButton;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setHasCloseButton(JNIEnv* env, jobject object, jboolean hasCloseButton) {


//@line:547

       IMGUI_DOCK_NODE->HasCloseButton = hasCloseButton;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getHasWindowMenuButton(JNIEnv* env, jobject object) {


//@line:552

       return IMGUI_DOCK_NODE->HasWindowMenuButton;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setHasWindowMenuButton(JNIEnv* env, jobject object, jboolean hasWindowMenuButton) {


//@line:557

       IMGUI_DOCK_NODE->HasWindowMenuButton = hasWindowMenuButton;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getWantCloseAll(JNIEnv* env, jobject object) {


//@line:564

       return IMGUI_DOCK_NODE->WantCloseAll;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantCloseAll(JNIEnv* env, jobject object, jboolean wantCloseAll) {


//@line:571

       IMGUI_DOCK_NODE->WantCloseAll = wantCloseAll;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getWantLockSizeOnce(JNIEnv* env, jobject object) {


//@line:576

       return IMGUI_DOCK_NODE->WantLockSizeOnce;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantLockSizeOnce(JNIEnv* env, jobject object, jboolean wantLockSizeOnce) {


//@line:581

       IMGUI_DOCK_NODE->WantLockSizeOnce = wantLockSizeOnce;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getWantMouseMove(JNIEnv* env, jobject object) {


//@line:588

       return IMGUI_DOCK_NODE->WantMouseMove;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantMouseMove(JNIEnv* env, jobject object, jboolean wantMouseMove) {


//@line:595

       IMGUI_DOCK_NODE->WantMouseMove = wantMouseMove;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getWantHiddenTabBarUpdate(JNIEnv* env, jobject object) {


//@line:600

       return IMGUI_DOCK_NODE->WantHiddenTabBarUpdate;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantHiddenTabBarUpdate(JNIEnv* env, jobject object, jboolean wantHiddenTabBarUpdate) {


//@line:605

       IMGUI_DOCK_NODE->WantHiddenTabBarUpdate = wantHiddenTabBarUpdate;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_getWantHiddenTabBarToggle(JNIEnv* env, jobject object) {


//@line:610

       return IMGUI_DOCK_NODE->WantHiddenTabBarToggle;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_setWantHiddenTabBarToggle(JNIEnv* env, jobject object, jboolean wantHiddenTabBarToggle) {


//@line:615

       IMGUI_DOCK_NODE->WantHiddenTabBarToggle = wantHiddenTabBarToggle;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isRootNode(JNIEnv* env, jobject object) {


//@line:619

        return IMGUI_DOCK_NODE->IsRootNode();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isDockSpace(JNIEnv* env, jobject object) {


//@line:623

        return IMGUI_DOCK_NODE->IsDockSpace();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isFloatingNode(JNIEnv* env, jobject object) {


//@line:627

        return IMGUI_DOCK_NODE->IsFloatingNode();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isCentralNode(JNIEnv* env, jobject object) {


//@line:631

        return IMGUI_DOCK_NODE->IsCentralNode();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isHiddenTabBar(JNIEnv* env, jobject object) {


//@line:638

        return IMGUI_DOCK_NODE->IsHiddenTabBar();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isNoTabBar(JNIEnv* env, jobject object) {


//@line:645

        return IMGUI_DOCK_NODE->IsNoTabBar();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isSplitNode(JNIEnv* env, jobject object) {


//@line:649

        return IMGUI_DOCK_NODE->IsSplitNode();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isLeafNode(JNIEnv* env, jobject object) {


//@line:653

        return IMGUI_DOCK_NODE->IsLeafNode();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiDockNode_isEmpty(JNIEnv* env, jobject object) {


//@line:657

        return IMGUI_DOCK_NODE->IsEmpty();
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGuiDockNode_nRect(JNIEnv* env, jobject object, jobject minDstImVec2, jobject maxDstImVec2) {


//@line:666

        ImRect rect = IMGUI_DOCK_NODE->Rect();
        Jni::ImVec2Cpy(env, &rect.Min, minDstImVec2);
        Jni::ImVec2Cpy(env, &rect.Max, maxDstImVec2);
    

}

