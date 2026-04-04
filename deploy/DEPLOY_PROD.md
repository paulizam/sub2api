# Sub2API 生产发布手册

> 目标：将 `sub2api` 生产更新流程标准化，确保 **可重复、可审计、可回滚**，并且 **不影响同机其他应用**。

---

## 1. 适用场景

本手册适用于当前这类部署形态：

- 服务器目录：`/opt/sub2api/app`
- compose 文件：`/opt/sub2api/app/deploy/docker-compose.source.local.yml`
- Nginx 域名：`key.waisoft.com`
- 应用容器：`sub2api`
- 数据容器：`sub2api-postgres` / `sub2api-redis`

如果你的环境路径不同，先在脚本参数里覆盖，不要直接改脚本源码。

---

## 2. 发布原则

### 2.1 绝对边界

发布时只能操作：

- `sub2api` 的源码目录
- `sub2api` 对应 compose 文件
- `sub2api` 对应 Nginx 站点
- `sub2api` 相关备份目录

禁止：

- 全局 `docker compose down`
- 全局 `docker image prune`
- 改动无关应用容器
- 批量 reload / restart 无关服务

### 2.2 必须先备份

每次发布前至少备份：

- 生产 `.env`
- compose 文件
- 反代配置
- PostgreSQL 导出
- `data/` + `redis_data/`
- 当前镜像 inspect
- 当前容器 inspect

### 2.3 先验证再宣告完成

必须至少验证：

- `docker compose ps`
- 本机健康检查 `/health`
- 公网健康检查 `/health`
- `docker logs --tail`
- 数据库迁移状态

---

## 3. 推荐发布模式

## 模式 A：本地 build（推荐）

流程：

1. 本地拉最新代码
2. 本地 Docker build
3. `docker save` 导出镜像
4. 上传镜像包到服务器
5. 服务器 `docker load`
6. 只重建 `sub2api`

优点：

- 生产机不编译
- 可重复性最强
- 线上变更面最小

适用前提：

- 本地有 Docker

## 模式 B：远端 build（兜底）

流程：

1. 本地只打源码包
2. 上传到服务器
3. 服务器使用 Docker multi-stage build 构建新镜像
4. 只重建 `sub2api`

优点：

- 本地无 Docker 也能发布

缺点：

- 生产机会进行编译
- 构建耗时更长
- 会在 Docker 构建阶段临时拉起 `node` builder

> 结论：长期应优先用 **模式 A**，模式 B 只作兜底。

---

## 4. 关于“为什么服务器上会看到 Node”

这不是宿主机在长期运行 Node。

原因是 `Dockerfile` 使用了 multi-stage build：

```dockerfile
FROM node:24-alpine AS frontend-builder
```

这意味着：

- 执行 `docker compose build sub2api` 时
- Docker 会在构建阶段临时使用 Node 镜像打前端包
- 构建结束后，运行时镜像不常驻 Node

排查命令：

```bash
ps -ef | grep [n]ode
command -v node
docker ps --format "{{.Names}}\t{{.Image}}" | grep node
```

如果三者都空，说明只是构建阶段使用了 Node，而不是运行态依赖。

---

## 5. 标准发布脚本

本仓库已提供：

- `deploy/release-sub2api.ps1`
- `deploy/release-sub2api.sh`

二者均支持两种模式：

- `local-docker`（推荐）
- `remote-build`（兜底）

### 5.1 PowerShell 示例

#### 本地 build（推荐）

```powershell
.\deploy\release-sub2api.ps1 `
  -Host 154.217.249.161 `
  -User root `
  -Mode local-docker
```

#### 远端 build（兜底）

```powershell
.\deploy\release-sub2api.ps1 `
  -Host 154.217.249.161 `
  -User root `
  -Mode remote-build
```

### 5.2 Bash 示例

#### 本地 build（推荐）

```bash
chmod +x deploy/release-sub2api.sh
./deploy/release-sub2api.sh \
  --host 154.217.249.161 \
  --user root \
  --mode local-docker
```

#### 远端 build（兜底）

```bash
./deploy/release-sub2api.sh \
  --host 154.217.249.161 \
  --user root \
  --mode remote-build
```

---

## 6. 脚本做了什么

无论 PowerShell 还是 Bash，脚本都按如下顺序执行：

1. 检查本地 `HEAD` 是否等于 `origin/main`
2. 生成源码包
3. 创建远端 release / backup 目录
4. 上传源码包
5. 备份 `.env`、compose、站点配置、DB、数据目录、镜像与容器信息
6. 给旧镜像打回滚 tag
7. 若 `local-docker`：
   - 本地 build
   - `docker save`
   - 上传镜像 tar
   - 远端 `docker load`
8. 若 `remote-build`：
   - 远端解包源码
   - `rsync` 覆盖源码树
   - 远端 `docker compose build sub2api`
9. 仅重建 `sub2api`
10. 采集验证结果与日志

---

## 7. SSH 与认证建议

脚本默认使用：

- `ssh`
- `scp`

脚本不会保存密码。  
**推荐使用 SSH key**，否则每次脚本运行会多次交互输入密码，严重影响稳定性。

建议：

```bash
ssh-copy-id root@154.217.249.161
```

或使用独立部署账号，并限制到特定命令/主机。

---

## 8. 日志留痕

### 8.1 每次发布必须产出两类日志

#### A. 仓库内文档日志

路径：

- `docs/deploy-logs/YYYY-MM-DD-sub2api-prod-update.md`

用途：

- 人能读
- 适合复盘、审计、交接

模板：

- `docs/deploy-logs/TEMPLATE.md`

#### B. 脚本运行日志

路径：

- `docs/deploy-logs/<UTC timestamp>-runtime.log`

用途：

- 原始执行过程
- 便于排查脚本失败位置

### 8.2 远端证据目录

脚本会自动生成：

- release 目录：`/opt/sub2api/releases/<release-id>`
- backup 目录：`/opt/backups/sub2api/<release-id>`

建议至少保留最近 3 次发布记录。

---

## 9. 回滚

### 9.1 镜像回滚

```bash
cd /opt/sub2api/app/deploy
docker tag sub2api-source:backup-<release-id> sub2api-source:local
docker compose -f docker-compose.source.local.yml up -d --no-build --force-recreate sub2api
```

### 9.2 数据回滚

如果新版本迁移了数据库，而业务异常不能仅靠镜像回滚解决，则：

1. 停 `sub2api`
2. 恢复对应 release 的 `sub2api.pgcustom`
3. 必要时恢复 `sub2api.data-and-redis.tgz`
4. 再启动 `sub2api`

---

## 10. 手工核验清单

每次发布后至少执行：

```bash
docker compose -f /opt/sub2api/app/deploy/docker-compose.source.local.yml ps
curl -fsS http://127.0.0.1:18080/health
curl -k -fsS --resolve key.waisoft.com:443:127.0.0.1 https://key.waisoft.com/health
docker logs --tail 50 sub2api
docker exec sub2api-postgres psql -U sub2api -d sub2api -Atc \
  "select filename from schema_migrations order by filename desc limit 10;"
```

验收标准：

- `sub2api` 为 `healthy`
- 内外健康检查均为 `{"status":"ok"}`
- 日志无启动级报错
- 数据库迁移结果符合预期

---

## 11. 推荐后续优化

1. **给本地工作站安装 Docker**
   - 彻底切回推荐模式：本地 build → 上传镜像 → 远端 load

2. **给发布脚本接入 SSH key**
   - 避免多次交互输入密码

3. **把文档日志纳入发布流程**
   - 每次发布后必须补 `docs/deploy-logs/*.md`

4. **若后续频繁发版**
   - 可以再补：
     - 自动回滚脚本
     - 自动生成部署日志骨架
     - 发布前健康检查脚本

---

## 12. 关联文档

- 本次真实记录：`docs/deploy-logs/2026-04-05-sub2api-prod-update.md`
- 发布记录模板：`docs/deploy-logs/TEMPLATE.md`
- PowerShell 发布脚本：`deploy/release-sub2api.ps1`
- Bash 发布脚本：`deploy/release-sub2api.sh`

⚚ 此手册就是后续发版的刀谱。
