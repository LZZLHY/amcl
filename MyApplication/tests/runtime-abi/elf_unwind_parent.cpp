/** 真实 DT_NEEDED 依赖，用于验证第二个映像登记失败时首个登记和两库构造都正确处理。 */
extern "C" void frame_call(void (*)());
extern "C" void parent_call(void (*callback)()) { frame_call(callback); }
