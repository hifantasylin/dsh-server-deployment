# 迁移部署手册：autovideo → DeepSeek Harness（官方 npm 闭包 + 通用插件基线，实测定案）

> 适用：将跑 autovideo（Docker Compose，`www.roubaai.com`）的同一台服务器切换为
> DeepSeek Harness 多租户 Web（dsh-server-deployment 网关）。
>
> **本文是 v3（方向 1 + 全用户通用插件基线定案版）**。演进：
> v1 = fork 源码树 + 本机 `lib/` 产物（已废弃）；v2 = 官方 npm 闭包 + roubaai 四包 tgz；
> v3 = 在 v2 之上加入「每户通用插件基线」（本机 `.dsh-main` profile 等价物）：
> 第三方插件（better-sidebar / @linxin666 / remote-web-gateway 等）走公共 npm，
> Rouba 品牌经 profile patch 挂载。2026-09-06 在 `rouba-dsh-sysd` + `dsh-preview`
> 容器完成实测定案。

---

## 0. 关键结论（容器实测得出，部署前必读）

| # | 结论 | 部署含义 |
|---|---|---|
| 1 | **官方 npm 闭包自带 landlock 全链**：`@deepseek-ai/dsh@0.1.2-rc.1`（默认 `app/node_modules`）含 `node-addon-landlock-run`（JS）+ `-linux-x64/bin/landlock-run`（static-musl prebuilt）；`probe()` → `"full"` | 服务器只跑官方闭包，无原生构建 landlock 缺口 |
| 2 | **非 root + sandbox 全链路通过**（`runuser` 降权到 `dsh-<user>` 起 web） | userctl 实例单元（`User=dsh-<user>`）直接工作 |
| 3 | **roubaai tgz 与官方闭包兼容**；通用插件基线（第三方公共 npm + Rouba 品牌）同验证 | 每户种子 = 本文 §4 基线 |
| 4 | **dsh-server-deployment 组件天然匹配官方闭包**：`userctl.js` 默认 `DSH_BIN=$BASE/app/node_modules/@deepseek-ai/dsh/lib/bin.js`、`NODE_BIN=$BASE/runtime/bin/node` | 无需 `DSH_DSH_BIN`/`DSH_NODE_BIN` 覆盖；只需 runtime symlink |
| 5 | **roubaai/brand 发布物 = 本机构建产物 `lib/`**（`lib/` 不入 git；pnpm pack 打 lib 不打 src）。改源码不重建 = 部署旧 UI（教训：settings 曾打包旧 "视频生成" UI） | **发布流程强制**：改 fork 源码后先 `pnpm run build:lib:host`（host 面）+ `pnpm --filter <client包> bundle`（client 面）再 pack |
| 6 | **Rouba 品牌无 `dsh.bundle`**，只能经 profile `cordis.patch.yml` insert；且官方 `ui-brand-official` 占同名 slot，须先 `disabled` | 种子模板的 patch 必须含 disable + insert（§4.2） |
| 7 | 原生模块：`ssh2`/`node-pty`/`cpu-features`（@linxin666 dsh-ssh、better-sidebar 终端）需 pnpm 本地编译 | 服务器要有 build 工具链（§2.1），profile manifest 写 `pnpm.onlyBuiltDependencies` |

---

## 1. 本机（开发机）产物准备 —— 每次发布前执行

> 服务器不构建 fork 源码。以下在 Windows 开发机 `f:\deepseek-harness`（fork，干净、HEAD 即发布基线）执行。

### 1.1 若改过 fork 源码：先重建 lib 再 pack

```powershell
cd f:\deepseek-harness
pnpm run build:lib:host          # host 面 lib（含 roubaai media 等）；clean 首建可能死锁，本机增量可用
pnpm --filter @roubaai/settings bundle          # client 面（设置页/品牌等 UI 改动用）
pnpm --filter @deepseek-ai/dsh-client-ui-brand-rouba bundle
# 校验产物与源码同代：grep 关键字符串 lib/client.js 应有新版标识（如 "RoubaAI"），无则勿发布
```

### 1.2 pack 五个 fork 包 tgz

```powershell
cd f:\deepseek-harness
mkdir -p F:\Workspace\tgz
$pkgs = '@roubaai/media','@roubaai/media-maizi','@roubaai/media-mxapi','@roubaai/settings','@deepseek-ai/dsh-client-ui-brand-rouba'
foreach ($p in $pkgs) { pnpm --filter $p pack --pack-destination F:\Workspace\tgz }
```

> 产物（5 个）：`roubaai-{media,media-maizi,media-mxapi,settings}-0.1.2-rc.1.tgz`
> + `deepseek-ai-dsh-client-ui-brand-rouba-0.1.2-rc.1.tgz`。pnpm pack 自动改写 `workspace:` 依赖。

### 1.3 上传物清单

- 上表 5 个 tgz
- dsh-server-deployment 仓库（gateway/bin/units/nginx/sudoers，随 git 同步到服务器）
- 第三方插件（better-sidebar 等）**不在上传物**：服务器 pnpm install 时从公共 npm registry 拉取（服务器需可访问 npm，见 §2.1）。

---

## 2. 服务器：官方闭包 + 依赖装配

> root 执行；`BASE=/opt/deepseek-harness`。

### 2.1 前置与备份 autovideo

```bash
apt-get update && apt-get install -y curl git rsync acl iptables sudo nginx \
  build-essential python3        # 原生模块编译链（dsh-ssh/better-sidebar 用）
id dsh-gateway >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin dsh-gateway
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
npm i -g pnpm@11
# autovideo 备份：数据库 dump + docker compose 配置 + 80/443 占用与证书路径记录（见 §5）
```

### 2.2 官方闭包

```bash
install -d "$BASE/app" && cd "$BASE/app" && npm init -y
npm i @deepseek-ai/dsh@0.1.2-rc.1    # 公共 registry / npmmirror 均有；≈3-7 分钟
# 验收
ls "$BASE/app/node_modules/@deepseek-ai/" | grep landlock    # run + run-linux-x64
cd "$BASE/app" && node -e "require('@deepseek-ai/node-addon-landlock-run').probe().then(console.log)"  # "full"
node "$BASE/app/node_modules/@deepseek-ai/dsh/lib/bin.js" --version   # 0.1.2-rc.1
```

### 2.3 runtime node symlink + tgz 落位

```bash
mkdir -p "$BASE/runtime/bin"
ln -sf /usr/bin/node "$BASE/runtime/bin/node"      # 绝对路径
install -d "$BASE/plugins-tgz" -o root -g root -m 0755
cp <上传物>/*.tgz "$BASE/plugins-tgz/"              # 5 个 tgz
```

### 2.4 settings.yaml 模板（可选）

`$BASE/settings.yaml` 沿用默认即可（createHome 无模板也有内置默认）：`agent-default-model: {provider: deepseek-official, model: deepseek-v4-flash, reasoningEffort: max}`。

### 2.5 冒烟：官方闭包直跑 web

```bash
DSH_HOME=/tmp/smoke-home timeout 10 node "$BASE/app/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --host 127.0.0.1 --port 31999 --no-open >/tmp/smoke.log 2>&1 || true
grep -o 'dsh web: http.*' /tmp/smoke.log
```

---

## 3. 安装 dsh-server-deployment 组件

clone `dsh-server-deployment` 到 `/root/dsh-server-deployment`（`<SRC>`）：

```bash
install -d "$BASE"/{gateway,bin}
install -m 0644 <SRC>/gateway/server.js <SRC>/gateway/userctl.js <SRC>/gateway/auth.js \
  <SRC>/gateway/credentials.js <SRC>/gateway/store.js "$BASE/gateway/"
cp -r <SRC>/gateway/static "$BASE/gateway/"
install -m 0755 <SRC>/bin/dsh-file-* <SRC>/bin/dsh-users.sh "$BASE/bin/"
install -m 0644 <SRC>/bin/dsh-loopback-guard* "$BASE/bin/"
install -m 0755 <SRC>/units/dsh-gateway.service /etc/systemd/system/
install -m 0755 <SRC>/units/dsh-loopback-guard.service /etc/systemd/system/
# sudoers 白名单（gateway 仅限 4 个文件助手；按 README「快速部署」段写 /etc/sudoers.d/dsh-upload）
systemctl daemon-reload && systemctl enable --now dsh-loopback-guard.service dsh-gateway.service
```

> 官方形态下无需补 `{"type":"commonjs"}`（$BASE 根无 `type:module`）。网关环境
> `/etc/default/dsh-gateway` 不注入 `DSH_DSH_BIN`/`DSH_NODE_BIN`。

---

## 4. 建号与每户「通用插件基线」种子

### 4.1 建号（无需 export）

```bash
"$BASE/bin/dsh-users.sh" add admin
"$BASE/bin/dsh-users.sh" list
systemctl --no-pager status dsh-web-admin.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3101/    # 401（鉴权正常）即起
```

### 4.2 每户种子基线（固化流程）

> 每户 `profiles/web` 被改写为下表依赖 + `bundles`；`pnpm install`（第三方走 npm、
> 私有包走 `file:$BASE/plugins-tgz/*.tgz`）；`cordis.patch.yml` 使 Rouba 品牌接管品牌槽。

`seed-user.sh <user>`（root 执行；逻辑与 `docker/preview` 的注入脚本同源）：

```bash
#!/bin/bash
set -euo pipefail
U="${1:?user}"; BASE=/opt/deepseek-harness; P="$BASE/users/$U/profiles/web"
[ -f "$P/package.json" ] || { echo "profile missing: $P (先让该户实例首启一次)"; exit 1; }
systemctl stop "dsh-web-$U.service" 2>/dev/null || true
node - "$P" <<'EOF'
const fs=require('fs');const [p]=process.argv.slice(2);const tgz='/opt/deepseek-harness/plugins-tgz';
const j=JSON.parse(fs.readFileSync(p,'utf8'));
j.dependencies={
  '@deepseek-ai/dsh-client-ui-brand-rouba':`file:${tgz}/deepseek-ai-dsh-client-ui-brand-rouba-0.1.2-rc.1.tgz`,
  '@linxin666/dsh-client-ui-skill-explorer':'0.3.14','@linxin666/dsh-client-ui-skin-center':'0.3.14',
  '@linxin666/dsh-client-ui-web-ui-settings':'0.3.14','@linxin666/dsh-ssh':'0.3.14',
  '@linxin666/dsh-tool-describe-image':'0.3.14',
  '@roubaai/media':`file:${tgz}/roubaai-media-0.1.2-rc.1.tgz`,
  '@roubaai/media-maizi':`file:${tgz}/roubaai-media-maizi-0.1.2-rc.1.tgz`,
  '@roubaai/media-mxapi':`file:${tgz}/roubaai-media-mxapi-0.1.2-rc.1.tgz`,
  '@roubaai/settings':`file:${tgz}/roubaai-settings-0.1.2-rc.1.tgz`,
  'dsh-better-sidebar':'0.18.0','dsh-remote-web-gateway':'0.2.2','dsh-usage-stats':'^0.1.16'};
j.dsh.profile.bundles=['@deepseek-ai/dsh-base','@deepseek-ai/dsh-web-app','dsh-better-sidebar',
  '@linxin666/dsh-client-ui-skill-explorer','@linxin666/dsh-client-ui-skin-center',
  '@linxin666/dsh-client-ui-web-ui-settings','@linxin666/dsh-ssh','@linxin666/dsh-tool-describe-image',
  'dsh-remote-web-gateway','dsh-usage-stats',
  '@roubaai/media','@roubaai/media-maizi','@roubaai/media-mxapi','@roubaai/settings'];
j.pnpm={onlyBuiltDependencies:['node-pty','ssh2','cpu-features']};
fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n');
EOF
cat > "$P/cordis.patch.yml" <<'YAML'
# Rouba owns the brand slots: disable the shipped official occupant, then mount.
- id: ui-brand-official
  disabled: true
- insert:
    - id: roubaai-brand
      name: '@deepseek-ai/dsh-client-ui-brand-rouba'
YAML
cd "$P" && rm -rf node_modules pnpm-lock.yaml && pnpm install   # 第三方走 npm registry
chown -R "dsh-${U}:dsh-${U}" "$BASE/users/$U"
systemctl start "dsh-web-$U.service"
```

### 4.3 验证带基线的用户

```bash
"$BASE/bin/dsh-users.sh" add tenant1 && bash seed-user.sh tenant1
# 服务/鉴权
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/        # 401
# 依赖与配置树
ls "$BASE/users/tenant1/profiles/web/node_modules/" | grep -E 'linxin666|better-sidebar|remote-web-gateway|@roubaai'  # 分组目录
DSH_HOME="$BASE/users/tenant1" "$BASE/app/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --dump-config 2>/dev/null | grep -E 'roubaai-brand|ui-brand-official'   # brand insert + official disabled
```

### 4.4 Key 引导（不变）

- LLM：用户登录 `/setup` 填各自 `.credentials.yaml`（0600）；或 `dsh-users.sh set-key <user>`。
- media：用户各自在 Settings → RoubaAI 填（私有 settings，含连接测试）；**不设共享默认**。
- autovideo 旧 `.env` key 不进共享位置。

---

## 5. TLS 反代切换与下线 autovideo

1. nginx：443（沿用 autovideo 证书）→ `proxy_pass http://127.0.0.1:3100`（gateway），覆盖 XFF（只取 `$remote_addr`）、WebSocket upgrade、`client_max_body_size 100m`（模板 `nginx/dsh-https-1145.conf`，1145→443、域名/证书路径换 autovideo 实际值）。
2. 临时端口验证 → `systemctl reload nginx` 正式切换。
3. autovideo 下线：确认 443 已切走后 `docker compose down`（**保留卷/数据库**，见 §7）。

---

## 6. 上线验证清单

| # | 检查 | 期望 |
|---|---|---|
| 1 | `cd $BASE/app && node -e "require('@deepseek-ai/node-addon-landlock-run').probe().then(console.log)"` | `full` |
| 2 | `systemctl status dsh-gateway dsh-loopback-guard dsh-web-*` | active |
| 3 | `find $BASE -not -path '*/users*' -perm /022 \| wc -l` | `0` |
| 4 | 文件助手自检（README 快速部署段） | 正常；越界 exit=3；子进程属 `dsh-<user>` |
| 5 | 回环隔离：A 户 curl B 户端口 | 拒绝 |
| 6 | 建 2 租户分别登录 | 数据互不可见；各自带完整基线 |
| 7 | 每户 `node_modules`：`@linxin666/*`、`dsh-better-sidebar`、`dsh-remote-web-gateway`、`@roubaai/*`、brand 在 | 种子生效 |
| 8 | 每户 `--dump-config`：`roubaai-brand` insert 生效、`ui-brand-official` disabled | Rouba 品牌接管 |
| 9 | 页面：侧边栏（better-sidebar）、远程连接、RoubaAI 设置区块、Rouba 品牌 | 浏览器确认 |
| 10 | 每户 `/setup` 填 LLM key；Settings→RoubaAI 填 media key | 写入该户私有文件 |
| 11 | WS 会话、文件抽屉、media 生成 | 正常 |
| 12 | 原生模块：`node -e "require('node-pty')"` / `require('ssh2')`（以 dsh-<user> 或 root 在 profile 上下文） | 加载成功 |

---

## 7. 回滚 / 升级 / 运维

- **回滚**（反代/域名问题）：`systemctl stop dsh-gateway`、还原 nginx（autovideo 段）、`docker compose up -d`。用户数据在 `users/` 与 `gateway/users.json`。
- **升级**：
  1. fork 改动 → 本机 §1.1 重建 + §1.2 重打 tgz → 上传覆盖 `$BASE/plugins-tgz/`。
  2. DSH 本体：`cd $BASE/app && npm i @deepseek-ai/dsh@<新版本>`。
  3. 组件：`git -C /root/dsh-server-deployment pull` 后按 §3 重装 + 重启网关。
  4. 对**已有 roubaai/基线用户**重跑 `seed-user.sh`（node 脚本内版本/路径随之更新）；新用户建号后直接 seed。
- **日常**：`dsh-users.sh list|add|passwd|set-key|del`；日志 `journalctl -u dsh-gateway / dsh-web-<user>`。

---

## 8. 验证记录（2026-09-05/06，`rouba-dsh-sysd` + `dsh-preview`）

1. 官方闭包 `npm i` → landlock prebuilt 随包（JS loader + static-musl 二进制），`probe=full`。
2. `runuser -u dsh-admin`（uid 998 nologin）起官方 web → 200/303，进程形态正确无崩溃。
3. roubaai tgz 注入官方 auto-init profile → `--dump-config` 含 4 bundle；设置页 RoubaAI 区块出现。
4. **教训（settings 旧 UI）**：fork 改 src 未重 build → tgz 打包旧 lib（"视频生成"）。
   重建 host（`build:lib:host`）+ client（`pnpm --filter @roubaai/settings bundle`）后 label 为
   `RoubaAI`、per-category 结构。
5. **通用插件基线**：第三方 5+ 插件 + brand 装进 preview profile → web 起；`@linxin666/*`
   等 200 包经 npm registry 安装（慢 registry 换 npmmirror）。
6. **Rouba 品牌**：brand 无 `dsh.bundle`，走 bundles 会报
   `declares no dsh.bundle`；正路 = profile `cordis.patch.yml` insert，并 `disabled` 官方
   `ui-brand-official`（同名 slot）。dump 验证 insert 生效、official disabled。

【需现场】systemd 特权侧（userctl 建号写单元、loopback-guard iptables、sudoers 助手降权）
与第三方插件对 rc.1 peer 的运行时行为，须在真实服务器确认（本地特权容器受限：
loopback-guard netfilter 在容器内必失败——真实服务器无碍）。

---

## 9. 遗留待办

1. **userctl 增加 `seed <user>` 子命令**（把 §4.2 种子固化为组件能力，add 后可选用）；
   顺手修 `refreshLoopbackGuard` 重复 guard 路径 bug。
2. 第三方插件版本（better-sidebar/remote-web-gateway/@linxin666）升级前先在本地
   preview 复测与 rc.1 兼容（peer 范围 `^0.1.2-rc.1` / `^0.1.0-rc.5` 均已满足）。
3. README「安装树完整性」表述更新为官方 app 闭包 + profile 私有依赖。
4. autovideo 服务器现场 §5 采集：OS/systemd、80/443 归属、证书路径与续期、数据量、
   npm/GitHub 可达性、Node 构建能力（原生模块需编译链）。
