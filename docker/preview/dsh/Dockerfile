# dsh-preview 的 DSH 服务镜像：官方 npm 闭包 + roubaai 四包 tgz + 回环桥
# 形态与真实服务器「官方闭包 app 布局」一致，仅加了 socat 用于容器间暴露。
FROM node:22-slim

# socat：把 dsh web 的 127.0.0.1 监听桥到容器网络可达地址（官方 web 拒绝 0.0.0.0）。
# build-essential/python3：基线插件（dsh-ssh/better-sidebar）的原生模块
# ssh2/node-pty/cpu-features 需在 pnpm install 时本地编译（真实服务器同样需要编译链）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends socat ca-certificates build-essential python3 \
 && rm -rf /var/lib/apt/lists/* \
 && npm i -g pnpm@11

# dsh 以独立非 root 账号运行（贴近生产 dsh-<user> 形态）
RUN useradd -m -d /home/dsh -s /bin/bash dsh \
 && mkdir -p /home/dsh/dsh-home \
 && chown dsh:dsh /home/dsh/dsh-home
# 预建 DSH_HOME 并归 dsh：命名卷首次挂载会从镜像 copy-up（含属主），
# 避免卷根以 root 属主导致 dsh 用户无法初始化 profile（EACCES）。

ENV BASE=/opt/deepseek-harness
# 官方闭包（默认 app 布局；userctl 的 DSH_BIN 默认即此路径）
RUN mkdir -p "$BASE/app"
WORKDIR "$BASE/app"
RUN npm init -y >/dev/null 2>&1 && npm i @deepseek-ai/dsh@0.1.2-rc.1

# 通用插件 tgz：roubaai 四包 + Rouba 品牌包（构建上下文 preview/plugins-tgz/；
# 第三方插件 @linxin666/*、dsh-better-sidebar 等走公共 npm，不进镜像）
COPY plugins-tgz/ "$BASE/plugins-tgz/"

# 注入脚本与启动脚本
COPY dsh/inject-profile.mjs /usr/local/bin/inject-profile.mjs
COPY dsh/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/inject-profile.mjs

USER dsh
EXPOSE 3101 3102
ENTRYPOINT ["/entrypoint.sh"]
