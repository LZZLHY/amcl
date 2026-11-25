import { DistributionPolicy, DOCS_INSTALL_URL, DOCS_INSTALL_FALLBACK_URL, DOCS_NO_JIT_URL,
  DOCS_NO_JIT_FALLBACK_URL } from 'commons';
import { SkillFields } from './LauncherSkillBus';

interface SupportRoute { url: string; params?: SkillFields; }

/** 页面及网页都由安装产品列出；调用方只传业务主题，不能指定路由、URL 或沙箱路径。 */
export function playerSupportRoute(args: SkillFields): SupportRoute | undefined {
  if (DistributionPolicy.isStore()) return undefined;
  const topic = args['topic'];
  if (topic === 'feedback') return { url: 'pages/FeedbackPage' };
  if (topic === 'sponsor') return { url: 'pages/SponsorPage' };
  if (topic !== 'install' && topic !== 'jit') return undefined;
  const install = topic === 'install';
  return { url: 'pages/DocWebPage', params: { 'title': install ? '怎么安装' : 'JIT 的解决办法',
    'src': install ? DOCS_INSTALL_URL : DOCS_NO_JIT_URL,
    'fallback': install ? DOCS_INSTALL_FALLBACK_URL : DOCS_NO_JIT_FALLBACK_URL } };
}

export function supportRoute(domain: string, args: SkillFields): SupportRoute | undefined {
  if (domain === 'messages') return { url: 'pages/MessageCenterPage' };
  if (domain === 'about') return { url: 'pages/AboutPage' };
  if (domain === 'changelog') return { url: 'pages/ChangelogPage' };
  if (domain === 'shares') return { url: 'pages/LogShareHistoryPage' };
  if (domain === 'policy' && DistributionPolicy.isStore() && ['privacy','license','logshare'].includes(String(args['policy']))) {
    return { url: 'pages/LocalPolicyPage', params: { 'policy': args['policy'] } };
  }
  if (domain === 'activity' && typeof args['activityId'] === 'number' && Number.isSafeInteger(args['activityId']) &&
    (args['activityId'] as number) > 0) {
    return { url: 'pages/ActivityLogPage', params: { 'activityId': args['activityId'], 'view': 'overview' } };
  }
  return undefined;
}
