// 显式依赖owner以保留DT_NEEDED；dlsym(facade,"image_anchor")会借到依赖符号，
// 用于证明canonical owner检查确实拒绝facade自身摘要被冒充为实际owner身份。
extern "C" int image_anchor();
extern "C" int facade_anchor() { return image_anchor(); }
