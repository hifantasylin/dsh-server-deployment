# 交接文档：autovideo → DeepSeek Harness 多租户迁移（2026-09-05）

> 本会话在本地 Docker 做了大量验证后暂停。新会话请先通读本文 + 
> `migration-autovideo-to-dsh.md`（已验证版 runbook），再从「当前卡点 / 建议下一步」继续。

---

## 1. 任务与目标

把线上 autovideo 项目（Docker Compose，域名 `https://www.roubaai.com`）下线，
改为部署 **deepseek-harness（`rouba-dsh` 仓库）+ roubaai-video-plugin 媒体插件 +
dsh-server-deployment 多租户网关**。服务器 = autovideo 那台同一 Docker 主机。

已确认决策（用户拍板）：
- 部署仓库：`git@github.com:hifantasylin/rouba-dsh.git`（private，分支 `media-rouba-pure-plugins`，git 即发布通道）。
- 安装前缀 `/opt/deepseek-harness`；域名/证书沿用 autovideo。
- media key / LLM key 均为**每用户自填**，不设共享默认。
- 优先交付：详细可执行 runbook。

## 2. 已提交代码（均已 push 到 rouba-dsh）

- `af87422a2a` media: stream generated video/music from a local host cache（媒体本地缓存根治方案）。
- `809b0dbd90` build: ignore multi-tenant gateway runtime paths（`.gitignore` 补 users/gateway/bin/settings.yaml/templates/plugins-tgz）。

本地工作树 `f:\deepseek-harness`：remote `origin`=官方 deepseek-ai，`rouba-dsh`=hifantasylin；当前分支同 commit，干净。

## 3. 核心产物（已在开发机）

| 资产 | 路径 | 说明 |
|---|---|---|
| 已验证 runbook | `f:\Github\used-plugins\dsh-server-deployment\docs\migration-autovideo-to-dsh.md` | 已按实验结论固化「源码+产物」流程 |
| lib 产物收集 | `F:\Workspace\collect-lib.ps1` + `lib-filelist.txt` | 各包 lib/ + apps/web/dist |
| lib tar | `F:\Workspace\prod-lib.tar` | 已打好的产物包 |
| roubaai tgz | `F:\Workspace\tgz\roubaai-{media,media-maizi,media-mxapi,settings}-0.1.2-rc.1.tgz` | 已验证 workspace 依赖改写 |
| profile 种子脚本 | `F:\Workspace\seed-profile2.js`（deps 用 file:tgz）、`seed-profile.js`（旧 file:目录版，弃） | 逻辑已移植进 runbook §4.3 |
| 实验脚本 | `F:\Workspace\{run-web.sh,run-web2.sh,install-dsh-server.sh,fix-gateway.sh}` | 容器内执行用 |
| deploy key | `F:\Workspace\deploykey`(.pub) | rouba-dsh-test 容器生成的 GitHub Deploy Key（只读该仓） |

## 4. 本地实验容器（可继续用）

| 容器 | 镜像/形态 | 状态 | 已验证 |
|---|---|---|---|
| `rouba-dsh-test` | node:22-slim，普通 | 在跑 | clone→pnpm install→放 lib 产物→不 build 直接 dsh web=200；roubaai tgz 种子=200 |
| `rouba-dsh-sysd` | ubuntu-sysd（自制，含 systemd），`--privileged --cgroupns=host` | 在跑 | 网关 200；建号/admin 单元 OK；**实例崩于 landlock**（见 §6） |
| 镜像 | `ubuntu-sysd`（docker commit 自 sysd-prep，已含 systemd/dbus） | — | 拉取 jrei/systemd-ubuntu 镜像源 403，故自制 |

容器内 `/opt/deepseek-harness` = rouba-dsh clone（含构建产物与 plugins-tgz 的 4 个 tgz）。
rouba-dsh-test 内有 `/opt/deepseek-harness`（root 跑验证用）与 `/tmp/seed-home`（roubaai 验证 profile）。
Docker Desktop 引擎可能间歇停止；启动脚本 `F:\Workspace\start-docker.ps1`（启动后容器仍在，`docker start` 恢复）。

## 5. 关键事实与坑（勿重复踩）

1. **clean 首建 `pnpm build` 必失败**：client 面在 host `tsc -b` 阶段引用 `lib/typert.remote-client.d.ts`，而该文件只由 tsc 之后的 tsdown(typert) 生成 → 死锁。`lib/` 从不提交。→ 服务器不要构建，用「源码 + 本机产物」。
2. **`dsh plugin add @roubaai/*` 不可用**：内部跑 `pnpm add` 走 npm registry → 404（从未发布）。
3. **roubaai 每户种子的可行做法**：`pnpm pack` 成 tgz（自动把 `workspace:` 依赖改写为版本号，已验证 settings→`@deepseek-ai/schemastery:^3.18.2`、maizi peer→`@roubaai/media:^0.1.2-rc.1`）；profile `package.json` 的 `dependencies` 写 `file:/…/roubaai-*.tgz`，并把 4 名追加进 `dsh.profile.bundles`；`pnpm install` 成功。⚠ 依赖必须写成 tgz 而非 `file: 目录`（目录在 monorepo workspace 内会被 pnpm 当 workspace 链接 → `ERR_PNPM_WORKSPACE_PKG_NOT_FOUND`）。
4. **monorepo 根 `package.json` 声明 `"type":"module"`**：拷进 `/opt/deepseek-harness/{gateway,bin}` 的 CJS 组件（dsh-server-deployment 的 *.js）会被当 ESM → `require is not defined`。修复：在这两个目录各放 `package.json` `{"type":"commonjs"}`（已在 sysd 容器应用，真实服务器同样需要；这两个目录已在 .gitignore，不会污染仓库）。
5. **根 node_modules 无 `@deepseek-ai/dsh`**（apps/cli 不被根依赖）：建号/实例须注入 `DSH_DSH_BIN=/opt/deepseek-harness/apps/cli/lib/bin.js`（userctl 环境变量支持）。
6. **runtime node**：`ln -sf /usr/bin/node /opt/deepseek-harness/runtime/bin/node`（此前 `$(command -v node)` 被外层转义吞掉导致失败，用绝对路径）。
7. **userctl 一个非致命 bug**：`refreshLoopbackGuard` 把 guard 路径重复作为 args[0]（`dsh-loopback-guard --apply` 前多传一次路径），导致 refresh 永远打 usage warning——不影响建号，真实部署可顺手修。
8. 容器 netfilter 限制 → `dsh-loopback-guard` 在容器内必然失败（真实服务器无碍，验证跳过即可）。

## 6. 当前卡点（未决，需新会话继续）

**多租户实例 web 进程崩于 sandbox**：
```
Error: …failed to import loader entry sandbox (@deepseek-ai/dsh-sandbox-local):
Cannot find module '…/sandbox-local/node_modules/@deepseek-ai/node-addon-landlock-run/lib/index.js'
```
- landlock 原生模块产自 `native/landlock-run`（`build:native`，Linux），源码树形态必缺；官方 **npm 安装 dsh 自带 Linux prebuilt**。
- 矛盾待查：`rouba-dsh-test`（root，DSH_HOME=/tmp/seed-home）同样缺 landlock 却能起 200（从不触发 sandbox）；`rouba-dsh-sysd` 里 root 手跑也崩。sandbox 是否被 include 有未明触发条件（疑似与 DSH_HOME 是否在仓库树内 / loader 探测有关），尚未定位。

三个待选方向（runbook 对话最后已抛给用户，未拍板）：
1. **回官方 npm 形态（推荐优先实测）**：服务器 `npm install @deepseek-ai/dsh@0.1.2-rc.1` 到默认 `app/` 布局（自带 landlock prebuilt），roubaai 仍 tgz per-user。风险：roubaai peer 基于 fork 旧基线，需实测与公共 npm 的 0.1.2-rc.1 兼容。
2. 坚持源码树：在 Linux 额外构建 `native/landlock-run`（build:ts + build:native），并继续排查 sandbox 触发差异。
3. 禁用 sandbox：找 web profile 的 sandbox include 开关（内部隔离已由 OS 账号+loopback 承担）；开关是否存在未确认。

## 7. 建议下一步（新会话第一条动作）

在 `rouba-dsh-sysd` 内实测方向 1（几分钟出兼容性结论）：
```bash
docker exec -it rouba-dsh-sysd bash
cd /opt/deepseek-harness
# ① 官方 dsh 闭包装到默认布局（npmmirror 有 0.1.2-rc.1）
mkdir -p app && cd app && npm init -y && npm i @deepseek-ai/dsh@0.1.2-rc.1
# ② landlock prebuilt 是否随包（重点）
find node_modules -path '*landlock*' -name '*.node' | head
# ③ 以非 root 系统用户起 web（验证 sandbox 可用 + roubaai tgz 注入是否兼容官方闭包）
# 对照 sysd 已建 admin 用户 /opt/deepseek-harness/users/admin 复用（其 profile 需按 runbook §4 重置）
```
若官方闭包 + roubaai tgz 能起 200 → 定案方向 1，重写 runbook 部署节并上服务器；
若 roubaai 与官方版本不兼容 → 在方向 1 基础上给 roubaai 单独 bump 适配或评估方向 3（禁用 sandbox）。

## 8. 服务器实操的遗留输入（runbook §1 待确认清单）

OS/systemd、80/443 当前归属（宿主 vs 容器 nginx）、证书路径与续期方式、autovideo 数据量、
服务器网络（npm/GitHub 可达性）、Node 构建能力。所有服务器命令以 runbook（已验证版）为准，
唯一例外：**凡拷进 `/opt/deepseek-harness` 的 dsh-server-deployment CJS 目录（gateway/bin）都要补
`{"type":"commonjs"}` 的 package.json**（坑 §4）。
