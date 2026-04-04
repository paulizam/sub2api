# Sub2API 生产发布记录模板

> 用于每次生产发布后留档。建议文件名：`YYYY-MM-DD-sub2api-prod-update.md`

---

## 1. 基本信息

- **执行日期**：
- **执行人**：
- **本地仓库路径**：
- **目标服务器**：
- **目标应用路径**：
- **目标 compose 文件**：
- **目标域名**：
- **变更目标**：

---

## 2. 更新前现场确认

### 2.1 服务器环境

- 系统：
- 主机名：
- SSH 端口：

### 2.2 同机其他应用

列出同机运行中的其他关键应用，说明本次更新不会触碰的边界。

### 2.3 更新前容器状态

执行命令：

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
```

结果摘要：

```text
```

### 2.4 compose 项目确认

执行命令：

```bash
docker compose ls
```

结果摘要：

```text
```

### 2.5 Nginx / Caddy / 反向代理确认

- 站点配置路径：
- upstream 端口：

---

## 3. 版本判断

- 本地 commit：
- 远端当前镜像 tag / image id：
- 本次目标版本：
- 是否涉及数据库迁移：

执行命令：

```bash
```

结果摘要：

```text
```

---

## 4. 备份

### 4.1 配置备份

- `.env`
- compose 文件
- 站点配置

### 4.2 数据备份

- PostgreSQL 导出：
- `data/` 压缩：
- `redis_data/` 压缩：

### 4.3 镜像备份 / 回滚 tag

- 旧镜像：
- 回滚 tag：

### 4.4 备份目录

```text
```

---

## 5. 本地打包 / 本地构建

### 5.1 若本地 build 镜像

执行命令：

```bash
```

结果：

- 镜像 tag：
- image id：
- `docker save` 文件：
- SHA256：

### 5.2 若本地仅打源码包

执行命令：

```bash
git archive --format=tar.gz --output=<package>.tar.gz HEAD
```

结果：

- 包文件：
- SHA256：

---

## 6. 上传与部署

### 6.1 上传路径

```text
```

### 6.2 部署动作

逐条列出实际执行的关键命令：

```bash
```

### 6.3 是否仅重建 sub2api

- [ ] 是
- [ ] 否

说明：

---

## 7. 数据库迁移结果

- 更新前最高迁移：
- 更新后最高迁移：
- 新增迁移：

验证命令：

```bash
docker exec <postgres-container> psql -U <user> -d <db> -Atc \
  "select filename from schema_migrations order by filename desc limit 20;"
```

---

## 8. 验证

### 8.1 compose 状态

```bash
docker compose -f <compose-file> ps
```

结果摘要：

```text
```

### 8.2 本机健康检查

```bash
curl -fsS http://127.0.0.1:<port>/health
```

结果：

```json
```

### 8.3 公网健康检查

```bash
curl -k -fsS --resolve <domain>:443:127.0.0.1 https://<domain>/health
```

结果：

```json
```

### 8.4 日志检查

```bash
docker logs --tail 50 <container>
```

结果摘要：

```text
```

---

## 9. 问题与异常

- 问题 1：
  - 现象：
  - 根因：
  - 处理：

---

## 10. 回滚方案

### 10.1 镜像回滚

```bash
```

### 10.2 数据回滚

- 数据备份路径：
- 恢复命令：

---

## 11. 关键证据路径

- 备份目录：
- 发布包：
- 构建日志：
- 部署日志：
- 回滚 tag：

---

## 12. 结论

- [ ] 发布成功
- [ ] 已验证可用
- [ ] 回滚锚点完整
- [ ] 操作记录完整

结论摘要：
