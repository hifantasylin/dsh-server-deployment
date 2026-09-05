# dsh-preview：DSH 官方闭包 + 全用户通用插件基线（本地可访问预览）

仿 autovideo 的 docker 组织方式（nginx 反代 + 服务容器 + 端口映射），把
**官方 npm 闭包（`@deepseek-ai/dsh@0.1.2-rc.1`）+ 通用插件基线**起成本机可反复
起停的预览环境，浏览器直接查看效果。

> 背景：2026-09-05 方向 1 实测定案（`docs/migration-autovideo-to-dsh.md` v2）。
> 「通用插件基线」取自本机 `.dsh-main` profile，等同真实服务器每户种子（见 runbook §4）。

## 通用插件基线（每户预装，全用户通用）

| 插件 | 版本 | 来源 | 作用 |
|---|---|---|---|
| `dsh-better-sidebar` | 0.18.0 | 公共 npm | VSCode 风格右侧栏（explorer/terminal/git/browser） |
| `@linxin666/dsh-client-ui-skill-explorer` | 0.3.14 | 公共 npm | 技能浏览 |
| `@linxin666/dsh-client-ui-skin-center` | 0.3.14 | 公共 npm | 皮肤中心 |
| `@linxin666/dsh-client-ui-web-ui-settings` | 0.3.14 | 公共 npm | Web UI 设置 |
| `@linxin666/dsh-ssh` | 0.3.14 | 公共 npm | SSH |
| `@linxin666/dsh-tool-describe-image` | 0.3.14 | 公共 npm | 看图 |
| `dsh-remote-web-gateway` | 0.2.2 | 公共 npm | 手机/平板远程访问（Quick Tunnel+QR） |
| `dsh-usage-stats` | ^0.1.16 | 公共 npm | 用量统计 |
| `@roubaai/{media,media-maizi,media-mxapi,settings}` | 0.1.2-rc.1 | fork 产物 tgz | 媒体生成栈 + RoubaAI 设置 |
| `@deepseek-ai/dsh-client-ui-brand-rouba` | 0.1.2-rc.1 | fork 产物 tgz | Rouba 品牌（sidebar/hero 槽） |

机制：
- 第三方走公共 npm（profile `dependencies` 版本号 + `pnpm install`）；私有包走
  `file:$BASE/plugins-tgz/*.tgz`。
- profile `dsh.profile.bundles` 顺序 = 上表顺序（base/web-app 在前）。
- Rouba 品牌无 `dsh.bundle`，只能经 profile `cordis.patch.yml` insert；且须先
  `disabled: true` 官方 `ui-brand-official`（同名 brand slot 冲突）。首启由
  `entrypoint.sh` 自动写这份 patch。
- `ssh2`/`node-pty`/`cpu-features` 原生模块由 pnpm 本地编译（`pnpm.onlyBuiltDependencies`
  已写入 profile manifest），镜像预装 build-essential/python3。

## 拓扑

```
宿主 localhost:8090
  └─ nginx 容器 (nginx:alpine)   upstream dsh:3102
       └─ dsh 服务容器 (node:22-slim)
            ├─ dsh web  127.0.0.1:3101   （官方安全限制：仅回环）
            └─ socat 桥  0.0.0.0:3102 → 127.0.0.1:3101
```

## 用法

```bash
cd docker/preview

# 首次构建 + 启动（构建含 npm i 官方闭包 + 编译链，约几分钟）
docker compose up -d --build

# 取访问链接（token 每次重启变化）
docker logs dsh-preview | grep "dsh web ready"
# 浏览器访问：http://localhost:8090/?token=<token>

# 停止 / 再次启动（profile 数据保留在 dsh-home 卷）
docker compose down
docker compose up -d

# 彻底清掉数据（回到首启初始化基线）
docker compose down -v
```

> 首次 `up` 会在容器内 pnpm 拉取第三方插件并编译原生模块（需要网络，
> registry 慢可进容器换 npmmirror：`docker exec -u 0 dsh-preview pnpm config set registry https://registry.npmmirror.com`）。

## 定制

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DSH_WEB_PORT` | `3101` | dsh web 容器内回环端口 |
| `DSH_BRIDGE_PORT` | `3102` | socat 桥对外端口（nginx upstream 使用） |
| `DSH_HOME_DIR` | `/home/dsh/dsh-home` | DSH_HOME（可换宿主目录挂载） |

宿主映射端口（`8090`）在 `docker-compose.yml` 的 `nginx.ports` 修改。

## 构建上下文素材与版本源

- `plugins-tgz/roubaai-*.tgz` × 4 + `deepseek-ai-dsh-client-ui-brand-rouba-*.tgz`：
  fork 产物（`pnpm pack`）。**发布流程**：改动 fork 源码后须先重建产物再 pack——
  host 面 `pnpm run build:lib:host`，client 面 `pnpm --filter <pkg> bundle`，
  否则 tgz 内是旧 `lib/`（教训：settings 一度打包了旧 UI）。
- 官方闭包版本在 `dsh/Dockerfile`（`npm i @deepseek-ai/dsh@<版本>`）。
- 第三方插件版本在 `dsh/inject-profile.mjs`（dependencies/bundles 表）。
