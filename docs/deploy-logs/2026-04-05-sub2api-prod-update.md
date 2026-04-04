# 2026-04-05 Sub2API 生产更新记录

> 目标：在 **不影响同机其他 Docker / Nginx 应用** 的前提下，将 `sub2api` 更新到最新源码版本，并保留可追查的证据链、备份点与回滚点。

---

## 1. 基本信息

- **执行日期**：2026-04-05（Asia/Shanghai）
- **本地仓库**：`D:\GO\AI\sub2api`
- **目标服务器**：`root@154.217.249.161`
- **目标应用路径**：`/opt/sub2api/app`
- **目标 compose 文件**：`/opt/sub2api/app/deploy/docker-compose.source.local.yml`
- **公网域名**：`key.waisoft.com`
- **公网反代**：`/etc/nginx/sites-available/key.waisoft.com`

---

## 2. 更新前现场确认

### 2.1 服务器基础环境

- 系统：`Ubuntu 24.04.4 LTS`
- 主机名：`ser6075293045`
- SSH：22 端口正常

### 2.2 同机其他应用

现场确认同机还运行以下应用：

- `codex2api-prod`
- `cli-proxy-api`
- `sub2api`

因此更新策略锁定为：

- **只操作 `sub2api` 对应目录与容器**
- **不执行全局 `docker compose down`**
- **不清理全局镜像/卷**
- **不修改其他 Nginx 站点**

### 2.3 更新前容器状态

执行：

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
```

关键结果：

```text
codex2api-prod     codex2api:repo-bf7fa36   Up 13 hours
sub2api            sub2api-source:local     Up 3 days (healthy)   0.0.0.0:18080->8080/tcp
sub2api-postgres   postgres:18-alpine       Up 3 days (healthy)
sub2api-redis      redis:8-alpine           Up 3 days (healthy)
cli-proxy-api      cli-proxy-api:local      Up 3 days
```

### 2.4 更新前 compose 项目确认

执行：

```bash
docker compose ls
```

关键结果：

```text
app     running(2)   /opt/codex2api/app/docker-compose.prod.yml,/opt/cliproxyapi/app/docker-compose.prod.yml
deploy  running(3)   /opt/sub2api/app/deploy/docker-compose.source.local.yml
```

### 2.5 更新前 Nginx 路由确认

执行：

```bash
sed -n '1,240p' /etc/nginx/sites-available/key.waisoft.com
```

关键结果：

```nginx
location / {
    proxy_pass http://127.0.0.1:18080;
}
```

结论：`key.waisoft.com` 对应 `sub2api`。

---

## 3. 版本判断与根因修正

### 3.1 初始误判

最初使用了本地旧 checkout 进行比对，一度得出“无需更新”的结论。  
随后重新执行：

```bash
git fetch origin --prune
git rev-parse HEAD
git rev-parse origin/main
git log --oneline -1 --decorate HEAD
git log --oneline -1 --decorate origin/main
```

发现：

- 本地最终同步后的 `HEAD`：`bf45581104cede19b7c95edf2b4e48b2627641ed`
- 旧服务器镜像构建时间：约 5 天前

结论：

- **服务器运行的 `sub2api-source:local` 不是最新源码构建产物**
- **必须执行更新**

### 3.2 本地是否直接 build

执行：

```powershell
docker version
where.exe docker
```

结果：

- 本地工作站 **无 Docker 可执行文件**

因此本次实际采用：

- **本地打最新源码包**
- **上传服务器**
- **服务器只为 `sub2api` 定点构建**

> 说明：这不是理想的长期标准路径。长期推荐方案仍然是“本地 build 镜像 → 上传镜像 → 服务器只 load + 切换”。

---

## 4. 更新前备份

### 4.1 第一组热备份

创建目录：

```text
/opt/backups/sub2api/20260404T200407Z
```

执行了以下备份动作：

```bash
cp /opt/sub2api/app/deploy/.env ...
cp /opt/sub2api/app/deploy/docker-compose.source.local.yml ...
cp /etc/nginx/sites-available/key.waisoft.com ...
docker compose -f docker-compose.source.local.yml config > docker-compose.rendered.yml
docker inspect sub2api > sub2api.container.inspect.json
docker image inspect sub2api-source:local > sub2api.image.inspect.json
docker exec sub2api-postgres pg_dump -U sub2api -d sub2api -Fc > sub2api.pgcustom
tar -C /opt/sub2api/app/deploy -czf sub2api.data-and-redis.tgz data redis_data
sha256sum * > SHA256SUMS
```

备份内容包括：

- `.env`
- `docker-compose.source.local.yml`
- `key.waisoft.com`
- `docker-compose.rendered.yml`
- `sub2api.container.inspect.json`
- `sub2api.image.inspect.json`
- `sub2api.pgcustom`
- `sub2api.data-and-redis.tgz`
- `SHA256SUMS`

### 4.2 第二组部署备份

创建目录：

```text
/opt/backups/sub2api/20260404T202430Z
```

追加保存：

- `sub2api.app-code.tgz`
- `build.log`
- `deploy.log`
- `compose_ps.txt`
- `health.local.json`
- `health.public.json`
- `schema_migrations_after.txt`
- `sub2api.image.current.txt`
- `sub2api.image.inspect.txt`
- `sub2api.tail.log`
- `target_commit.txt`
- `version_file.txt`

### 4.3 回滚镜像锚点

执行：

```bash
docker tag sub2api-source:local sub2api-source:backup-20260404T202430Z
```

结果：

- 旧镜像保留为：
  - `sub2api-source:backup-20260404T202430Z`

---

## 5. 本地打包与上传

### 5.1 生成源码包

本地执行：

```powershell
$sha=(git rev-parse --short=12 HEAD).Trim()
$pkg="sub2api-$sha.tar.gz"
git archive --format=tar.gz --output=$pkg HEAD
Get-FileHash $pkg -Algorithm SHA256
```

结果：

- 文件：`sub2api-bf45581104ce.tar.gz`
- SHA256：`c1c5c8458b595a048bd01bd70a56e3029880ba997293092bfa4b1ccb0ae23180`

### 5.2 上传到服务器

远端目录：

```text
/opt/sub2api/releases/20260404T202430Z
```

上传后验证：

```bash
sha256sum /opt/sub2api/releases/20260404T202430Z/sub2api-bf45581104ce.tar.gz
```

结果：

```text
c1c5c8458b595a048bd01bd70a56e3029880ba997293092bfa4b1ccb0ae23180
```

校验一致。

---

## 6. 远端实际更新动作

### 6.1 覆盖源码树

解包到中转目录后，执行：

```bash
rsync -a --delete \
  --exclude 'deploy/.env' \
  --exclude 'deploy/data/' \
  --exclude 'deploy/postgres_data/' \
  --exclude 'deploy/redis_data/' \
  --exclude 'deploy/docker-compose.source.local.yml' \
  "$SRC"/ /opt/sub2api/app/
```

说明：

- 保留了所有生产配置与运行数据
- 仅更新源码与通用部署文件

### 6.2 构建新镜像

执行：

```bash
cd /opt/sub2api/app/deploy
docker compose -f docker-compose.source.local.yml build sub2api
docker tag sub2api-source:local sub2api-source:bf455811
```

构建结果：

- 新镜像 ID：`d4607014d14f`
- 新 tag：
  - `sub2api-source:local`
  - `sub2api-source:bf455811`

### 6.3 切换服务

执行：

```bash
docker compose -f docker-compose.source.local.yml up -d sub2api
```

关键结果：

```text
Container sub2api Recreate
Container sub2api Recreated
Container sub2api Started
```

说明：

- 只重建了 `sub2api`
- `sub2api-postgres` 与 `sub2api-redis` 未重建

---

## 7. 数据库迁移结果

更新前最高迁移：

```text
080_create_tls_fingerprint_profiles.sql
```

更新后执行：

```bash
docker exec sub2api-postgres psql -U sub2api -d sub2api -Atc \
  "select filename from schema_migrations order by filename desc limit 12;"
```

结果最高迁移为：

```text
089_usage_log_image_output_tokens.sql
```

新增迁移覆盖：

- `081_add_group_account_filter.sql`
- `081_create_channels.sql`
- `082_refactor_channel_pricing.sql`
- `083_channel_model_mapping.sql`
- `084_channel_billing_model_source.sql`
- `085_channel_restrict_and_per_request_price.sql`
- `086_channel_platform_pricing.sql`
- `087_usage_log_billing_mode.sql`
- `088_channel_billing_model_source_channel_mapped.sql`
- `089_usage_log_image_output_tokens.sql`

---

## 8. 验证命令与结果

### 8.1 容器状态

执行：

```bash
docker compose -f /opt/sub2api/app/deploy/docker-compose.source.local.yml ps
```

结果：

```text
sub2api            Up ... (healthy)
sub2api-postgres   Up ... (healthy)
sub2api-redis      Up ... (healthy)
```

### 8.2 本机健康检查

执行：

```bash
curl -fsS http://127.0.0.1:18080/health
```

结果：

```json
{"status":"ok"}
```

### 8.3 公网健康检查

执行：

```bash
curl -k -fsS --resolve key.waisoft.com:443:127.0.0.1 https://key.waisoft.com/health
```

结果：

```json
{"status":"ok"}
```

### 8.4 当前镜像确认

执行：

```bash
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}" | grep sub2api-source
```

结果：

```text
sub2api-source  bf455811                  d4607014d14f
sub2api-source  local                     d4607014d14f
sub2api-source  backup-20260404T202430Z  d31f1dbc78e4
```

### 8.5 日志检查

执行：

```bash
docker logs --tail 20 sub2api
```

结果：

- 服务启动正常
- 已有真实 HTTP 访问
- 未见启动级报错

---

## 9. 关于“服务器为什么出现 node”

本次观察到的 “node” 痕迹，不是宿主机常驻服务。

已核验：

```bash
ps -ef | grep [n]ode
command -v node
docker ps --format "{{.Names}}\t{{.Image}}" | grep node
```

结果均为空。

原因是 `Dockerfile` 使用了 **multi-stage build**：

```dockerfile
FROM node:24-alpine AS frontend-builder
```

这意味着：

- 只要在服务器上执行 `docker compose build sub2api`
- Docker 就会在构建阶段临时使用 Node 镜像打前端包
- 运行态镜像并不常驻 node

---

## 10. 回滚方案

### 10.1 仅回滚镜像

```bash
cd /opt/sub2api/app/deploy
docker tag sub2api-source:backup-20260404T202430Z sub2api-source:local
docker compose -f docker-compose.source.local.yml up -d sub2api
```

### 10.2 若数据库迁移导致业务异常

1. 停服务：

```bash
cd /opt/sub2api/app/deploy
docker compose -f docker-compose.source.local.yml stop sub2api
```

2. 恢复数据库备份：

```text
/opt/backups/sub2api/20260404T200407Z/sub2api.pgcustom
```

3. 必要时恢复数据压缩包：

```text
/opt/backups/sub2api/20260404T200407Z/sub2api.data-and-redis.tgz
```

4. 再起服务：

```bash
docker compose -f docker-compose.source.local.yml up -d sub2api
```

---

## 11. 本次关键证据路径

- **更新前备份**：`/opt/backups/sub2api/20260404T200407Z`
- **更新执行记录**：`/opt/backups/sub2api/20260404T202430Z`
- **发布包**：`/opt/sub2api/releases/20260404T202430Z/sub2api-bf45581104ce.tar.gz`
- **目标 commit**：`bf45581104cede19b7c95edf2b4e48b2627641ed`
- **新镜像**：`sub2api-source:bf455811`
- **旧镜像回滚 tag**：`sub2api-source:backup-20260404T202430Z`

---

## 12. 结论

本次更新已完成，满足以下条件：

- 仅影响 `sub2api`
- 其他应用未受波及
- 备份完整
- 回滚锚点完整
- 数据库迁移成功
- 内外健康检查通过
- 当前线上镜像已切到 `bf455811`

⚚ 劫破。
