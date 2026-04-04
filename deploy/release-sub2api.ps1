[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Host,

    [Parameter(Mandatory = $true)]
    [string]$User,

    [int]$Port = 22,

    [ValidateSet('local-docker', 'remote-build')]
    [string]$Mode = 'local-docker',

    [string]$RemoteAppRoot = '/opt/sub2api/app',
    [string]$RemoteDeployDir = '/opt/sub2api/app/deploy',
    [string]$RemoteReleaseRoot = '/opt/sub2api/releases',
    [string]$RemoteBackupRoot = '/opt/backups/sub2api',
    [string]$RemoteDomain = 'key.waisoft.com',
    [string]$RemoteSiteConfig = '/etc/nginx/sites-available/key.waisoft.com',
    [string]$ComposeFile = 'docker-compose.source.local.yml',
    [string]$ImageRepository = 'sub2api-source',
    [string]$ImageTagAlias = 'local',
    [string]$RollbackTagPrefix = 'backup',
    [switch]$SkipDbBackup,
    [switch]$SkipRemoteHealthCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$commit = (git -C $repoRoot rev-parse HEAD).Trim()
$shortCommit = $commit.Substring(0, 8)
$packageName = "sub2api-$($commit.Substring(0,12)).tar.gz"
$packagePath = Join-Path $repoRoot $packageName
$localLogDir = Join-Path $repoRoot 'docs\deploy-logs'
$localRuntimeLog = Join-Path $localLogDir "$releaseId-runtime.log"
$remoteReleaseDir = "$RemoteReleaseRoot/$releaseId"
$remoteBackupDir = "$RemoteBackupRoot/$releaseId"
$remotePackagePath = "$remoteReleaseDir/$packageName"
$remoteComposePath = "$RemoteDeployDir/$ComposeFile"
$remoteImageVersionTag = "$ImageRepository:$shortCommit"
$remoteImageAliasTag = "$ImageRepository:$ImageTagAlias"
$remoteRollbackTag = "$ImageRepository:$RollbackTagPrefix-$releaseId"

New-Item -ItemType Directory -Force -Path $localLogDir | Out-Null
Start-Transcript -Path $localRuntimeLog -Force | Out-Null

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-SshTarget {
    return "$User@$Host"
}

function Invoke-Ssh([string]$Command) {
    $target = Get-SshTarget
    Write-Host "SSH> $Command" -ForegroundColor DarkGray
    & ssh -p $Port -o StrictHostKeyChecking=accept-new $target $Command
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed"
    }
}

function Copy-ToRemote([string]$LocalPath, [string]$RemotePath) {
    $target = Get-SshTarget
    Write-Host "SCP> $LocalPath -> ${target}:$RemotePath" -ForegroundColor DarkGray
    & scp -P $Port -o StrictHostKeyChecking=accept-new $LocalPath "${target}:$RemotePath"
    if ($LASTEXITCODE -ne 0) {
        throw "SCP upload failed"
    }
}

try {
    Write-Step "验证本地 git 版本"
    $head = (git -C $repoRoot rev-parse HEAD).Trim()
    $originMain = (git -C $repoRoot rev-parse origin/main).Trim()
    if ($head -ne $originMain) {
        throw "本地 HEAD ($head) 未对齐 origin/main ($originMain)，请先同步代码。"
    }

    if ($Mode -eq 'local-docker') {
        Write-Step "检查本地 Docker"
        $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
        if (-not $dockerCmd) {
            throw "未检测到本地 Docker。可改用 -Mode remote-build，或先安装 Docker。"
        }
    }

    Write-Step "准备发布包"
    if (Test-Path $packagePath) { Remove-Item $packagePath -Force }
    & git -C $repoRoot archive --format=tar.gz --output=$packagePath HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive 失败" }
    $packageHash = (Get-FileHash $packagePath -Algorithm SHA256).Hash.ToLower()
    Write-Host "Package: $packageName"
    Write-Host "SHA256 : $packageHash"

    if ($Mode -eq 'local-docker') {
        Write-Step "本地构建镜像并导出 tar"
        $localImageVersionTag = "$ImageRepository:$shortCommit"
        $localImageTar = Join-Path $repoRoot "$ImageRepository-$shortCommit-image.tar"
        if (Test-Path $localImageTar) { Remove-Item $localImageTar -Force }
        & docker build -t $localImageVersionTag -f (Join-Path $repoRoot 'Dockerfile') $repoRoot
        if ($LASTEXITCODE -ne 0) { throw "本地 docker build 失败" }
        & docker save -o $localImageTar $localImageVersionTag
        if ($LASTEXITCODE -ne 0) { throw "docker save 失败" }
        $imageTarHash = (Get-FileHash $localImageTar -Algorithm SHA256).Hash.ToLower()
        Write-Host "ImageTar: $localImageTar"
        Write-Host "ImageSHA: $imageTarHash"
    }

    Write-Step "创建远端发布目录"
    Invoke-Ssh "mkdir -p '$remoteReleaseDir' '$remoteBackupDir'"

    Write-Step "上传发布包"
    Copy-ToRemote $packagePath $remotePackagePath
    Invoke-Ssh "sha256sum '$remotePackagePath'"

    if ($Mode -eq 'local-docker') {
        $localImageTar = Join-Path $repoRoot "$ImageRepository-$shortCommit-image.tar"
        $remoteImageTar = "$remoteReleaseDir/$ImageRepository-$shortCommit-image.tar"
        Write-Step "上传镜像包"
        Copy-ToRemote $localImageTar $remoteImageTar
        Invoke-Ssh "sha256sum '$remoteImageTar'"
    }

    Write-Step "远端备份配置与回滚锚点"
    $dbBackupLine = if ($SkipDbBackup) {
        "echo 'skip db backup' > '$remoteBackupDir/db-backup-skipped.txt'"
    } else {
        "docker exec sub2api-postgres pg_dump -U sub2api -d sub2api -Fc > '$remoteBackupDir/sub2api.pgcustom'"
    }

    Invoke-Ssh @"
set -euo pipefail
cp '$RemoteDeployDir/.env' '$remoteBackupDir/'
cp '$remoteComposePath' '$remoteBackupDir/'
cp '$RemoteSiteConfig' '$remoteBackupDir/' 2>/dev/null || true
docker compose -f '$remoteComposePath' config > '$remoteBackupDir/docker-compose.rendered.yml'
docker inspect sub2api > '$remoteBackupDir/sub2api.container.inspect.json'
docker image inspect '$remoteImageAliasTag' > '$remoteBackupDir/sub2api.image.inspect.json'
$dbBackupLine
tar -C '$RemoteDeployDir' -czf '$remoteBackupDir/sub2api.data-and-redis.tgz' data redis_data
if docker image inspect '$remoteImageAliasTag' >/dev/null 2>&1; then
  docker tag '$remoteImageAliasTag' '$remoteRollbackTag'
fi
"@

    if ($Mode -eq 'remote-build') {
        Write-Step "远端解包并仅更新源码树"
        Invoke-Ssh @"
set -euo pipefail
SRC='$remoteReleaseDir/src'
mkdir -p "`$SRC"
rm -rf "`$SRC"/*
tar -xzf '$remotePackagePath' -C "`$SRC"
rsync -a --delete \
  --exclude 'deploy/.env' \
  --exclude 'deploy/data/' \
  --exclude 'deploy/postgres_data/' \
  --exclude 'deploy/redis_data/' \
  --exclude 'deploy/$ComposeFile' \
  "`$SRC"/ '$RemoteAppRoot'/
cd '$RemoteDeployDir'
docker compose -f '$remoteComposePath' build sub2api | tee '$remoteBackupDir/build.log'
docker tag '$remoteImageAliasTag' '$remoteImageVersionTag'
"@
    } else {
        Write-Step "远端加载本地构建镜像"
        Invoke-Ssh @"
set -euo pipefail
LOAD_OUT=`$(docker load -i '$remoteReleaseDir/$ImageRepository-$shortCommit-image.tar')
echo "`$LOAD_OUT" | tee '$remoteBackupDir/docker-load.log'
docker tag '$remoteImageVersionTag' '$remoteImageAliasTag'
"@
    }

    Write-Step "仅重建 sub2api 服务"
    Invoke-Ssh @"
set -euo pipefail
cd '$RemoteDeployDir'
docker compose -f '$remoteComposePath' up -d --no-build --force-recreate sub2api | tee '$remoteBackupDir/deploy.log'
for i in `$(seq 1 60); do
  if curl -fsS 'http://127.0.0.1:18080/health' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker compose -f '$remoteComposePath' ps > '$remoteBackupDir/compose_ps.txt'
docker logs --tail 200 sub2api > '$remoteBackupDir/sub2api.tail.log' 2>&1 || true
docker inspect sub2api --format '{{.Image}} {{.Config.Image}}' > '$remoteBackupDir/sub2api.image.current.txt'
docker image inspect '$remoteImageAliasTag' --format '{{.Id}} {{.Created}}' > '$remoteBackupDir/sub2api.image.inspect.current.txt'
docker exec sub2api-postgres psql -U sub2api -d sub2api -Atc "select filename from schema_migrations order by filename desc limit 20;" > '$remoteBackupDir/schema_migrations_after.txt'
curl -fsS 'http://127.0.0.1:18080/health' > '$remoteBackupDir/health.local.json'
"@

    if (-not $SkipRemoteHealthCheck) {
        Write-Step "公网健康检查"
        Invoke-Ssh "curl -k -fsS --resolve '$RemoteDomain:443:127.0.0.1' 'https://$RemoteDomain/health' | tee '$remoteBackupDir/health.public.json'"
    }

    Write-Step "部署完成"
    Write-Host "Commit     : $commit"
    Write-Host "ReleaseId  : $releaseId"
    Write-Host "BackupDir  : $remoteBackupDir"
    Write-Host "RollbackTag: $remoteRollbackTag"
    Write-Host "LogFile    : $localRuntimeLog"
}
finally {
    Stop-Transcript | Out-Null
}
