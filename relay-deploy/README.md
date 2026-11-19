# Zentic relay 部署（Docker + Caddy）

一台服务器上跑两个容器：`relay`（Elixir 版 zentic-relay，明文 HTTP，只在 compose 内网监听 4000）和 `caddy`（对外 80/443，自动申请证书并终结 TLS，把 WebSocket 转给 relay）。

`relay` 镜像在服务器上用本仓库源码构建：构建上下文是仓库根目录（`docker-compose.yml` 里的 `context: ..`），所以服务器上需要有完整的仓库，而不只是这个目录。

## 前提

- 一台 Linux 服务器，已装 Docker 和 Compose 插件，并能访问外网：构建时要拉 Docker Hub 的 `hexpm/elixir` 基础镜像、从 hex.pm 下载依赖、从 Debian 源装几个运行库。服务器在国内网络受限的环境时，这三处都需要自备镜像源。
- 域名的 A/AAAA 记录指向这台服务器。
- **80 和 443 必须对公网开放**（防火墙和云厂商安全组都要放行）。Caddy 靠 80 端口完成证书验证。
- 内存默认按 2 GiB 配置。机器更小或更大，就同步改 `.env` 里的两个内存值。

## 1. 把代码放到服务器

`relay-deploy/` 已提交并推送后，在服务器上克隆仓库（仓库可匿名克隆）：

```bash
git clone https://github.com/debin-ge/zentic-relay.git
```

在推送之前，或想部署本地未提交的改动时，改为把本地仓库同步过去。`--delete` 让服务器上的代码与本地完全一致，`--exclude /relay-deploy/.env` 保护服务器上已经写好的配置不被删除：

```bash
rsync -a --delete --exclude .git --exclude _build --exclude deps --exclude /relay-deploy/.env /Users/gedebin/Documents/Code/zentic/zentic-relay/ user@your-server:~/zentic-relay/
```

## 2. 配置并构建启动

进入服务器上的 `zentic-relay/relay-deploy/` 目录：

```bash
cp .env.example .env
```

编辑 `.env`，至少把 `RELAY_DOMAIN` 改成你的域名，然后构建并启动：

```bash
docker compose up -d --build
```

首次构建要编译 Elixir 依赖，比之后的增量构建慢。

## 3. 验证

```bash
docker compose ps
```

`relay` 应显示 `healthy`。然后从外部访问：

```bash
curl https://<你的域名>/health
```

期望 `{"status":"ok"}`；`/ready` 期望 `{"status":"ready"}`。`/metrics` 在公网上返回 404，这是有意的，要抓取指标请在服务器上走内网（`relay:4000/metrics`）。

## 4. 让 daemon 使用它

在运行 daemon 的机器上设置（或写入 `config.json` 的 `daemon.relay.*`）：

```text
ZENTIC_RELAY_ENABLED=true
ZENTIC_RELAY_ENDPOINT=<你的域名>:443
ZENTIC_RELAY_USE_TLS=true
```

环境变量在 daemon 启动时读取，改完需要重启 daemon，然后用新地址重新配对一次。

## 日常运维

查看日志：

```bash
docker compose logs -f relay
```

**升级：** 先给当前镜像留一个回滚标签：

```bash
docker tag zentic-relay:local zentic-relay:previous
```

再更新服务器上的代码（在仓库根目录 `git pull`，或按第 1 步重新同步），然后在 `relay-deploy/` 里重新构建并重启：

```bash
docker compose up -d --build
```

**回滚：** 把留好的标签改回去，不重新构建直接重建容器：

```bash
docker tag zentic-relay:previous zentic-relay:local && docker compose up -d --no-build
```

重启或升级 relay 会断开所有在线会话，客户端会自动重连。`caddy_data` 卷保存证书，不要删除，否则每次重建都会重新申请，容易触发 Let's Encrypt 的频率限制。

## 不在这里的内容

多节点集群需要 `RELEASE_NODE`、`RELEASE_COOKIE` 和按 `x-reroute-target` 响应头转发的代理适配，见仓库根目录的 `README.md`。这套单机配置不涉及。
