// 把「全用户通用插件基线」注入官方 auto-init 的 web profile。
// 基线 = dsh-main 本机 profile 的等价物：
//   官方 base/web-app + dsh-better-sidebar(侧边栏) + @linxin666/* 五件套 +
//   dsh-remote-web-gateway(远程连接) + dsh-usage-stats + @roubaai/* 四包 +
//   @deepseek-ai/dsh-client-ui-brand-rouba（Rouba 品牌，经 profile patch insert，
//   见 entrypoint.sh 写入的 cordis.patch.yml——官方 occupant 被 disable）。
// 本地私有包走 file:*.tgz；第三方走公共 npm registry（pnpm install 拉取）。
// 用法：node inject-profile.mjs <profiles/web/package.json>
import fs from 'node:fs';

const [p] = process.argv.slice(2);
if (!p) {
  console.error('usage: node inject-profile.mjs <profile package.json>');
  process.exit(1);
}

const j = JSON.parse(fs.readFileSync(p, 'utf8'));
const tgzDir = '/opt/deepseek-harness/plugins-tgz';

const dependencies = {
  '@deepseek-ai/dsh-client-ui-brand-rouba': `file:${tgzDir}/deepseek-ai-dsh-client-ui-brand-rouba-0.1.2-rc.1.tgz`,
  '@linxin666/dsh-client-ui-skill-explorer': '0.3.14',
  '@linxin666/dsh-client-ui-skin-center': '0.3.14',
  '@linxin666/dsh-client-ui-web-ui-settings': '0.3.14',
  '@linxin666/dsh-ssh': '0.3.14',
  '@linxin666/dsh-tool-describe-image': '0.3.14',
  '@roubaai/media': `file:${tgzDir}/roubaai-media-0.1.2-rc.1.tgz`,
  '@roubaai/media-maizi': `file:${tgzDir}/roubaai-media-maizi-0.1.2-rc.1.tgz`,
  '@roubaai/media-mxapi': `file:${tgzDir}/roubaai-media-mxapi-0.1.2-rc.1.tgz`,
  '@roubaai/settings': `file:${tgzDir}/roubaai-settings-0.1.2-rc.1.tgz`,
  'dsh-better-sidebar': '0.18.0',
  'dsh-remote-web-gateway': '0.2.2',
  'dsh-usage-stats': '^0.1.16',
};

const bundles = [
  '@deepseek-ai/dsh-base',
  '@deepseek-ai/dsh-web-app',
  'dsh-better-sidebar',
  '@linxin666/dsh-client-ui-skill-explorer',
  '@linxin666/dsh-client-ui-skin-center',
  '@linxin666/dsh-client-ui-web-ui-settings',
  '@linxin666/dsh-ssh',
  '@linxin666/dsh-tool-describe-image',
  'dsh-remote-web-gateway',
  'dsh-usage-stats',
  '@roubaai/media',
  '@roubaai/media-maizi',
  '@roubaai/media-mxapi',
  '@roubaai/settings',
];

j.dependencies = dependencies;
j.dsh = j.dsh || {};
j.dsh.profile = j.dsh.profile || {};
j.dsh.profile.bundles = bundles;
j.dsh.profile.patchReload = j.dsh.profile.patchReload || 'live';
// 原生模块（ssh2 / node-pty / cpu-features）由 pnpm 构建
j.pnpm = { onlyBuiltDependencies: ['node-pty', 'ssh2', 'cpu-features'] };

fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
console.log('[inject] deps:', Object.keys(j.dependencies).length);
console.log('[inject] bundles:', j.dsh.profile.bundles.length);
