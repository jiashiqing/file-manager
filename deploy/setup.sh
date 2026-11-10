#!/usr/bin/env bash
# =====================================================================
#  git-repo-deploy · 首次部署（git 仓库原地部署）
#  支持 Ubuntu 20.04+ / Debian 11+ / Rocky 8+ / Alma 8+（glibc ≥ 2.28）
# ---------------------------------------------------------------------
#  推荐用法（先把仓库 clone 到最终位置，再原地部署）：
#    git clone https://github.com/you/app.git /data/web/app
#    cd /data/web/app
#    sudo -E APP_DIR="$(pwd)" WEB_PORT=8090 bash deploy/setup.sh
#
#  解耦用法（脚本单独放 /opt/git-repo-deploy，配置放 /etc，项目里不留 deploy/）：
#    cd /data/web/app
#    sudo -E bash /opt/git-repo-deploy/setup.sh
#  配置文件由 deploy_env_path() 自动发现，详见 SKILL.md「解耦部署」。
#
#  有域名（自动申请 HTTPS）：
#    sudo -E APP_DIR="$(pwd)" bash deploy/setup.sh app.example.com
#
#  ⚠ sudo 会清空环境变量，变量必须写在 sudo -E 之后、bash 之前。
#
#  重复执行是安全的：DATA_DIR 永不覆盖，已有数据库会保留。
#  装完以后的日常更新用 deploy/pull-deploy.sh，不要重复跑本脚本。
#  首次部署会把本次参数写成配置快照，之后更新 / 体检自动沿用，
#  不用再重传 SVC / DATA_DIR / HEALTH。命令行显式传的始终优先。
#  配置文件自动发现：DEPLOY_ENV_FILE > 项目 deploy/deploy.conf >
#  /etc/git-repo-deploy/apps.conf 索引 > /etc/git-repo-deploy/<目录名>.conf
#  > $APP_DIR/.deploy/env。详见 SKILL.md「解耦部署」。
#  手写配置（首行没有生成标记）默认只读，setup.sh 不会覆盖它。
# =====================================================================
set -euo pipefail

# >>> deploy-env
# 部署参数配置：setup.sh 写，pull-deploy.sh / selfcheck.sh 读。
# 格式是纯 KEY=VALUE（一行一条）。这里刻意**不 source、不 eval**：
# 文件里的 $(...) / 反引号 / 分号都只是普通字符串，绝不会被当命令执行。
# setup.sh / pull-deploy.sh / selfcheck.sh 三处这一段必须逐字一致，
# 由 scripts/render_test.sh 抽取比对。
DEPLOY_ENV_KEYS="APP_NAME SVC RUN_USER APP_DIR DATA_DIR WEB_PORT BACKEND_PORT PUBLIC_URL RUNTIME ENTRY START_CMD NODE_MIN NODE_CHECK NPM_REGISTRY BUILD_CMD HEALTH SSE_PATH LIMIT_RE MAX_BODY MODE BRANCH BACKUP_DIR BACKUP_KEEP HIST_KEEP EXTRA_ENV ENV_FILE WEB_USER ALLOW_CIDR EMAIL BIZ_URLS"

# 记录「脚本启动时环境里已经存在的变量」= 调用方显式传参。
# 必须在任何 ${VAR:-默认值} 之前调用，否则分不清显式值和脚本自己填的默认值。
deploy_env_snapshot() {
  local k
  DEPLOY_EXPLICIT_KEYS=""
  for k in $DEPLOY_ENV_KEYS; do
    if [ "${!k+x}" = x ]; then DEPLOY_EXPLICIT_KEYS="$DEPLOY_EXPLICIT_KEYS $k "; fi
  done
  export DEPLOY_EXPLICIT_KEYS
}

deploy_env_is_explicit() {
  case " ${DEPLOY_EXPLICIT_KEYS:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

# 配置文件发现顺序（先命中先用）：
#   ① DEPLOY_ENV_FILE 显式指定
#   ② $APP_DIR/deploy/deploy.conf          跟代码走，进仓库
#   ③ 中央索引里按 APP_DIR 查到的路径（默认 /etc/git-repo-deploy/apps.conf）
#   ④ /etc/git-repo-deploy/<目录名>.conf   约定路径
#   ⑤ $APP_DIR/.deploy/env                老部署兼容 / 脚本生成的快照
# 脚本放到 /opt/git-repo-deploy 等仓库外目录时，靠 ③④ 也能零传参找到配置。
# 索引格式：每行 APP_DIR=配置路径，# 开头是注释。
deploy_env_path() {
  local app_dir="${1:-.}" idx line k v conv base
  if [ -n "${DEPLOY_ENV_FILE:-}" ]; then printf '%s' "$DEPLOY_ENV_FILE"; return 0; fi
  if [ -r "$app_dir/deploy/deploy.conf" ]; then
    printf '%s' "$app_dir/deploy/deploy.conf"; return 0
  fi
  idx="${GIT_REPO_DEPLOY_INDEX:-/etc/git-repo-deploy/apps.conf}"
  if [ -r "$idx" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      k="${line%%=*}"
      if [ "$k" = "$line" ]; then continue; fi
      v="${line#*=}"
      if [ "$k" = "$app_dir" ] && [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done < "$idx"
  fi
  base="${app_dir%/}"; base="${base##*/}"
  conv="/etc/git-repo-deploy/$base.conf"
  if [ -r "$conv" ]; then printf '%s' "$conv"; return 0; fi
  printf '%s/.deploy/env' "$app_dir"
}

# 读配置文件。优先级：命令行显式 > 配置文件 > 脚本默认值。
# APP_DIR 刻意不从文件读：仓库可能被整体搬走，旧路径会把新位置盖掉。
deploy_env_load() {
  local f="${1:-}" line="" k="" v=""
  DEPLOY_ENV_LOADED=0
  if [ -z "$f" ] || [ ! -r "$f" ]; then return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    if [ "$k" = "$line" ]; then continue; fi
    if [ "$k" = "APP_DIR" ]; then continue; fi
    case " $DEPLOY_ENV_KEYS " in *" $k "*) ;; *) continue ;; esac
    if deploy_env_is_explicit "$k"; then continue; fi
    v="${line#*=}"
    printf -v "$k" '%s' "$v"
    DEPLOY_ENV_LOADED=1
  done < "$f"
  export DEPLOY_ENV_LOADED
}

# 判断文件是不是脚本自己生成的快照（首行带生成标记）。
deploy_env_is_generated() {
  local f="$1" first=""
  [ -r "$f" ] || return 1
  IFS= read -r first < "$f" 2>/dev/null || true
  case "$first" in *'git-repo-deploy 部署参数快照'*) return 0 ;; esac
  return 1
}

# 把本次生效的参数写成快照。手写配置（首行没有生成标记）默认只读不改写，
# 只有 DEPLOY_ENV_FORCE_SAVE=1 才会覆盖。返回 0 成功 / 1 失败 / 2 只读跳过。
deploy_env_save() {
  local f="${1:-}" dir k="" v="" tmp
  if [ -z "$f" ]; then return 1; fi
  if [ -f "$f" ] && ! deploy_env_is_generated "$f"; then
    [ "${DEPLOY_ENV_FORCE_SAVE:-0}" = "1" ] || return 2
  fi
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$f.tmp.$$"
  {
    printf '%s\n' '# git-repo-deploy 部署参数快照（自动生成，可手工改）'
    printf '%s\n' '# 纯 KEY=VALUE；脚本按白名单解析，不会执行文件内容。'
    printf '%s\n' '# 优先级：命令行显式传入 > 本文件 > 脚本默认值。'
    for k in $DEPLOY_ENV_KEYS; do
      if [ "$k" = "WEB_PASS" ]; then continue; fi
      v="${!k-}"
      case "$v" in *$'\n'*|*$'\r'*) continue ;; esac
      if [ -z "$v" ]; then continue; fi
      printf '%s=%s\n' "$k" "$v"
    done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}
# <<< deploy-env


deploy_env_snapshot

DOMAIN="${1:-}"

# ---------------------------------------------------------------- 参数
APP_NAME="${APP_NAME:-}"
SVC="${SVC:-}"
RUN_USER="${RUN_USER:-}"
APP_DIR="${APP_DIR:-}"
DATA_DIR="${DATA_DIR:-}"
WEB_PORT="${WEB_PORT:-80}"
BACKEND_PORT="${BACKEND_PORT:-8091}"
RUNTIME="${RUNTIME:-}"
ENTRY="${ENTRY:-}"
START_CMD="${START_CMD:-}"
NODE_MIN="${NODE_MIN:-22.13}"
NODE_CHECK="${NODE_CHECK:-}"
NPM_REGISTRY="${NPM_REGISTRY:-}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
BUILD_CMD="${BUILD_CMD:-}"
HEALTH="${HEALTH:-/api/ping}"
SSE_PATH="${SSE_PATH:-/api/stream}"
LIMIT_RE="${LIMIT_RE:-^/api/(result|heartbeat|auth|reset|schools|materials|codes|import|unified)}"
MAX_BODY="${MAX_BODY:-32m}"
MODE="${MODE:-basic}"
WEB_USER="${WEB_USER:-}"
WEB_PASS="${WEB_PASS:-}"
ALLOW_CIDR="${ALLOW_CIDR:-}"
EMAIL="${EMAIL:-}"
PUBLIC_URL="${PUBLIC_URL:-}"
ENV_FILE="${ENV_FILE:-}"
EXTRA_ENV="${EXTRA_ENV:-}"
BIZ_URLS="${BIZ_URLS:-}"
NO_NGINX="${NO_NGINX:-0}"
NO_CERTBOT="${NO_CERTBOT:-0}"
I_KNOW="${I_KNOW:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT="$(cd "$SCRIPT_DIR/.." && pwd)"
# 脚本在项目内（父目录有 .git / package.json）→ 源码在父目录；
# 脚本被单独放到 /opt/git-repo-deploy 等位置 → 源码取当前工作目录。
# 想从任意目录调用，显式传 SRC 或 APP_DIR。
if [ -d "$SCRIPT_PARENT/.git" ] || [ -f "$SCRIPT_PARENT/package.json" ]; then
  SRC="${SRC:-$SCRIPT_PARENT}"
else
  SRC="${SRC:-${APP_DIR:-$PWD}}"
fi
# 模板跟脚本走：解耦部署后项目里不需要保留 deploy/ 目录。
TPL_DIR="${TPL_DIR:-}"
if [ -z "$TPL_DIR" ]; then
  if [ -f "$SCRIPT_DIR/app.service.tpl" ]; then TPL_DIR="$SCRIPT_DIR"
  else TPL_DIR="$SRC/deploy"; fi
fi

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_0=$'\033[0m'
step() { echo -e "\n\033[36m▶ $*\033[0m"; }
ok()   { echo -e "  ${c_ok}✓${c_0} $*"; }
warn() { echo -e "  ${c_warn}!${c_0} $*"; }
die()  { echo -e "  ${c_err}✗ $*${c_0}"; exit 1; }

# 取公网 IPv4：多来源依次试，只接受真正的公网地址。
# 绝不退回 `hostname -I` —— 云服务器上它给的是 172.17.x / 10.x 这类内网地址，
# 写进 PUBLIC_URL 就等于让应用把内网地址发给外部用户，而且重跑脚本也纠不回来。
# 拿不到就返回非 0，让调用方留空（应用应按访问者 Host 自行推导）。
detect_public_ip() {
  local u ip
  for u in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "http://100.100.100.200/latest/meta-data/eipv4" \
    "http://metadata.tencentyun.com/latest/meta-data/public-ipv4" \
    "http://169.254.169.254/latest/meta-data/public-ipv4"
  do
    ip="$(curl -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$ip" in ''|*[!0-9.]*) continue ;; esac
    case "$ip" in
      127.*|10.*|192.168.*|169.254.*) continue ;;
      172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
    esac
    printf '%s' "$ip"
    return 0
  done
  return 1
}

# 从目录名派生一个稳定的 ASCII 标识。
# 纯中文目录名会被 sed 清空（[^a-z0-9]+ 会吃掉整串汉字）——这时用 cksum 生成
# 确定性后缀，保证：① 不会空 ② 同一目录每次派生结果一致。
# setup.sh / pull-deploy.sh / selfcheck.sh 三处的这个函数必须逐字一致，
# 否则"部署用的服务名"和"更新时找的服务名"会对不上。scripts/render_test.sh 会校验。
derive_name() {
  local base slug
  base="$(basename "${1:-.}")"
  slug="$(printf '%s' "$base" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  if [ -z "$slug" ]; then
    slug="app-$(printf '%s' "$base" | cksum | cut -d' ' -f1 | cut -c1-6)"
  fi
  printf '%s' "$slug"
}

# ---------------------------------------------------------------- 推断默认值
# APP_NAME 只允许小写字母、数字、连字符：它会变成 systemd 服务名、
# nginx 配置文件名、htpasswd 文件名、nginx upstream 名的前缀。
if [ -z "$APP_NAME" ]; then
  APP_NAME="$(derive_name "$SRC")"
fi
case "$APP_NAME" in
  *[!a-z0-9-]*) die "APP_NAME 只能用小写字母、数字、连字符，当前：$APP_NAME";;
esac

APP_DIR="${APP_DIR:-$SRC}"

# 读取部署配置文件：必须放在派生默认值之前，配置里的 APP_NAME 才能影响 SVC 等。
# 命令行显式传入的优先级最高（deploy_env_snapshot 已在最前面记下哪些是显式）。
DEPLOY_ENV_PATH="$(deploy_env_path "$APP_DIR")"
deploy_env_load "$DEPLOY_ENV_PATH"

# 配置可能改写了 APP_NAME，再校验一次
case "$APP_NAME" in
  *[!a-z0-9-]*) die "APP_NAME 只能用小写字母、数字、连字符，当前：$APP_NAME";;
esac
SVC="${SVC:-$APP_NAME}"
# 系统账号名一般限 32 字符，这里保守截到 20，避免 useradd 报错或和系统账号撞名
RUN_USER="${RUN_USER:-$(printf '%s' "$APP_NAME" | cut -c1-20)}"
DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
WEB_USER="${WEB_USER:-$APP_NAME}"

# nginx 的 upstream / limit_req zone 名必须全局唯一，否则同一台机器装第二个实例时
# nginx -t 会报 duplicate upstream / duplicate zone。用服务名派生，连字符转下划线。
NGX_ID="${SVC//-/_}"

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo -E bash $SCRIPT_DIR/setup.sh"
[ -d "$SRC" ] || die "代码源目录不存在：$SRC（解耦部署请先 cd 到项目目录，或显式传 APP_DIR / SRC）"

# ---------------------------------------------------------------- 推断运行时
if [ -z "$RUNTIME" ]; then
  if [ -f "$SRC/package.json" ]; then RUNTIME=node
  elif [ -f "$SRC/requirements.txt" ] || [ -f "$SRC/pyproject.toml" ]; then RUNTIME=python
  else RUNTIME=static; fi
fi
case "$RUNTIME" in node|python|static) ;; *) die "RUNTIME 只能是 node / python / static";; esac

if [ -z "$ENTRY" ]; then
  case "$RUNTIME" in
    node)   ENTRY=server.js;;
    python) if [ -f "$SRC/app.py" ]; then ENTRY=app.py
            elif [ -f "$SRC/main.py" ]; then ENTRY=main.py
            else ENTRY=app.py; fi;;
    static) ENTRY="";;
  esac
fi
case "$RUNTIME" in
  node|python) [ -f "$SRC/$ENTRY" ] || die "找不到入口文件 $SRC/$ENTRY（用 ENTRY=xxx 指定）";;
esac

case "$MODE" in basic|ipallow|open) ;; *) die "MODE 只能是 basic / ipallow / open";; esac
case "$WEB_PORT" in ''|*[!0-9]*) die "WEB_PORT 必须是数字";; esac
case "$BACKEND_PORT" in ''|*[!0-9]*) die "BACKEND_PORT 必须是数字";; esac

if [ -n "$DOMAIN" ] && [ "$WEB_PORT" != "80" ]; then
  warn "有域名时对外固定用 80/443，已忽略 WEB_PORT=$WEB_PORT"
  WEB_PORT=80
fi

if [ "$NO_NGINX" = "1" ]; then
  BIND_HOST="0.0.0.0"
  NODE_PORT="$WEB_PORT"
else
  BIND_HOST="127.0.0.1"
  NODE_PORT="$BACKEND_PORT"
  [ "$NODE_PORT" = "$WEB_PORT" ] && die "BACKEND_PORT 不能和 WEB_PORT 相同"
fi

# DATA_DIR 相对 APP_DIR 的路径（用于 tar 排除 / git 跟踪检查）
DATA_REL=""
case "$DATA_DIR" in
  "$APP_DIR"/*) DATA_REL="${DATA_DIR#"$APP_DIR"/}";;
esac

echo -e "${c_dim}应用标识：$APP_NAME（服务 $SVC，账号 $RUN_USER，端口标识 $NGX_ID）${c_0}"
echo -e "${c_dim}源目录：  $SRC${c_0}"
echo -e "${c_dim}部署到：  $APP_DIR${c_0}"
echo -e "${c_dim}数据目录：$DATA_DIR${c_0}"
echo -e "${c_dim}对外端口：$WEB_PORT   Node 端口：$NODE_PORT ($BIND_HOST)${c_0}"
echo -e "${c_dim}运行时：  $RUNTIME${c_0}"
echo -e "${c_dim}访问方式：$MODE$([ "$NO_NGINX" = "1" ] && echo '（无 Nginx，直连）')${c_0}"

# ---------------------------------------------------------------- 系统检测
step "检测系统"
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
else
  die "不认识的发行版（没有 apt / dnf / yum）"
fi
ok "包管理器：$PKG"

# ---------------------------------------------------------------- 装依赖
step "安装系统依赖"
if [ "$PKG" = "apt" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  if [ "$NO_NGINX" = "1" ]; then
    apt-get install -y -qq curl ca-certificates tar >/dev/null
  else
    apt-get install -y -qq curl ca-certificates nginx apache2-utils tar >/dev/null
  fi
else
  if [ "$NO_NGINX" = "1" ]; then
    $PKG install -y -q curl ca-certificates tar >/dev/null 2>&1 || true
  else
    $PKG install -y -q curl ca-certificates nginx httpd-tools tar >/dev/null 2>&1 || true
    systemctl enable nginx >/dev/null 2>&1 || true
  fi
fi
ok "基础依赖就绪"

# ---------------------------------------------------------------- 版本比较
# ver_ge A B → A >= B（按点分段比较，缺位补 0）
ver_ge() {
  local a="$1" b="$2" IFS='.' i p q n
  local -a x y
  read -r -a x <<< "$a"
  read -r -a y <<< "$b"
  n=${#x[@]}; [ ${#y[@]} -gt "$n" ] && n=${#y[@]}
  for ((i=0; i<n; i++)); do
    p="${x[i]:-0}"; q="${y[i]:-0}"
    p="${p//[!0-9]/0}"; q="${q//[!0-9]/0}"
    if [ "$p" -gt "$q" ]; then return 0; fi
    if [ "$p" -lt "$q" ]; then return 1; fi
  done
  return 0
}

NODE_BIN=""; PY_BIN=""

# ---------------------------------------------------------------- Node
if [ "$RUNTIME" = "node" ]; then
  step "检查 Node.js（需要 ≥ $NODE_MIN）"
  need_node=1
  if command -v node >/dev/null 2>&1; then
    NV="$(node -p 'process.versions.node' 2>/dev/null || echo 0)"
    if ver_ge "$NV" "$NODE_MIN"; then
      need_node=0
      ok "已装 Node $NV（满足 $NODE_MIN+）"
    else
      warn "现有 Node $NV 太旧（需要 $NODE_MIN+），将装 22.x"
    fi
  fi

  if [ "$need_node" -eq 1 ]; then
    if [ "$PKG" = "apt" ]; then
      curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh \
        || die "下载 NodeSource 源失败（国内服务器可换 npmmirror，见 references/pitfalls.md）"
      bash /tmp/nodesource_setup.sh >/dev/null 2>&1 || die "NodeSource 源配置失败"
      apt-get install -y -qq nodejs >/dev/null
    else
      curl -fsSL https://rpm.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh \
        || die "下载 NodeSource 源失败"
      bash /tmp/nodesource_setup.sh >/dev/null 2>&1 || die "NodeSource 源配置失败"
      $PKG install -y -q nodejs >/dev/null
    fi
    NV="$(node -p 'process.versions.node')"
    ok "已安装 Node $NV"
  fi

  NODE_BIN="$(command -v node)"
  [ -n "$NODE_BIN" ] || die "找不到 node 可执行文件"
  ok "node 路径：$NODE_BIN"

  # 只在显式给了 NODE_CHECK 时才验证，避免把"某个具体模块"绑死在通用脚本里。
  # 例：NODE_CHECK=node:sqlite —— 该模块 22.5 引入，22.13 才免实验标志。
  if [ -n "$NODE_CHECK" ]; then
    if "$NODE_BIN" -e "require('$NODE_CHECK')" >/dev/null 2>&1; then
      ok "$NODE_CHECK 可用"
    else
      die "当前 Node $NV 加载不了 $NODE_CHECK。检查 NODE_MIN（$NODE_MIN）是否够，或 glibc 是否太旧（CentOS 7 不行）"
    fi
  fi
fi

# ---------------------------------------------------------------- Python
if [ "$RUNTIME" = "python" ]; then
  step "检查 Python3"
  command -v python3 >/dev/null 2>&1 || {
    if [ "$PKG" = "apt" ]; then
      apt-get install -y -qq python3 python3-venv python3-pip >/dev/null
    else
      $PKG install -y -q python3 python3-pip >/dev/null 2>&1 || true
    fi
  }
  PY_BIN="$(command -v python3)"
  [ -n "$PY_BIN" ] || die "找不到 python3"
  ok "python3 路径：$PY_BIN（$("$PY_BIN" -V 2>&1)）"
fi

# ---------------------------------------------------------------- 建用户
step "创建运行账号"
if id "$RUN_USER" >/dev/null 2>&1; then
  ok "用户 $RUN_USER 已存在"
else
  NOSHELL="$(command -v nologin || echo /usr/sbin/nologin)"
  useradd --system --home "$APP_DIR" --shell "$NOSHELL" "$RUN_USER" 2>/dev/null \
    || useradd --system --home-dir "$APP_DIR" --shell "$NOSHELL" "$RUN_USER"
  ok "已创建系统用户 $RUN_USER（不给登录 shell）"
fi

# ---------------------------------------------------------------- 停旧服务
if systemctl cat "$SVC" >/dev/null 2>&1; then
  step "停止旧实例"
  systemctl stop "$SVC" 2>/dev/null || true
  ok "旧服务已停止（稍后会重启）"
fi

# ---------------------------------------------------------------- 拷代码
step "部署代码到 $APP_DIR"
mkdir -p "$APP_DIR"

KEEP_DATA=0
if [ -n "$DATA_REL" ] && [ -d "$APP_DIR/$DATA_REL" ] && [ -n "$(ls -A "$APP_DIR/$DATA_REL" 2>/dev/null || true)" ]; then
  KEEP_DATA=1
fi

SAME_DIR=0
if [ "$(cd "$SRC" && pwd -P)" = "$(cd "$APP_DIR" && pwd -P)" ]; then SAME_DIR=1; fi

# 防呆：源目录里带着数据库，却要装到另一个空目录 —— 那等于把现有数据"搬丢"
if [ "$SAME_DIR" != "1" ] && [ -n "$DATA_REL" ] && [ "$I_KNOW" != "1" ] \
   && [ -d "$SRC/$DATA_REL" ] && [ -n "$(ls -A "$SRC/$DATA_REL" 2>/dev/null || true)" ] \
   && [ ! -d "$APP_DIR/$DATA_REL" ]; then
  warn "源目录里已有数据：$SRC/$DATA_REL"
  warn "但安装目录 $APP_DIR 是空的，继续会部署成一个全新的空库"
  die "如果这是升级，请改用 APP_DIR=$SRC；确认要全新部署请加 I_KNOW=1"
fi

if [ "$SAME_DIR" = "1" ]; then
  ok "安装目录即源目录，跳过拷贝"
else
  EXCLUDES=(--exclude='./.git' --exclude='./node_modules' --exclude='./.venv'
            --exclude='./.deploy' --exclude='./__pycache__' --exclude='./*.pyc')
  [ -n "$DATA_REL" ] && EXCLUDES+=(--exclude="./$DATA_REL")
  # tar 读到"拷贝过程中被改动的文件"会以退出码 1 结束，pipefail 下会直接中断部署。
  # 这类告警无害，捕获后继续；真正的失败留给下面的"入口文件是否存在"去暴露。
  if ! tar -C "$SRC" -cf - "${EXCLUDES[@]}" . 2>/dev/null | tar -C "$APP_DIR" -xf -; then
    warn "拷贝过程有告警（多为文件在拷贝中被改动），已继续"
  fi
  warn "已拷贝代码，但没有带上 .git —— 这种模式下 pull-deploy.sh 不可用"
  warn "想以后用 git 更新，请删掉 $APP_DIR 重新 git clone 后原地部署"
fi

mkdir -p "$DATA_DIR"
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR"
chmod 755 "$APP_DIR" "$DATA_DIR" 2>/dev/null || true
ok "代码已就位（$(du -sh "$APP_DIR" 2>/dev/null | cut -f1)）"

if [ "$KEEP_DATA" -eq 1 ]; then
  ok "检测到已有数据，$DATA_REL/ 未被覆盖"
else
  ok "首次部署，数据目录为空，服务启动时会自行初始化"
fi

# ---------------------------------------------------------------- 数据保护自查
# git checkout -f 会覆盖"已被 git 跟踪"的文件。数据目录理应在 .gitignore 里，
# 万一被提交进去了，下次部署就会把运行中的库冲成仓库里的旧版本。
if [ -d "$APP_DIR/.git" ] && [ -n "$DATA_REL" ]; then
  if git -C "$APP_DIR" ls-files --error-unmatch "$DATA_REL" >/dev/null 2>&1; then
    warn "⚠ 数据目录 $DATA_REL/ 被 git 跟踪了！下次 pull-deploy 会覆盖现有数据"
    warn "  立刻处理：echo '$DATA_REL/' >> $APP_DIR/.gitignore && git -C $APP_DIR rm -r --cached '$DATA_REL'"
  fi
fi

# ---------------------------------------------------------------- 推导访问地址
step "确定对外地址"
if [ -z "$PUBLIC_URL" ]; then
  if [ -n "$DOMAIN" ]; then
    PUBLIC_URL="http://$DOMAIN"
  else
    PUB_IP="$(detect_public_ip || true)"
    if [ -n "$PUB_IP" ]; then
      if [ "$WEB_PORT" = "80" ]; then
        PUBLIC_URL="http://$PUB_IP"
      else
        PUBLIC_URL="http://$PUB_IP:$WEB_PORT"
      fi
    fi
  fi
fi
if [ -n "$PUBLIC_URL" ]; then
  ok "PUBLIC_URL = $PUBLIC_URL"
  [ -z "$DOMAIN" ] && warn "二维码 / 分享链接用这个地址；外部访问时它必须是公网 IP"
else
  ok "PUBLIC_URL 留空 —— 应用按访问者实际的 Host 推导地址"
  warn "没查到公网 IP（api.ipify.org / 云元数据都试过）。留空比写死内网 IP 安全得多"
  warn "若应用不支持按 Host 推导，请显式传：PUBLIC_URL=http://<公网地址>:<端口>"
fi

# ---------------------------------------------------------------- 启动命令
if [ -z "$START_CMD" ]; then
  case "$RUNTIME" in
    node)   START_CMD="$NODE_BIN $APP_DIR/$ENTRY";;
    python) START_CMD="$APP_DIR/.venv/bin/python $APP_DIR/$ENTRY";;
    static) START_CMD="$(command -v python3 || echo /usr/bin/python3) -m http.server $NODE_PORT --bind $BIND_HOST --directory $APP_DIR";;
  esac
fi
ok "启动命令：$START_CMD"

# ---------------------------------------------------------------- Python 虚拟环境
if [ "$RUNTIME" = "python" ]; then
  if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
    step "创建 Python 虚拟环境"
    "$PY_BIN" -m venv "$APP_DIR/.venv" || die "创建 venv 失败（apt install python3-venv）"
    ok "已创建 $APP_DIR/.venv"
  fi
  if [ -f "$APP_DIR/requirements.txt" ] && [ "$INSTALL_DEPS" = "1" ]; then
    step "安装 Python 依赖"
    "$APP_DIR/.venv/bin/pip" install --no-cache-dir -q --upgrade pip >/dev/null 2>&1 || true
    "$APP_DIR/.venv/bin/pip" install --no-cache-dir -q -r "$APP_DIR/requirements.txt" \
      || die "pip 安装失败，手动排查：$APP_DIR/.venv/bin/pip install -r $APP_DIR/requirements.txt"
    ok "依赖已安装"
  fi
  chown -R "$RUN_USER:$RUN_USER" "$APP_DIR/.venv"
fi

# ---------------------------------------------------------------- Node 依赖
if [ "$RUNTIME" = "node" ] && [ -f "$APP_DIR/package.json" ] && [ "$INSTALL_DEPS" = "1" ]; then
  step "安装 Node 依赖"
  NPM="$(command -v npm || true)"
  [ -n "$NPM" ] || die "找不到 npm，检查 Node 安装"
  REG_ARG=()
  [ -n "$NPM_REGISTRY" ] && REG_ARG=(--registry "$NPM_REGISTRY")
  run_npm() { ( cd "$APP_DIR" && "$NPM" "$@" --no-audit --no-fund >/dev/null 2>&1 ); }
  # --no-package-lock：仓库不跟踪锁文件时不在服务器生成它，避免污染工作区
  # （selfcheck 会把未跟踪文件当"未提交改动"告警；仓库跟踪了锁文件则走上面的 npm ci 分支）
  if [ -f "$APP_DIR/package-lock.json" ] && run_npm ci --omit=dev "${REG_ARG[@]+"${REG_ARG[@]}"}"; then
    ok "依赖已安装（npm ci）"
  elif run_npm install --omit=dev --no-package-lock "${REG_ARG[@]+"${REG_ARG[@]}"}"; then
    ok "依赖已安装（npm install --omit=dev）"
  elif run_npm install --no-package-lock "${REG_ARG[@]+"${REG_ARG[@]}"}"; then
    ok "依赖已安装（npm install）"
  else
    die "依赖安装失败，手动排查：cd $APP_DIR && npm install ${NPM_REGISTRY:+--registry $NPM_REGISTRY}"
  fi
fi

# ---------------------------------------------------------------- 构建
if [ -n "$BUILD_CMD" ]; then
  step "执行构建"
  ( cd "$APP_DIR" && bash -c "$BUILD_CMD" ) || die "构建失败：$BUILD_CMD"
  ok "构建完成"
fi
chown -R "$RUN_USER:$RUN_USER" "$APP_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- systemd
step "写入 systemd 服务"

# 环境变量块：每行一个 Environment=
ENV_LINES="Environment=PUBLIC_URL=$PUBLIC_URL
Environment=PORT=$NODE_PORT
Environment=BIND_HOST=$BIND_HOST
Environment=NODE_ENV=production"
[ "$RUNTIME" = "node" ] && ENV_LINES="$ENV_LINES
Environment=PATH=$(dirname "$NODE_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -n "$ENV_FILE" ] && ENV_LINES="$ENV_LINES
EnvironmentFile=-$ENV_FILE"
if [ -n "$EXTRA_ENV" ]; then
  for kv in $EXTRA_ENV; do
    ENV_LINES="$ENV_LINES
Environment=$kv"
  done
fi

# 加固块：ProtectHome=true 会把 /home 与 /root 全藏起来。
# APP_DIR 或 DATA_DIR 落在这些目录下时必须降级，否则服务起来就报 ENOENT。
HARDEN_LINES="NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full"
case "$APP_DIR$DATA_DIR" in
  *"/home/"*|*"/root/"*)
    HARDEN_LINES="$HARDEN_LINES
# 代码或数据在 /home、/root 下，不能开 ProtectHome=true
ProtectHome=false
ReadWritePaths=$DATA_DIR"
    warn "代码/数据在 /home 或 /root 下：已关闭 ProtectHome，并只放开 $DATA_DIR 可写"
    ;;
  *)
    HARDEN_LINES="$HARDEN_LINES
ProtectHome=true
ReadWritePaths=$DATA_DIR"
    ;;
esac

# Description 用可读的目录名（可以是中文），服务名才必须是 ASCII
APP_TITLE="$(basename "$SRC")"
DOMAIN_OR_UNDERSCORE="_"
[ -n "$DOMAIN" ] && DOMAIN_OR_UNDERSCORE="$DOMAIN"
PORT="$NODE_PORT"
AUTH=""

# 通用占位符渲染器：用 awk + ENVIRON 逐行替换 __KEY__。
# 不用 sed 是因为值里可能有 | & / \ 和换行（ENV_LINES 就是多行的）。
TPL_KEYS="APP_TITLE SVC RUN_USER ROOT DATA_DIR START_CMD ENV_LINES HARDEN_LINES NGX_ID WEB_PORT PORT DOMAIN DOMAIN_OR_UNDERSCORE AUTH SSE_PATH LIMIT_RE MAX_BODY"
export TPL_KEYS

render_tpl() {
  local tpl="$1" out="$2"
  awk '
# >>> render-awk
    function repl(s, k, v,   out, p) {
      out = ""
      while ((p = index(s, k)) > 0) {
        out = out substr(s, 1, p - 1) v
        s = substr(s, p + length(k))
      }
      return out s
    }
    BEGIN {
      m = split(ENVIRON["TPL_KEYS"], names, " ")
      for (i = 1; i <= m; i++) marks[i] = "__" names[i] "__"
    }
    {
      line = $0
      for (i = 1; i <= m; i++) {
        if ((names[i] in ENVIRON) && index(line, marks[i]) > 0) {
          line = repl(line, marks[i], ENVIRON[names[i]])
        }
      }
      print line
    }
# <<< render-awk
  ' "$tpl" > "$out"
}

# 占位符里用到的变量都得进 ENVIRON
export APP_TITLE SVC RUN_USER DATA_DIR START_CMD ENV_LINES HARDEN_LINES NGX_ID WEB_PORT PORT DOMAIN DOMAIN_OR_UNDERSCORE SSE_PATH LIMIT_RE MAX_BODY
export ROOT="$APP_DIR"

[ -f "$TPL_DIR/app.service.tpl" ] || die "找不到 $TPL_DIR/app.service.tpl（模板需与脚本同目录，或放项目 deploy/ 下）"
render_tpl "$TPL_DIR/app.service.tpl" "/etc/systemd/system/$SVC.service"

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
ok "服务已注册：$SVC"

# ---------------------------------------------------------------- 访问控制
AUTH_LINE=""
if [ "$NO_NGINX" = "1" ]; then
  step "跳过访问控制"
  warn "NO_NGINX=1：没有口令、没有限速，任何人拿到地址就能进"
  warn "仅用于临时测试。正式使用请去掉 NO_NGINX 并走 Nginx"
else
  step "生成访问控制（$MODE）"
  case "$MODE" in
    basic)
      HTPASSWD="/etc/nginx/${SVC}.htpasswd"
      if [ -z "$WEB_PASS" ] && [ -f "$HTPASSWD" ]; then
        # 重跑 setup.sh 时不要重置已有口令，否则全校的入口密码突然变了
        warn "已存在 $HTPASSWD，沿用旧口令（想换密码：删掉该文件后重跑，或用 WEB_PASS=xxx）"
      else
        if [ -z "$WEB_PASS" ]; then
          WEB_PASS="$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12 2>/dev/null || true)"
          [ -n "$WEB_PASS" ] || WEB_PASS="pw$(date +%s)${RANDOM}"
        fi
        htpasswd -bc "$HTPASSWD" "$WEB_USER" "$WEB_PASS" >/dev/null 2>&1 \
          || die "生成口令文件失败，确认 apache2-utils / httpd-tools 已安装"
        chmod 644 "$HTPASSWD"
        ok "整站口令：$WEB_USER / $WEB_PASS"
      fi
      AUTH_LINE="    auth_basic \"$APP_TITLE\"; auth_basic_user_file $HTPASSWD;"
      ;;
    ipallow)
      [ -n "$ALLOW_CIDR" ] || die "ipallow 模式请设置 ALLOW_CIDR=\"学校出口IP/24\""
      for c in $ALLOW_CIDR; do AUTH_LINE="$AUTH_LINE    allow $c;"$'\n'; done
      AUTH_LINE="${AUTH_LINE}    allow 127.0.0.1;"$'\n'"    deny all;"
      ok "只放行：$ALLOW_CIDR（+ 本机）"
      ;;
    open)
      AUTH_LINE="    # open 模式：没有任何访问控制"
      warn "open 模式 = 任何人都能看到全部数据"
      ;;
  esac
fi
export AUTH="$AUTH_LINE"

# ---------------------------------------------------------------- Nginx
if [ "$NO_NGINX" != "1" ]; then
  step "配置 Nginx 反向代理"
  [ -f "$TPL_DIR/nginx-http.conf.tpl" ] || die "找不到 $TPL_DIR/nginx-http.conf.tpl"

  render_tpl "$TPL_DIR/nginx-http.conf.tpl" "/etc/nginx/conf.d/$SVC.conf"

  if [ "$WEB_PORT" = "80" ] && [ -f /etc/nginx/sites-enabled/default ]; then
    BAK="/etc/nginx/default.disabled.$(date +%Y%m%d%H%M%S)"
    mv /etc/nginx/sites-enabled/default "$BAK"
    ok "已停用发行版默认站点（备份：$BAK）"
  fi

  if ! nginx -t >/dev/null 2>&1; then
    nginx -t || true
    die "Nginx 配置有误，见上面的报错（文件：/etc/nginx/conf.d/$SVC.conf）"
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  ok "Nginx 已加载，监听 $WEB_PORT"
fi

# ---------------------------------------------------------------- 防火墙
step "放行端口"
PORTS="$WEB_PORT"
[ -n "$DOMAIN" ] && PORTS="80 443"

opened=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  for p in $PORTS; do ufw allow "$p/tcp" >/dev/null 2>&1 || true; done
  ok "ufw 已放行：$PORTS"
  opened=1
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  for p in $PORTS; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1 || true; done
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld 已放行：$PORTS"
  opened=1
fi
[ "$opened" -eq 0 ] && warn "没检测到启用的本机防火墙"
warn "云平台安全组 / 云防火墙必须单独放行 $PORTS，否则外网连不上"

# ---------------------------------------------------------------- 启动
step "启动服务"
systemctl restart "$SVC"
sleep 2
if ! systemctl is-active --quiet "$SVC"; then
  journalctl -u "$SVC" -n 30 --no-pager
  die "服务启动失败，日志见上"
fi
ok "服务已运行（$SVC，端口 $NODE_PORT）"

if curl -fsS --max-time 5 "http://127.0.0.1:$NODE_PORT$HEALTH" >/dev/null 2>&1; then
  ok "内部探针 $HEALTH 正常"
else
  warn "服务在跑，但探针 $HEALTH 不通"
  warn "如果这个项目没有该路径，重新部署时传 HEALTH=/ 或你实际的健康检查路径"
  journalctl -u "$SVC" -n 20 --no-pager | sed 's/^/    /'
fi

if [ "$NO_NGINX" != "1" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$WEB_PORT/" 2>/dev/null || echo 000)"
  case "$CODE" in
    200) ok "Nginx 转发正常（HTTP 200）" ;;
    401) ok "Nginx 转发正常（HTTP 401 = 口令生效）" ;;
    403) ok "Nginx 转发正常（HTTP 403 = IP 白名单生效）" ;;
    000) warn "Nginx 端口 $WEB_PORT 无响应，检查 /etc/nginx/conf.d/$SVC.conf" ;;
    *)   warn "Nginx 返回 HTTP $CODE，请检查：sudo tail -20 /var/log/nginx/error.log" ;;
  esac
fi

# ---------------------------------------------------------------- HTTPS
if [ -n "$DOMAIN" ] && [ "$NO_CERTBOT" != "1" ]; then
  step "申请 HTTPS 证书（Let's Encrypt）"
  if [ "$PKG" = "apt" ]; then
    apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  else
    $PKG install -y -q certbot python3-certbot-nginx >/dev/null 2>&1 \
      || die "装 certbot 失败，请手动执行：certbot --nginx -d $DOMAIN"
  fi

  CB_ARGS=(--nginx -d "$DOMAIN" --agree-tos --redirect --non-interactive)
  if [ -n "$EMAIL" ]; then
    CB_ARGS+=(-m "$EMAIL")
  else
    CB_ARGS+=(--register-unsafely-without-email)
    warn "没填 EMAIL，证书到期提醒收不到（续期任务仍会自动跑）"
  fi

  if certbot "${CB_ARGS[@]}"; then
    ok "证书已签发"
    render_tpl "$TPL_DIR/nginx-https.conf.tpl" "/etc/nginx/conf.d/$SVC.conf"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    ok "已切到 HTTPS 加固配置"

    sed -i "s|^Environment=PUBLIC_URL=.*|Environment=PUBLIC_URL=https://$DOMAIN|" \
      "/etc/systemd/system/$SVC.service"
    systemctl daemon-reload && systemctl restart "$SVC"
    PUBLIC_URL="https://$DOMAIN"
    ok "已通知服务端使用 $PUBLIC_URL"
  else
    warn "证书申请失败（常见原因：域名没解析到这台机器 / 80 端口没放行）"
    warn "服务仍可通过 http://$DOMAIN 访问，修好后手动执行：certbot --nginx -d $DOMAIN"
  fi
elif [ -n "$DOMAIN" ]; then
  warn "NO_CERTBOT=1：跳过了证书申请，HTTP 配置仍生效"
else
  warn "没有域名，只能走 HTTP —— 口令与业务数据是明文传输，建议尽快配域名"
fi

# ---------------------------------------------------------------- 参数快照
# 本次真正生效的参数写回同一个配置文件（就是上面 DEPLOY_ENV_PATH 读的那份）。
# 之后的 pull-deploy.sh / selfcheck.sh 自动读它，不用重传 SVC / DATA_DIR / HEALTH。
# 手写配置（首行没有脚本生成标记）默认只读不改写；脚本生成的快照幂等重写。
# DEPLOY_ENV_FORCE_SAVE=1 才会覆盖手写配置。
DEPLOY_ENV_SAVE_RC=0
deploy_env_save "$DEPLOY_ENV_PATH" || DEPLOY_ENV_SAVE_RC=$?
case "$DEPLOY_ENV_SAVE_RC" in
  0) ok "部署参数已记入 $DEPLOY_ENV_PATH（后续更新 / 体检自动沿用）" ;;
  2) ok "检测到手写配置 $DEPLOY_ENV_PATH，按只读处理，未改写" ;;
  *) warn "写 $DEPLOY_ENV_PATH 失败 —— 后续更新仍需手动传 SVC / DATA_DIR / HEALTH" ;;
esac
case "$DEPLOY_ENV_PATH" in
  "$APP_DIR"/deploy/deploy.conf)
    ok "配置文件 deploy/deploy.conf 随代码走（有意纳入版本管理）"
    ;;
  "$APP_DIR"/*)
    DEPLOY_ENV_REL="${DEPLOY_ENV_PATH#"$APP_DIR"/}"
    if git -C "$APP_DIR" ls-files --error-unmatch "$DEPLOY_ENV_REL" >/dev/null 2>&1; then
      warn "⚠ 配置文件 $DEPLOY_ENV_REL 被 git 跟踪了，下次 checkout 会覆盖它"
      warn "  处理：echo '.deploy/' >> $APP_DIR/.gitignore && git -C $APP_DIR rm -r --cached .deploy"
    fi
    ;;
esac

# ---------------------------------------------------------------- 完成
LINE="======================================================================"
echo ""
echo -e "\033[32m$LINE\033[0m"
echo -e "\033[32m   部署完成\033[0m"
echo -e "\033[32m$LINE\033[0m"
if [ -n "$PUBLIC_URL" ]; then
  echo "  访问地址： $PUBLIC_URL/"
else
  echo "  访问地址： http://<这台机器的公网IP>:$WEB_PORT/"
fi
for u in $BIZ_URLS; do
  echo "  业务入口： $PUBLIC_URL$u"
done
echo ""
if [ "$MODE" = "basic" ] && [ "$NO_NGINX" != "1" ]; then
  echo "  网页口令： $WEB_USER / ${WEB_PASS:-（沿用上次，见 /etc/nginx/${SVC}.htpasswd）}"
fi
[ "$MODE" = "ipallow" ] && echo "  访问白名单：$ALLOW_CIDR（其余来源 403）"
echo ""
echo "  目录布局："
echo "    代码     $APP_DIR"
echo "    数据     $DATA_DIR"
echo "    服务     /etc/systemd/system/$SVC.service"
[ "$NO_NGINX" != "1" ] && echo "    站点     /etc/nginx/conf.d/$SVC.conf"
echo ""
echo "  常用命令："
echo "    systemctl status  $SVC     查看状态"
echo "    systemctl restart $SVC     重启"
echo "    journalctl -u $SVC -f      看实时日志"
echo "    bash $SCRIPT_DIR/selfcheck.sh   一键体检"
echo "    bash $SCRIPT_DIR/pull-deploy.sh 拉新版本（改动以后用这个，不用重跑 setup.sh）"
echo "    （脚本留在项目里时，等价于 bash deploy/setup.sh / deploy/selfcheck.sh / deploy/pull-deploy.sh）"
echo ""
[ -z "$DOMAIN" ] && echo "  ⚠ 建议尽快配域名上 HTTPS，否则口令与业务数据明文过公网"
echo -e "\033[32m$LINE\033[0m"
