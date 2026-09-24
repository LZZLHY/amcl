/**
 * Stub libobjc.A.so for HarmonyOS
 * java-objc-bridge's Runtime interface loads "objc.A" via JNA and looks up
 * ObjC runtime functions by name. All functions return 0/NULL — MC gets null
 * results from ObjC calls and skips clipboard/macOS functionality.
 */

typedef void* Pointer;
typedef long long int64;

// Class lookup
Pointer objc_lookUpClass(const char* name) { return 0; }
Pointer objc_getClass(const char* name) { return 0; }
Pointer objc_getMetaClass(const char* name) { return 0; }
Pointer objc_getRequiredClass(const char* name) { return 0; }
Pointer objc_getFutureClass(const char* name) { return 0; }
int objc_getClassList(Pointer buffer, int bufferCount) { return 0; }
Pointer objc_allocateClassPair(Pointer superclass, const char* name, long extraBytes) { return 0; }
void objc_registerClassPair(Pointer cls) {}
void objc_setFutureClass(Pointer cls, const char* name) {}

// Selector
Pointer sel_getUid(const char* name) { return 0; }
Pointer sel_registerName(const char* name) { return 0; }
const char* sel_getName(Pointer sel) { return ""; }
int sel_isEqual(Pointer lhs, Pointer rhs) { return 0; }

// Messaging
int64 objc_msgSend(Pointer self, Pointer cmd, ...) { return 0; }
int64 objc_msgSendSuper(Pointer self, Pointer cmd, ...) { return 0; }
double objc_msgSend_fpret(Pointer self, Pointer cmd, ...) { return 0.0; }
void objc_msgSend_stret(Pointer stretAddr, Pointer self, Pointer cmd, ...) {}
int64 objc_msgSendSuper_stret(Pointer self, Pointer cmd) { return 0; }

// Object
Pointer object_copy(Pointer obj, long size) { return 0; }
Pointer object_dispose(Pointer obj) { return 0; }
Pointer object_getClass(Pointer obj) { return 0; }
const char* object_getClassName(Pointer obj) { return ""; }
Pointer object_getIndexedIvars(Pointer obj) { return 0; }
Pointer object_getInstanceVariable(Pointer obj, const char* name, Pointer outValue) { return 0; }
Pointer object_getIvar(Pointer obj, Pointer ivar) { return 0; }
Pointer object_setClass(Pointer obj, Pointer cls) { return 0; }
Pointer object_setInstanceVariable(Pointer obj, const char* name, Pointer value) { return 0; }
void object_setIvar(Pointer obj, Pointer ivar, Pointer value) {}

// Class info
const char* class_getName(Pointer cls) { return ""; }
Pointer class_getSuperclass(Pointer cls) { return 0; }
int class_isMetaClass(Pointer cls) { return 0; }
long class_getInstanceSize(Pointer cls) { return 0; }
Pointer class_getInstanceVariable(Pointer cls, const char* name) { return 0; }
Pointer class_getClassVariable(Pointer cls, const char* name) { return 0; }
Pointer class_getInstanceMethod(Pointer cls, Pointer name) { return 0; }
Pointer class_getClassMethod(Pointer cls, Pointer name) { return 0; }
Pointer class_getMethodImplementation(Pointer cls, Pointer name) { return 0; }
int class_respondsToSelector(Pointer cls, Pointer sel) { return 0; }
int class_conformsToProtocol(Pointer cls, Pointer protocol) { return 0; }
Pointer class_copyIvarList(Pointer cls, Pointer outCount) { return 0; }
Pointer class_copyMethodList(Pointer cls, Pointer outCount) { return 0; }
Pointer class_copyPropertyList(Pointer cls, Pointer outCount) { return 0; }
Pointer class_copyProtocolList(Pointer cls, Pointer outCount) { return 0; }
Pointer class_getProperty(Pointer cls, const char* name) { return 0; }
int class_addIvar(Pointer cls, const char* name, long size, char alignment, const char* types) { return 0; }
int class_addMethod(Pointer cls, Pointer name, Pointer imp, const char* types) { return 0; }
int class_addProtocol(Pointer cls, Pointer protocol) { return 0; }
Pointer class_replaceMethod(Pointer cls, Pointer name, Pointer imp, const char* types) { return 0; }
int class_addProperty(Pointer cls, const char* name, Pointer attrs, int attrCount) { return 0; }
void class_replaceProperty(Pointer cls, const char* name, Pointer attrs, int attrCount) {}

// Method
void method_exchangeImplementations(Pointer m1, Pointer m2) {}
void method_getArgumentType(Pointer m, int index, Pointer dst, long dstLen) {}
Pointer method_getImplementation(Pointer m) { return 0; }
Pointer method_getName(Pointer m) { return 0; }
int method_getNumberOfArguments(Pointer m) { return 0; }
void method_getReturnType(Pointer m, Pointer dst, long dstLen) {}
const char* method_getTypeEncoding(Pointer m) { return ""; }
Pointer method_setImplementation(Pointer m, Pointer imp) { return 0; }

// Ivar
const char* ivar_getName(Pointer v) { return ""; }
long ivar_getOffset(Pointer v) { return 0; }
const char* ivar_getTypeEncoding(Pointer v) { return ""; }

// Property
const char* property_getAttributes(Pointer property) { return ""; }

// Protocol
Pointer objc_getProtocol(const char* name) { return 0; }
Pointer objc_copyProtocolList(Pointer outCount) { return 0; }
int protocol_conformsToProtocol(Pointer proto, Pointer other) { return 0; }
Pointer protocol_copyMethodDescriptionList(Pointer proto, int isRequired, int isInstance, Pointer outCount) { return 0; }
Pointer protocol_copyPropertyList(Pointer proto, Pointer outCount) { return 0; }
Pointer protocol_copyProtocolList(Pointer proto, Pointer outCount) { return 0; }
Pointer protocol_getMethodDescription(Pointer proto, Pointer aSel, int isRequired, int isInstance) { return 0; }
const char* protocol_getName(Pointer proto) { return ""; }
Pointer protocol_getProperty(Pointer proto, const char* name, int isRequired, int isInstance) { return 0; }
int protocol_isEqual(Pointer proto, Pointer other) { return 0; }

// Associated objects
Pointer objc_getAssociatedObject(Pointer object, const char* key) { return 0; }
void objc_setAssociatedObject(Pointer object, Pointer key, Pointer value, Pointer policy) {}
void objc_removeAssociatedObjects(Pointer object) {}
