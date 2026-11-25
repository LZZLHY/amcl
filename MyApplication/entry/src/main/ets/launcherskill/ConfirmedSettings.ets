import { ThemeMode } from 'commons';
import { PreferenceManager } from 'feature_system';
import { UpdateChecker } from 'update';
import { SettingsSkillData } from './SettingsSkillValues';

const scalarKeys: Record<string,string> = {
  'memory':'mcXmx','virtual-memory':'virtualMemoryMode','isolation':'versionIsolation','game-keep-screen-on':'gameKeepScreenOn',
  'process':'tabletIndependentGameProcess','java':'jdkVersion','frame-rate':'ohosFrameRateCap','fixed-refresh-rate':'ohosFixedRefreshRate',
  'language':'gameLanguage','remote-cache':'cacheRemoteMeta','acceleration':'accelDownload','jdk-web':'jdkWebEnabled',
  'jdk-auto':'jdkAutoCheck','mc-source':'mcSource','mod-source':'modSource','jdk-source':'jdkSource','jdk-update':'jdkChannel','storage':'mcStorageLocation'
};

/** 只读请求中的原始键。其他设置不可读不会妨碍当前项；错误不能变成页面的展示缺省。 */
export function readConfirmedSetting(prefs: PreferenceManager,id: string): SettingsSkillData {
  const result: SettingsSkillData = {'confirmed':true};
  const key=scalarKeys[id];
  if (key!==undefined) result[id]=prefs.strictLauncherField(key);
  if (id==='jdk-source') result['jdk-web']=prefs.strictLauncherField('jdkWebEnabled');
  if (id==='jdk-update') result['jdk-auto']=prefs.strictLauncherField('jdkAutoCheck');
  if (id==='fixed-refresh-rate') result['cap']=prefs.strictLauncherField('ohosFrameRateCap');
  if (id==='jvm') result['hasCustomArguments']=(prefs.strictLauncherField('customJvmArgs') as string).trim().length>0;
  if (id==='theme') {
    const theme=prefs.strictTheme();
    result['mode']=theme.mode===ThemeMode.SYSTEM?'system':theme.mode===ThemeMode.LIGHT?'light':'dark';
    result['accent']=theme.accent;
  }
  if (id==='phone-sheet-height') result['percent']=prefs.strictSheetHeight();
  if (id==='immersive') {
    const light=prefs.strictImmersiveLight();
    result['enabled']=light.enabled;result['navigation']=light.navigationMode;
    result['bottomBar']=light.bottomBar;result['titleButtons']=light.titleButtons;
  }
  if (id==='software-update') {
    const installed=UpdateChecker.installedIdentity();
    if (!installed) throw new Error('无法核实已安装应用版本');
    result['currentVersion']=installed.name;
    result['currentCode']=installed.code;
  }
  return result;
}
