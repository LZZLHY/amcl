/**
 * 为每次启动派生独立的日志配置。原下载配置保持字节与 SHA-1 身份不变，只写本局副本。
 * 仅改可识别的 logs/ 文件输出与删除策略；未知/用户自定义配置保持原样并记录边界。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync, writeEvidenceTextAtomic, updateSessionEnvironment, sessionEnvironmentFact } from 'commons';

export interface SessionLoggingRewrite { text: string; owned: boolean; reason: string; }

/** 纯转换便于用不同代际官方 XML 做行为回归；路径来自应用会话目录，不含游戏账户信息。 */
export function rewriteSessionLoggingXml(text: string, directory: string): SessionLoggingRewrite {
  const escaped: string = directory.split('&').join('&amp;').split('"').join('&quot;')
    .split('<').join('&lt;').split('>').join('&gt;').split("'").join('&apos;');
  if (!new RegExp('fileName\\s*=\\s*["\']logs/latest\\.log["\']').test(text)) {
    return { text: text, owned: false, reason: '日志配置不是可识别的官方相对路径模板，保留原配置并按外部来源采集' };
  }
  let output: string = text.replace(new RegExp('(fileName|filePattern)\\s*=\\s*"logs/', 'g'), '$1="' + escaped + '/')
    .replace(new RegExp("(fileName|filePattern)\\s*=\\s*'logs/", 'g'), "$1='" + escaped + '/');
  // 单次会话的轮转分片不得被数量/日期删除策略清掉；整个会话由账本保留策略管理。
  output = output.replace(new RegExp('<Delete\\b[^>]*>[\\s\\S]*?</Delete\\s*>', 'gi'), '')
    .replace(new RegExp('<Delete\\b[^>]*/>', 'gi'), '')
    .replace(new RegExp('(<DefaultRolloverStrategy\\b[^>]*\\bmax\\s*=\\s*)["\'][^"\']*["\']', 'g'), '$1"2147483647"');
  return { text: output, owned: true, reason: '官方配置副本仅调整会话文件落点与整局保留策略' };
}

/** 将已校验的官方配置参数转为本局副本；返回原参数表示明确的外部配置边界。 */
export function prepareSessionLoggingArgument(filesDir: string, activityId: number, argument: string): string {
  if (activityId <= 0) return argument;
  const equal: number = argument.indexOf('=');
  const original: string = equal < 0 ? '' : argument.substring(equal + 1);
  let rewritten: SessionLoggingRewrite = { text: '', owned: false, reason: '没有可解析的日志配置文件参数' };
  if (original.length > 0) {
    try {
      if (fs.statSync(original).size > 1024 * 1024) throw new Error('配置超过安全大小');
      rewritten = rewriteSessionLoggingXml(fs.readTextSync(original), filesDir + '/logs/ledger/' + activityId + '/game/logs');
    } catch (e) { rewritten.reason = '日志配置不可读取：' + (e as Error).message; }
  }
  updateSessionEnvironment(filesDir, activityId, [
    sessionEnvironmentFact('logging.configurationStatus', rewritten.owned ? 'owned' : 'external', 'SessionLoggingConfig'),
    sessionEnvironmentFact('logging.configurationReason', rewritten.reason, 'SessionLoggingConfig'),
  ]);
  if (!rewritten.owned) return argument;
  const dir: string = filesDir + '/logs/ledger/' + activityId;
  ensureDirSync(dir + '/game/logs'); ensureDirSync(dir + '/configuration');
  const path: string = dir + '/configuration/log4j.xml';
  writeEvidenceTextAtomic(path, rewritten.text);
  return argument.substring(0, equal + 1) + path;
}
