# 迁移部署手册：autovideo → DeepSeek Harness（多租户，已验证版）

> 适用：将跑 autovideo（Docker Compose，`www.roubaai.com`）的同一台服务器切换为
> `rouba-dsh` 源码树 + 构建产物 + `dsh-server-deployment` 多租户网关。
>
> 本版流程已经过本地 Linux 容器（`node:22-slim`）**实际验证**：
> 见文末「验证记录」。标注【需现场】的是只有真实服务器/systemd 特权环境才能完成的点。

---

## 0. 关键结论（本地实验得出，部署前必读）

| # | 结论 | 部署含义 |
|---|---|---|
| 1 | 当前 `media-rouba-pure-plugins` 分支 **clean clone 后 `pnpm build` 必失败**（client 面在 host tsc 阶段引用 `lib/typert.remote-client.d.ts`，而该文件只由 tsc 之后的 tsdown 生成 → 首建死锁；`lib/` 从未提交） | **服务器不做 tsc/tsdown 构建**；改用「源码 + 已构建产物」形态 |
| 2 | 「真实 clone + 本机构建产物（各包 `lib/` + `apps/web/dist`）」下 `dsh --profile web` 正常起、页面 200 | 路线 B 成立，本手册按此编写 |
| 3 | `dsh plugin add @roubaai/*` 会从 npm registry 拉取 → 404（这些包从未发布），**不可用** | 弃用；改「本地 pack tgz」 |
| 4 | roubaai 四包 `pnpm pack` 成 tgz 后内部 `workspace:` 依赖被改写为版本号；profile 的 `dependencies` 用 `file:`.tgz + `dsh.profile.bundles` 追加 4 名 → `pnpm install` 成功，带 roubaai 的 web 起 200 | **每户种子 = 复制「已装好 4 个 tgz 的 profile」** |
| 5 | 仓库根 `node_modules` 里没有 `@deepseek-ai/dsh`（apps/cli 不被根依赖） | 覆盖 `DSH_DSH_BIN` 指向 `apps/cli/lib/bin.js` |

目标拓扑、安装树布局、决策（域名/证书/key 策略）沿用 v1 版，不重复。

---

## 1. 本机（开发机）产物准备 —— 每次发布前执行

> 服务器不构建。以下在 Windows 开发机 `f:\deepseek-harness` 执行一次，产出两个 tar 上传。

### 1.1 构建 lib 与前端（若源码有改动）

```powershell
pnpm install
pnpm run build:lib:host        # tsc + tsdown（含 typert 生成）；clean 首建可能死锁，
                               # 本机增量可用；改过源码且构建异常时，用已存 lib 的机器做基线
pnpm run build:web             # apps/web/dist
```

> 注意：本机曾成功构建，`lib/` 与当前 HEAD 源码一致即为有效产物。若改过 TS 源码需重建。
> 服务器只认与 `git clone` 的 HEAD **同一 commit** 的产物。

### 1.2 收集产物 tar

已有脚本：`F:\Workspace\collect-lib.ps1`（把各包 `lib/` + `apps/web/dist` 的相对路径写入
`lib-filelist.txt`）。在开发机执行后打包：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\Workspace\collect-lib.ps1
cd /d f:\deepseek-harness && tar -cf <上传用>/prod-lib.tar -T <上传用>/lib-filelist.txt
```

### 1.3 pack roubaai 四包 tgz

```bash
mkdir -p <上传用>/tgz
cd f:\deepseek-harness
pnpm --filter @roubaai/media pack --pack-destination <上传用>/tgz
pnpm --filter @roubaai/media-maizi pack --pack-destination <上传用>/tgz
pnpm --filter @roubaai/media-mxapi pack --pack-destination <上传用>/tgz
pnpm --filter @roubaai/settings pack --pack-destination <上传用>/tgz
```

> 产物：`roubaai-{media,media-maizi,media-mxapi,settings}-0.1.2-rc.1.tgz`
> （本地已验证 tgz 内 `workspace:` 依赖已改写为版本号，如 `@deepseek-ai/schemastery: ^3.18.2`、
> peer `@roubaai/media: ^0.1.2-rc.1`）。

上传物清单：`prod-lib.tar`、4 个 roubaai tgz。

---

## 2. 服务器：源码 + 产物装配

> root 执行；`BASE=/opt/deepseek-harness`。

### 2.1 前置与备份 autovideo

```bash
apt-get update && apt-get install -y curl git rsync acl iptables sudo nginx
id dsh-gateway >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin dsh-gateway
# Node 22 + pnpm（仅 pnpm install 用，不跑 tsc）
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
npm i -g pnpm@11
# autovideo 备份（数据库/端口记录），参考 v1 版 §3.1
```

### 2.2 clone + 装依赖

```bash
git clone -b media-rouba-pure-plugins git@github.com:hifantasylin/rouba-dsh.git /opt/deepseek-harness
cd /opt/deepseek-harness
pnpm install        # 只装依赖，约 1 分钟内（store 复用则秒级）
```

### 2.3 放置构建产物

```bash
tar xf <上传物>/prod-lib.tar -C /opt/deepseek-harness
# 校验关键产物
test -f /opt/deepseek-harness/apps/cli/lib/bin.js && echo CLI_OK
test -f /opt/deepseek-harness/packages/roubaai-video-plugin/media/lib/index.js && echo MEDIA_LIB_OK
find /opt/deepseek-harness/packages -name 'typert.remote-client.d.ts' | head -1
```

### 2.4 放置 roubaai tgz + runtime node

```bash
install -d /opt/deepseek-harness/plugins-tgz
cp <上传物>/tgz/roubaai-*.tgz /opt/deepseek-harness/plugins-tgz/
mkdir -p /opt/deepseek-harness/runtime/bin
ln -sf "$(command -v node)" /opt/deepseek-harness/runtime/bin/node
# DSH 本体路径覆盖（userctl 生成实例单元时注入环境变量）
mkdir -p /opt/deepseek-harness/gateway
chown root:dsh-gateway /opt/deepseek-harness/gateway
```

### 2.5 冒烟：直接跑 dsh（不构建）

```bash
cd /opt/deepseek-harness
DSH_HOME=/tmp/smoke-home timeout 8 node apps/cli/lib/bin.js --profile web \
  --host 127.0.0.1 --port 31999 --no-open >/tmp/smoke.log 2>&1 || true
grep -o 'dsh web: http.*' /tmp/smoke.log   # 出现 URL 即成功
```

---

## 3. 安装 dsh-server-deployment 组件

clone `dsh-server-deployment` 到 `/root/dsh-server-deployment`（`<SRC>`），按 v1 版 §4 不变：

```bash
# gateway 代码 + bin 助手 + systemd 单元 + sudoers 白名单 + settings.yaml 模板
# 全部命令与 v1 版 §4 相同（前缀恰好就是 /opt/deepseek-harness，无需 sed）
systemctl enable --now dsh-loopback-guard.service dsh-gateway.service
(cd /opt/deepseek-harness/gateway && node _unit.js)
```

### 网关环境（/etc/default/dsh-gateway）追加 DSH 覆盖

```bash
cat > /etc/default/dsh-gateway <<'EOF'
# 网关自身环境（v1 版已含 COOKIE_SECURE 等）；实例路径覆盖在 userctl 调用时注入
EOF
```

> 网关本身不跑 dsh，实例单元由 `dsh-users.sh` 生成；路径覆盖通过调用
> `dsh-users.sh` 时的环境变量注入（见 §4.1），或在 userctl 统一加默认。

---

## 4. 建号与每户 roubaai 种子（固化流程）

### 4.1 环境变量（建号与实例单元共用）

`userctl.js` 读取这些环境变量（命令前缀一致即可）：

```bash
export DSH_DSH_BIN=/opt/deepseek-harness/apps/cli/lib/bin.js
export DSH_NODE_BIN=/opt/deepseek-harness/runtime/bin/node
# DSH_BASE_DIR / USERS_DIR 等默认即 /opt/deepseek-harness，无需改
```

### 4.2 先建一个用户跑通官方 web（暂不带 roubaai）

```bash
/opt/deepseek-harness/bin/dsh-users.sh add admin
/opt/deepseek-harness/bin/dsh-users.sh list
systemctl --no-pager status dsh-web-admin.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3101/    # 200/30x
```

### 4.3 制作 roubaai profile 模板（一次性）

> 机制（已验证）：roubaai 四包以 `file:` 指向 `/opt/deepseek-harness/plugins-tgz/*.tgz`
> 加入每户 `profiles/web/package.json` 的 `dependencies`，并把 4 个包名追加进
> `dsh.profile.bundles`，然后 `pnpm install`。

```bash
# 1) 初始化一个带 roubaai 的 web profile（临时 DSH_HOME）
DSH_HOME=/tmp/seed-home $DSH_NODE_BIN $DSH_DSH_BIN --profile web \
  --host 127.0.0.1 --port 32999 --no-open &
sleep 6 && kill %1 2>/dev/null     # 首启生成 profiles/web；起后即可停

# 2) 改写 profiles/web/package.json（node 脚本，等价于 seed-profile2.js）
#    dependencies 置为 4 个 file:...tgz；bundles 追加 4 名
#    （逻辑见 F:\Workspace\seed-profile2.js，路径换成 /opt/deepseek-harness/plugins-tgz）

# 3) 安装
cd /tmp/seed-home/profiles/web && rm -rf node_modules pnpm-lock.yaml && pnpm install
ls node_modules/@roubaai           # media media-maizi media-mxapi settings

# 4) 抽为模板（去掉不该继承的东西）
install -d /opt/deepseek-harness/templates
cp -r /tmp/seed-home/profiles /opt/deepseek-harness/templates/home-seed-profiles
rm -f /opt/deepseek-harness/templates/home-seed-profiles/web/cordis.patch.yml
```

### 4.4 建号钩子（把种子给每个新用户）

```bash
# add 之后、实例启动前执行（固化为脚本，挂到 dsh-users.sh add 流程后）：
# seed-user.sh <user>
U=/opt/deepseek-harness/users/$1
systemctl stop dsh-web-$1.service 2>/dev/null
cp -r /opt/deepseek-harness/templates/home-seed-profiles "$U/profiles"
chown -R dsh-$1:dsh-$1 "$U/profiles"
systemctl start dsh-web-$1.service
```

### 4.5 验证带 roubaai 的用户

```bash
/opt/deepseek-harness/bin/dsh-users.sh add tenant1 && bash seed-user.sh tenant1
curl -s -L -c /tmp/ck -b /tmp/ck -o /dev/null -w '%{http_code}\n' \
  "http://127.0.0.1:$(/opt/deepseek-harness/bin/dsh-users.sh list | awk '$1=="tenant1"{print $2}')/…"
# 页面 200；媒体 Settings 项出现（需浏览器确认）
```

### 4.6 Key 引导

- LLM：用户登录 `/setup` 引导，写各自 `.credentials.yaml`（0600）。也可 `dsh-users.sh set-key <user>`。
- media：用户各自在 Settings 页填（存私有 settings）。**不设共享默认**。
- autovideo 旧 `.env` key 不进共享位置（DeepSeek key 转 admin 预置；麦子 key 归户自填）。

---

## 5. TLS 反代切换与下线 autovideo

nginx server 段与切换顺序同 v1 版 §6（443 → 127.0.0.1:3100，覆盖 XFF，
沿用 autovideo 证书；先验证临时端口 → 切 443 → 停 compose 保留卷）。

---

## 6. 上线验证清单（合并 v1 版 + 新流程）

| # | 检查 | 期望 |
|---|---|---|
| 1 | `node $BASE/gateway/_unit.js` | pass |
| 2 | `systemctl status dsh-gateway dsh-loopback-guard dsh-web-*` | active |
| 3 | `find $BASE -not -path '*/users*' -perm /022 \| wc -l` | `0` |
| 4 | 文件助手自检（README 步骤3） | 正常；越界 exit=3；`runuser` 子进程属 `dsh-<user>` |
| 5 | 回环隔离：A 户 curl B 户端口 | 拒绝 |
| 6 | 建 2 租户分别登录 | 数据互不可见；各自带 roubaai（Settings/工具） |
| 7 | 每户 `node_modules/@roubaai` 存在；web 200 | 种子生效 |
| 8 | `/setup` 填 LLM key；Settings 填 media key | 写入该户私有文件 |
| 9 | WS 会话、文件抽屉、media 生成 | 正常 |
| 10 | `git -C $BASE status --short` | 干净（运行数据被 .gitignore 排除） |

---

## 7. 回滚 / 升级 / 运维

- 回滚：反代/域名问题恢复 autovideo（停 gateway、`docker compose up -d`、切回旧 nginx）；
  用户数据在 `users/` 与 `gateway/users.json`，`dsh-users.sh del` 清理。
- 升级：本机重新执行 §1（新产物+tgz）→ 服务器 `git pull && pnpm install`（依赖若变）
  → 解压新产物覆盖 → 已有用户 profile 若锁旧 roubaai 版本则重跑 §4.3-4.4 种子
  → 安装树写位自检 → 重启实例与网关。
- 日常：`dsh-users.sh list|add|set-key|passwd|del`；日志 `journalctl -u dsh-gateway / dsh-web-<user>`。

---

## 8. 验证记录（本地容器 `node:22-slim`，2026-09-05）

1. 真实 `git clone`（deploy key）成功 → `pnpm install` 成功 → `pnpm build` **失败**
   （`Cannot find module '@deepseek-ai/…/remote'`，40+ 处，typert 首建死锁）→ 确认不做服务器构建。
2. 上传本机 `lib/` 产物后，不跑 tsc/tsdown：`node apps/cli/lib/bin.js --help` OK；
   `dsh --profile web` 启动并返回 **200**。
3. `dsh plugin add @roubaai/*` → registry 404（不可用）。
4. roubaai 四包 `pnpm pack` → tgz 内 `workspace:` 改写为版本号；profile `file:`.tgz 依赖
   + bundles 追加 → `pnpm install` 成功（7 包）→ 带 roubaai 的 web 起 **200**。

【需现场】systemd 特权侧（userctl 建号写单元、loopback-guard、sudoers 助手降权）必须在
真实服务器或特权 systemd 容器验证；peer 解析在真实 home 路径（`users/<u>` 向上命中
仓库根 node_modules）应成立，建议 §4.5 双租户用例确认。
