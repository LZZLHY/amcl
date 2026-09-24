/** 系统EGL在首次公开调用时读取并锁存提供者，入口查询也属于该调用边界。
 * AppScope的NEED_OPENGL=1是进程启动能力声明；真正是否启用由系统设备能力决定，
 * Minecraft本局仍可选择GL/GLES/Vulkan。构建回调、源码及HAP门禁共用本校验，
 * 不在这里修改或补齐输入，防止错误源配置被打包过程静默掩盖。
 */
export function graphicsBootstrapIssues(app) {
  const environments=app?.appEnvironments;
  const values=Array.isArray(environments)?environments.filter(item=>item?.name==='NEED_OPENGL'):[];
  return values.length===1 && values[0].value==='1' ? [] :
    ['System graphics bootstrap requires exactly one startup NEED_OPENGL=1'];
}
