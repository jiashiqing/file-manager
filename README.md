# file-manager · 文件管理系统

零依赖 Node 文件管理系统：上传（拖拽/多文件/进度条）、下载、搜索、删除、分页、上传 IP 记录、存储路径可配置。

- 本地运行：`node server.js` → http://localhost:8199（Windows 双击 `start.bat`）
- 服务器部署：见 [部署指南.md](部署指南.md)（git 仓库即部署目录，systemd + Nginx + 自动回滚）

---

## deploy.conf 参数详解

`deploy/deploy.conf.example` 是部署配置模板。把参数写进配置文件后，`setup.sh` / `pull-deploy.sh` / `selfcheck.sh` 都能零传参找到它，不用每次敲一长串环境变量。

**用法**：复制成 `deploy/deploy.conf`（跟代码走，可进 git），或放仓库外 `/etc/<名字>/deploy.conf`。格式为纯 `KEY=VALUE`，一行一条，`#` 开头是注释。脚本按白名单解析，**不会 source / eval**，写进 `$(rm -rf …)` 也只是普通字符串。

**两个永远不进配置文件的键**：
- `WEB_PASS`（口令）——只能命令行传：`WEB_PASS=xxx sudo -E ... bash deploy/setup.sh`
- `APP_DIR`（代码目录）——始终以当前目录 / 命令行为准，防止仓库搬走后被旧路径覆盖

### 身份与目录

| 参数 | 示例值 | 含义 |
| --- | --- | --- |
| `APP_NAME` | `file-manager` | 应用名，小写字母/数字/连字符。`SVC`、`RUN_USER` 都从它派生；纯中文目录名会退化成 `app-<6位校验和>` |
| `SVC` | `file-manager` | systemd 服务名 = Nginx 配置文件名（`/etc/systemd/system/<SVC>.service`）。同机装第二个实例必须换名，否则 Nginx 报 duplicate upstream |
| `DATA_DIR` | `/data/web/file-manager/files` | 数据目录（本项目 = 上传文件的存放目录）。**永不覆盖、永不删除**，每次发版前自动备份这里。必须已被 `.gitignore` 排除，否则部署会覆盖线上数据 |

### 端口与访问

| 参数 | 示例值 | 含义 |
| --- | --- | --- |
| `WEB_PORT` | `8090` | 对外端口（Nginx 监听）。有域名时强制 80/443。**云安全组必须手动放行** |
| `BACKEND_PORT` | `8091` | 应用内部端口，只监听 127.0.0.1，外网摸不到。systemd 注入 `PORT` + `BIND_HOST` 给应用 |
| `PUBLIC_URL` | `http://1.2.3.4:8092` | 对外完整地址（含协议+端口）。会写进 systemd 的 `Environment=`，供应用生成二维码/回调地址用。**端口必须等于 `WEB_PORT`**，写错会出现「页面能开、扫码进不去」。不需要就删掉这行 |
| `MODE` | `basic` | 访问控制三选一：`basic`=口令弹窗（默认，密码自动生成或 `WEB_PASS` 指定）；`ipallow`=只放行指定网段（校园网用）；`open`=完全不设防（纯内网临时演示） |
| `ALLOW_CIDR` | `203.0.113.0/24` | 仅 `MODE=ipallow` 时必填，放行的网段，多个空格分隔 |
| `WEB_USER` | `teacher` | 仅 `MODE=basic` 时的登录用户名，默认 = `APP_NAME` |

### 健康检查与上传

| 参数 | 示例值 | 含义 |
| --- | --- | --- |
| `HEALTH` | `/api/ping` | 内部探针路径。发版后探 15 秒，不通自动回滚——**路径写错 = 每次部署都被误判失败**。本项目已内置 `/api/ping` |
| `SSE_PATH` | `none` | 实时推送（Server-Sent Events）路径，Nginx 对它单独关缓冲。无 SSE 写 `none` |
| `LIMIT_RE` | `^/api/upload` | Nginx 写接口限速的 location 正则（防恶意刷接口）。按项目实际接口改 |
| `MAX_BODY` | `2g` | Nginx 上传体积上限。**要和应用层上限一致**（本项目应用层 2GB），否则大文件传到一半被 Nginx 掐断报 413 |

### 运行时

| 参数 | 示例值 | 含义 |
| --- | --- | --- |
| `RUNTIME` | `node` | 运行时类型：`node` / `python` / `static`（一般自动识别，不用写） |
| `ENTRY` | `server.js` | 入口文件 |
| `NODE_MIN` | `22.13` | Node 最低版本，低于它自动装 Node 22.x。本项目 `>=16` 即可 |
| `NODE_CHECK` | 空 | 启动前验证某个内置模块能加载（如 `node:sqlite`）。本项目零依赖，留空 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像。国内服务器必填，否则 `npm install` 卡死。本项目零依赖，其实用不上 |
| `EXTRA_ENV` | `SA_BEHIND_PROXY=1` | 额外环境变量（空格分隔多个），写进 systemd 的 `Environment=` 行，应用通过 `process.env` 读 |

### 部署行为

| 参数 | 示例值 | 含义 |
| --- | --- | --- |
| `BRANCH` | `main` | 默认拉取的分支 |
| `BACKUP_DIR` | `/data/backup` | 发版前数据备份的落点 |
| `BACKUP_KEEP` | `20` | 备份保留份数，超出自动清理 |
| `HIST_KEEP` | `50` | 部署历史（`pull-deploy.sh --list` 看到的）保留条数 |

### 配置文件的发现顺序（先命中先用）

```
DEPLOY_ENV_FILE=<路径>          # 临时指定，优先级最高
deploy/deploy.conf              # 跟代码走（仅参数永不改时用）
/etc/git-repo-deploy/apps.conf  # 中央索引：一行一个 APP_DIR=配置路径
/etc/git-repo-deploy/<目录名>.conf  # 约定路径，免索引
.deploy/env                     # setup.sh 自动生成的参数快照
```

优先级：**命令行显式传入 > 配置文件 > 脚本默认值**。

### ⚠ 边界提醒

- 配置**属于这台机器**（要随时调端口/模式）→ 放仓库外 `/etc`，别进 git；配置**属于项目且永不改** → 才可以 `deploy/deploy.conf` 跟代码走
- 不带「git-repo-deploy 部署参数快照」首行标记的手写配置，`setup.sh` 按只读处理不会覆盖；想让脚本托管才加 `DEPLOY_ENV_FORCE_SAVE=1`
- 白名单外的键被静默忽略，拼错不报错——对照 `deploy.conf.example` 逐行核

## 本项目推荐配置（供复制）

```bash
APP_NAME=file-manager
SVC=file-manager
DATA_DIR=/data/web/file-manager/files
WEB_PORT=8090
BACKEND_PORT=8091
MODE=basic
HEALTH=/api/ping
SSE_PATH=none
MAX_BODY=2g
BRANCH=main
```

`WEB_PASS` 命令行传：`WEB_PASS=你的密码 sudo -E bash deploy/setup.sh`
