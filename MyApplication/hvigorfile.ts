import { appTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { graphicsBootstrapIssues } from './scripts/graphics-bootstrap-contract.mjs';

export default {
  system: appTasks,
  plugins: [{
    pluginId: 'systemGraphicsBootstrap',
    apply(node: any) {
      node.afterNodeEvaluate((evaluated: any) => {
        const enabled = process.env.AMCL_DESKTOP_NATIVE_GL_VALIDATE === '1';
        const product = process.argv.find(arg => arg.startsWith('product='))?.slice(8) ?? 'default';
        if (enabled && product !== 'desktop') throw new Error('Native GL validation is desktop-only');
        const context = evaluated.getContext(OhosPluginId.OHOS_APP_PLUGIN);
        const config = context.getAppJsonOpt();
        const registry = JSON.parse(readFileSync(resolve(__dirname, 'config/products.json'), 'utf8'));
        if (!registry.products[product]) throw new Error('Unknown or retired product: ' + product);
        // AppScope是启动环境的权威来源。仅校验实际合并结果，保留其他环境项；
        // 不按产品/本局profile删除能力声明，也不把错误配置静默修成另一个值。
        const bootstrapIssues = graphicsBootstrapIssues(config.app);
        if (bootstrapIssues.length > 0) throw new Error(bootstrapIssues.join('\n'));
      });
    }
  }]
};
