/**
 * 标准音频服务的加载器兼容启动桥。Agent只处理已核ModuleClassLoader的SPI资源枚举，
 * 不改变Java类解析顺序；实际provider/JNI仍由启动器父加载域定义。
 */
import { AUDIO_SERVICE_AGENT_RUNTIME_JAR } from './AudioServiceCompatibilityArtifact';

/** 内容寻址路径与旧应用共存；不能覆盖另一个正在启动的进程正在读取的Agent。 */
export function audioServiceCompatibilityPath(filesDir: string): string {
  return filesDir + '/runtime-compat/' + AUDIO_SERVICE_AGENT_RUNTIME_JAR;
}

/** 用户参数合并后安装生产兼容组件；只保护本组件身份，保留其它Agent和音频诊断参数。 */
export function applyAudioServiceCompatibility(args: string[], filesDir: string): string[] {
  for (const arg of args) {
    if (arg.startsWith('-Damcl.audio.service.') || arg === '-Damcl.audio.enabled' ||
      arg.startsWith('-Damcl.audio.enabled=') ||
      arg.startsWith('-javaagent:' + filesDir + '/runtime-compat/amcl-audio-service-agent-')) {
      throw new Error('平台音频组件由启动器交付，不允许自定义参数覆盖');
    }
  }
  // 平台服务桥先注册首次定义变换，防止其他premain先定义Forge加载器；其它Agent相对顺序不变。
  return ['-Damcl.audio.enabled=true', '-Damcl.audio.service.schema=1',
    '-javaagent:' + audioServiceCompatibilityPath(filesDir)].concat(args);
}
