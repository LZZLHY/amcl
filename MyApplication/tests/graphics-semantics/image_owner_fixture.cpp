// 仅宿主映像身份夹具：导出唯一anchor，既不声明GL/EGL语义，也不冒充生产provider。
extern "C" int image_anchor() { return 7; }
