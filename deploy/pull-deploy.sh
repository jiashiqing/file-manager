#!/usr/bin/env bash
# =====================================================================
#  git-repo-deploy · 从远程仓库更新部署（保留本地数据 · 支持回滚）
#
#  和 deploy/setup.sh 的分工：
#    setup.sh        首次部署。装运行时、建账号、写 systemd、配 Nginx、开端口。
#    pull-deploy.sh  日常更新。git 拉代码 → 装依赖 → 重启 → 探活 → 失败自动回滚。
#    两者不冲突：setup.sh 不碰 .git 的提交历史，本脚本不碰 systemd/Nginx 配置。
#    首次部署会把参数写进 $APP_DIR/.deploy/env，本脚本与 selfcheck.sh 自动读取；
#    命令行显式传入的优先。老部署第一次跑完本脚本会自动补写这份快照。
#
#  ---- 常用 ----
#    sudo bash deploy/pull-deploy.sh                  拉默认分支最新并部署
#    sudo bash deploy/pull-deploy.sh v1.2.0           部署某个 tag
#    sudo bash deploy/pull-deploy.sh a1b2c3d          部署某个 commit
#    sudo bash deploy/pull-deploy.sh --rollback       回退到上一次部署的版本
#    sudo bash deploy/pull-deploy.sh --rollback <sha> 回退到指定版本
#    sudo bash deploy/pull-deploy.sh --list           看部署历史
#    sudo bash deploy/pull-deploy.sh --status         看当前版本与远程差多少
#    sudo bash deploy/pull-deploy.sh --init <仓库地址> 首次：把已有目录接上远程仓库
#    cd /data/web/app && sudo bash /opt/git-repo-deploy/pull-deploy.sh  解耦用法
#
#  ---- 环境变量 ----
#    APP_DIR       代码目录；脚本在项目 deploy/ 内时取上一级，解耦时取当前目录
#    .deploy/env   首次部署落下的参数快照（自动生成 / 自动读取）
#    deploy/deploy.conf  项目内手写配置（优先于 .deploy/env，默认只读）
#    GIT_REPO_DEPLOY_INDEX  中央索引路径（默认 /etc/git-repo-deploy/apps.conf）
#    DEPLOY_ENV_FILE  自定义配置文件路径；不传时按自动发现顺序查找
#    GIT_REPO_DEPLOY_INDEX  中央索引路径（默认 /etc/git-repo-deploy/apps.conf）
#    SVC           systemd 服务名，默认从目录名推断
#    DATA_DIR      数据目录，默认 $APP_DIR/data
#    BRANCH        默认分支，默认从 origin/HEAD 推断
#    HEALTH        健康检查路径，默认 /api/ping
#    BACKUP_DIR    部署前数据备份位置，默认 /data/backup
#    BACKUP_KEEP   备份保留份数，默认 20
#    HIST_KEEP     部署历史保留条数，默认 50
#    NPM_REGISTRY  npm 源，国内用 https://registry.npmmirror.com
#    BUILD_CMD     装完依赖后执行的构建命令
#    SKIP_DEPS=1   跳过依赖安装
#    FORCE=1       允许丢弃工作区里未提交的本地修改
#    SKIP_BACKUP=1 跳过部署前的数据库备份（不推荐）
#
#  ---- 四条硬规则 ----
#   1. 数据目录理应在 .gitignore 里，git 永远不碰它；本脚本也从不执行 git clean。
#   2. 部署前必定先停服务、再备份数据库，避免拿到 WAL 半截状态。
#   3. 新版本启动失败会自动切回上一个版本并重启，不需要人守着。
#   4. 回滚用的是 git checkout <sha>（detached HEAD），不会移动任何分支指针。
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

# ---------------------------------------------------------------- 自复制
# 部署过程中会把仓库切到别的 commit，脚本文件本身可能被替换甚至删除。
# bash 是边读边执行的，文件被换掉会导致后半段读错。先把自己拷到 /tmp 再 exec。
if [ -z "${PD_REEXEC:-}" ]; then
  PD_TMP="$(mktemp -t pull-deploy-XXXXXX.sh)"
  cat "${BASH_SOURCE[0]}" > "$PD_TMP"
  export PD_REEXEC=1
  # 记住「用户实际调用的那份脚本」：自复制后 BASH_SOURCE 会变成 /tmp 副本，
  # 收尾提示必须指向 /opt/git-repo-deploy/ 这类真实位置，而不是项目里的 deploy/。
  export PD_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  export PD_SETUP="$(dirname "$PD_SELF")/setup.sh"
  PD_SCRIPT_PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -d "$PD_SCRIPT_PARENT/.git" ]; then
    export APP_DIR="${APP_DIR:-$PD_SCRIPT_PARENT}"
  else
    export APP_DIR="${APP_DIR:-$PWD}"
  fi
  exec bash "$PD_TMP" "$@"
fi
trap 'rm -f "$0" 2>/dev/null || true' EXIT
PD_SELF="${PD_SELF:-${BASH_SOURCE[0]}}"
PD_SETUP="${PD_SETUP:-$(dirname "$PD_SELF")/setup.sh}"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_0=$'\033[0m'
step() { echo -e "\n\033[36m▶ $*\033[0m"; }
ok()   { echo -e "  ${c_ok}✓${c_0} $*"; }
warn() { echo -e "  ${c_warn}!${c_0} $*"; }
die()  { echo -e "  ${c_err}✗ $*${c_0}"; exit 1; }

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

APP_DIR="${APP_DIR:-$PWD}"

# 读取部署配置文件（默认 $APP_DIR/.deploy/env，可用 DEPLOY_ENV_FILE 指到仓库外）。
# 优先级：命令行显式 > 配置文件 > 下面的默认值。
# 老部署没有这个文件也没关系：本次部署成功后会自动补写一份。
DEPLOY_ENV_PATH="$(deploy_env_path "$APP_DIR")"
deploy_env_load "$DEPLOY_ENV_PATH"

# git ≥ 2.35 遇到「仓库属主 ≠ 当前用户」会拒绝操作，报
#   fatal: detected dubious ownership in repository at '...'
# 而 setup.sh 会把代码目录 chown 给运行账号，本脚本却要用 root 跑，两边对不上。
# 做法：先探一下这个目录能不能正常读，读不了才为它单独放行（不放开全局）。
# 放行写 --system（/etc/gitconfig，全机所有用户生效）：sudo -E 时 HOME 保留成登录用户，
# --global 只写到那一个用户的 ~/.gitconfig，selfcheck / 手工 git 换个身份跑就又不认了。
if [ -d "$APP_DIR/.git" ] && ! git -C "$APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    git config --system --add safe.directory "$APP_DIR" 2>/dev/null \
      || git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
  else
    git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
  fi
fi

# 服务名默认从目录名推断，推断规则和 setup.sh 保持一致
def_name="$(derive_name "$APP_DIR")"

SVC="${SVC:-$def_name}"
DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
BRANCH="${BRANCH:-}"
HEALTH="${HEALTH:-/api/ping}"
BACKUP_DIR="${BACKUP_DIR:-/data/backup}"
BACKUP_KEEP="${BACKUP_KEEP:-20}"
HIST_KEEP="${HIST_KEEP:-50}"
NPM_REGISTRY="${NPM_REGISTRY:-}"
BUILD_CMD="${BUILD_CMD:-}"
SKIP_DEPS="${SKIP_DEPS:-0}"
FORCE="${FORCE:-0}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"

ACTION=deploy
TARGET=""
INIT_URL=""

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --init)
      ACTION=init; shift
      [ $# -gt 0 ] || die "--init 后面要跟仓库地址"
      INIT_URL="$1"; shift ;;
    --rollback)
      ACTION=rollback; shift
      if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then TARGET="$1"; shift; fi ;;
    --list)      ACTION=list;     shift ;;
    --status)    ACTION=status;   shift ;;
    --force)     FORCE=1;         shift ;;
    --no-backup) SKIP_BACKUP=1;   shift ;;
    -h|--help)   usage; exit 0 ;;
    -*) die "未知参数：$1（--help 看用法）" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------- 工具
detect_branch() {
  if [ -n "$BRANCH" ]; then echo "$BRANCH"; return; fi
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [ -n "$b" ]; then echo "$b"; return; fi
  if git rev-parse --verify --quiet origin/main   >/dev/null 2>&1; then echo main;   return; fi
  if git rev-parse --verify --quiet origin/master >/dev/null 2>&1; then echo master; return; fi
  echo main
}

# 把任意写法（空 / 分支名 / tag / sha / HEAD~1）解析成 commit sha
resolve_sha() {
  local t="${1:-}"
  [ -n "$t" ] || t="$(detect_branch)"
  # 优先远程分支，避免本地分支落后于远程
  if git rev-parse --verify --quiet "origin/$t^{commit}" >/dev/null 2>&1; then
    git rev-parse "origin/$t^{commit}"; return 0
  fi
  if git rev-parse --verify --quiet "$t^{commit}" >/dev/null 2>&1; then
    git rev-parse "$t^{commit}"; return 0
  fi
  return 1
}

short() { git rev-parse --short "$1" 2>/dev/null || echo "${1:0:7}"; }

probe() {
  local i
  for i in $(seq 1 15); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$PORT$HEALTH" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

record() {
  local sha="$1" ref="$2" res="$3"
  mkdir -p "$APP_DIR/.deploy" 2>/dev/null || return 0
  printf '%s %s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$sha" "$ref" "$res" \
    >> "$APP_DIR/.deploy/history" 2>/dev/null || true
  if [ -f "$APP_DIR/.deploy/history" ] && [ "$(wc -l < "$APP_DIR/.deploy/history")" -gt "$HIST_KEEP" ]; then
    tail -n "$HIST_KEEP" "$APP_DIR/.deploy/history" > "$APP_DIR/.deploy/.h.tmp"
    mv "$APP_DIR/.deploy/.h.tmp" "$APP_DIR/.deploy/history"
  fi
}

read_runtime() {
  RUN_USER="$(systemctl show -p User --value "$SVC" 2>/dev/null || true)"
  [ -n "$RUN_USER" ] || RUN_USER="$(stat -c %U "$APP_DIR" 2>/dev/null || echo root)"
  PORT="$(systemctl show -p Environment --value "$SVC" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^PORT=//p' | head -1 || true)"
  [ -n "$PORT" ] || PORT=8091
}

# ---------------------------------------------------------------- 备份
backup_data() {
  if [ ! -d "$DATA_DIR" ]; then
    ok "没有数据目录 $DATA_DIR，跳过备份"
    return 0
  fi
  if [ "$SKIP_BACKUP" = "1" ]; then
    warn "SKIP_BACKUP=1：跳过了数据备份"
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  local stamp; stamp="$(date +%F-%H%M%S)"
  local dbs; dbs="$(find "$DATA_DIR" -maxdepth 1 -type f -name '*.sqlite' 2>/dev/null || true)"

  if [ -n "$dbs" ]; then
    # 此刻服务已停，库文件和 -wal/-shm 都是静止的，直接 cp 就是一致快照
    local db out
    while IFS= read -r db; do
      [ -n "$db" ] || continue
      out="$BACKUP_DIR/$(basename "${db%.sqlite}")-$stamp-predeploy.sqlite"
      cp -p "$db" "$out"
      [ -f "$db-wal" ] && { cp -p "$db-wal" "$out-wal" || true; }
      [ -f "$db-shm" ] && { cp -p "$db-shm" "$out-shm" || true; }
      ok "已备份：$out（$(du -h "$out" | cut -f1)）"
    done <<< "$dbs"
    ls -1t "$BACKUP_DIR"/*-predeploy.sqlite 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f || true
  else
    # 非 SQLite 项目：整目录打包（排除依赖与缓存，避免把几百 MB 塞进备份）
    local out="$BACKUP_DIR/data-$stamp-predeploy.tar.gz"
    tar -C "$(dirname "$DATA_DIR")" -czf "$out" \
      --exclude='node_modules' --exclude='.venv' --exclude='__pycache__' \
      "$(basename "$DATA_DIR")" 2>/dev/null || { warn "打包数据目录失败，跳过备份"; return 0; }
    ok "已备份：$out（$(du -h "$out" | cut -f1)）"
    ls -1t "$BACKUP_DIR"/data-*-predeploy.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f || true
  fi
}

# ---------------------------------------------------------------- 依赖
install_deps() {
  [ "$SKIP_DEPS" = "1" ] && { warn "SKIP_DEPS=1：跳过依赖安装"; return 0; }

  if [ -f "$APP_DIR/package.json" ]; then
    local marker="$APP_DIR/node_modules/.package-lock.json"
    local need=0
    [ -d "$APP_DIR/node_modules" ] || need=1
    [ -f "$marker" ] || need=1
    if [ "$need" = "0" ] && [ "$APP_DIR/package.json" -nt "$marker" ]; then need=1; fi
    if [ "$need" = "0" ] && [ -f "$APP_DIR/package-lock.json" ] \
       && [ "$APP_DIR/package-lock.json" -nt "$marker" ]; then need=1; fi

    if [ "$need" = "0" ]; then
      ok "依赖未变化，跳过安装"
      return 0
    fi

    local npm; npm="$(command -v npm || true)"
    [ -n "$npm" ] || die "找不到 npm，检查 Node 是否安装"
    local reg=()
    [ -n "$NPM_REGISTRY" ] && reg=(--registry "$NPM_REGISTRY")
    run_npm() { ( cd "$APP_DIR" && "$npm" "$@" --no-audit --no-fund >/dev/null 2>&1 ); }

    # --no-package-lock：仓库不跟踪锁文件时不在服务器生成它，避免污染工作区
    # （selfcheck 会把未跟踪文件当"未提交改动"告警；仓库跟踪了锁文件则走上面的 npm ci 分支）
    if [ -f "$APP_DIR/package-lock.json" ] && run_npm ci --omit=dev "${reg[@]+"${reg[@]}"}"; then
      ok "依赖已安装（npm ci）"
    elif run_npm install --omit=dev --no-package-lock "${reg[@]+"${reg[@]}"}"; then
      ok "依赖已安装（npm install --omit=dev）"
    elif run_npm install --no-package-lock "${reg[@]+"${reg[@]}"}"; then
      ok "依赖已安装（npm install）"
    else
      die "依赖安装失败，手动排查：cd $APP_DIR && npm install${NPM_REGISTRY:+ --registry $NPM_REGISTRY}"
    fi
  elif [ -f "$APP_DIR/requirements.txt" ]; then
    [ -x "$APP_DIR/.venv/bin/pip" ] || die "没找到 $APP_DIR/.venv，Python 项目请先用 $PD_SETUP 部署一次"
    "$APP_DIR/.venv/bin/pip" install --no-cache-dir -q -r "$APP_DIR/requirements.txt" \
      || die "pip 安装失败"
    ok "Python 依赖已安装"
  else
    ok "没有依赖清单，跳过"
  fi

  if [ -n "$BUILD_CMD" ]; then
    ( cd "$APP_DIR" && bash -c "$BUILD_CMD" ) || die "构建失败：$BUILD_CMD"
    ok "构建完成"
  fi
}

# ---------------------------------------------------------------- 核心部署
# 把工作区切到 $1 指定的版本，起服务，探活；失败自动退回上一个版本。
do_deploy() {
  local ref="$1"
  local new_sha prev_sha
  prev_sha="$(git rev-parse HEAD 2>/dev/null || echo '')"
  new_sha="$(resolve_sha "$ref")" || die "找不到版本：$ref（先 --status 看远程有什么）"

  step "目标版本"
  echo "  目标  $(short "$new_sha")  $(git log -1 --format=%s "$new_sha" | cut -c1-60)"
  [ -n "$prev_sha" ] && echo "  当前  $(short "$prev_sha")  $(git log -1 --format=%s "$prev_sha" | cut -c1-60)"

  if [ "$new_sha" = "$prev_sha" ]; then
    ok "已经是这个版本，只做重启"
  else
    step "切换代码"
    # checkout 具体 sha 会进 detached HEAD：不移动任何分支指针，
    # 所以"部署旧版本"不会把 main 搞乱。
    git checkout -f "$new_sha" 2>&1 | sed 's/^/    /'
    ok "已切到 $(short "$new_sha")"
  fi

  install_deps
  chown -R "$RUN_USER:$RUN_USER" "$APP_DIR" 2>/dev/null || true

  step "启动服务"
  systemctl start "$SVC" 2>/dev/null || systemctl restart "$SVC"
  if probe; then
    ok "服务正常（127.0.0.1:$PORT$HEALTH）"
    record "$new_sha" "$(short "$new_sha")" ok
    return 0
  fi

  # ---- 失败自动回滚 ----
  echo ""
  warn "新版本启动失败，日志如下："
  journalctl -u "$SVC" -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
  if [ -z "$prev_sha" ]; then
    record "$new_sha" "$(short "$new_sha")" fail
    die "没有可回退的上一版本，需要人工处理"
  fi

  warn "自动回退到 $(short "$prev_sha")"
  git checkout -f "$prev_sha" >/dev/null 2>&1 || true
  install_deps || true
  chown -R "$RUN_USER:$RUN_USER" "$APP_DIR" 2>/dev/null || true
  systemctl restart "$SVC" || true
  if probe; then
    record "$new_sha" "$(short "$new_sha")" fail
    echo ""
    die "新版本有问题，已自动回退到 $(short "$prev_sha") 并恢复正常。修复后重新部署即可"
  fi
  record "$new_sha" "$(short "$new_sha")" fail
  die "回退后仍然连不上，需要人工介入：journalctl -u $SVC -n 50"
}

# ---------------------------------------------------------------- 各动作
do_init() {
  local url="$1"
  [ -n "$url" ] || die "--init 需要仓库地址，例如 https://github.com/you/repo.git"
  cd "$APP_DIR"

  step "关联远程仓库"
  if [ -d .git ]; then
    ok "已经是 git 仓库"
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin "$url"
    else
      git remote add origin "$url"
    fi
  else
    git init -q
    git remote add origin "$url"
    ok "已初始化：$APP_DIR"
  fi
  ok "origin = $url"

  step "拉取远程"
  if ! git fetch origin --prune 2>&1 | sed 's/^/    /'; then
    die "git fetch 失败。先确认能访问仓库（curl -I <仓库域名>）；国内拉 github 见 references/pitfalls.md 的镜像前缀；私有仓库需要部署密钥"
  fi

  local b; b="$(detect_branch)"
  git rev-parse --verify --quiet "origin/$b" >/dev/null 2>&1 \
    || die "远程没有分支 $b（用 BRANCH=xxx 指定）"

  # 关键顺序：先落 .gitignore，再 checkout。
  # 否则 data/ 还没被忽略，git 会把里面的文件当成"要删除的旧文件"。
  if git cat-file -e "origin/$b:.gitignore" 2>/dev/null; then
    git show "origin/$b:.gitignore" > .gitignore
    ok "已写入远程仓库的 .gitignore（数据目录受保护）"
  else
    warn "远程仓库没有 .gitignore，数据目录可能被当成普通文件"
  fi

  step "同步代码"
  git checkout -f --detach "origin/$b" 2>&1 | sed 's/^/    /'
  ok "已同步到 $(short "$(git rev-parse HEAD)")"

  echo ""
  echo "  数据目录：$DATA_DIR"
  if [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ]; then
    ok "原有数据还在，没被动过"
  else
    warn "数据目录是空的，服务首次启动会新建（如果这里有历史数据，先停下来检查）"
  fi
  echo ""
  echo "  下一步：sudo bash $PD_SELF --status"
}

do_list() {
  local h="$APP_DIR/.deploy/history"
  [ -f "$h" ] || die "还没有部署记录（先跑一次部署，或 --init 后再部署）"
  echo ""
  printf '  %-20s %-9s %-10s %s\n' "时间" "版本" "结果" "目标"
  printf '  %-20s %-9s %-10s %s\n' "--------------------" "---------" "----------" "----"
  tail -n 20 "$h" | awk '{
    r = ($4 == "ok") ? "成功" : "失败";
    printf "  %-20s %-9s %-10s %s\n", $1, substr($2,1,7), r, $3
  }'
  echo ""
  echo "  当前 HEAD：$(short "$(git rev-parse HEAD 2>/dev/null || echo none)")"
}

do_status() {
  cd "$APP_DIR"
  step "当前版本"
  git log -1 --format='  %h  %ad  %s' --date=short

  step "工作区"
  local dirty
  dirty="$(git status --porcelain 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    ok "干净（数据目录已被忽略，不算修改）"
  else
    warn "有未提交的修改，部署时会被丢弃："
    echo "$dirty" | head -15 | sed 's/^/    /'
  fi

  step "数据目录"
  if [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ]; then
    ok "$DATA_DIR（$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)）"
  else
    warn "$DATA_DIR 不存在或为空"
  fi

  step "与远程对比"
  if ! git fetch --quiet origin --prune 2>/dev/null; then
    warn "git fetch 失败（网络或凭据问题），跳过对比"
    return 0
  fi
  local b behind ahead
  b="$(detect_branch)"
  behind="$(git rev-list --count "HEAD..origin/$b" 2>/dev/null || echo '?')"
  ahead="$(git rev-list --count "origin/$b..HEAD" 2>/dev/null || echo '?')"
  echo "  远程 $b：落后 $behind 个提交，领先 $ahead 个"
  if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
    echo "  可以拉的提交："
    git log --oneline "HEAD..origin/$b" 2>/dev/null | head -10 | sed 's/^/    /'
  fi
}

do_rollback() {
  local cur target
  cur="$(git rev-parse HEAD)"
  if [ -n "$TARGET" ]; then
    target="$TARGET"
  else
    local h="$APP_DIR/.deploy/history"
    [ -f "$h" ] || die "没有部署历史，无法自动回滚。可以指定版本：--rollback <sha>"
    # 从最新往回找第一个和当前不同的版本
    target="$(awk -v cur="$cur" '{a[NR]=$2} END{for(i=NR;i>0;i--) if(a[i]!=cur){print a[i]; exit}}' "$h")"
    [ -n "$target" ] || die "历史里只有当前这一个版本，没有可回退的目标"
  fi
  ok "回退目标：$(short "$target")"
  do_deploy "$target"
}

# ---------------------------------------------------------------- 主流程
main() {
  [ -d "$APP_DIR" ] || die "目录不存在：$APP_DIR"
  cd "$APP_DIR"

  # 只读动作不要求 root，方便先在普通账号下看看情况
  case "$ACTION" in
    list|status) ;;
    *) [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $PD_SELF" ;;
  esac

  case "$ACTION" in
    init)   do_init "$INIT_URL"; exit 0 ;;
    list)   do_list;   exit 0 ;;
    status) do_status; exit 0 ;;
  esac

  # ---- 以下都是要动服务的动作 ----
  [ -d .git ] || die "$APP_DIR 不是 git 仓库。首次请先：bash $PD_SELF --init <仓库地址>"
  git remote get-url origin >/dev/null 2>&1 || die "没有配置 origin 远程地址"
  systemctl cat "$SVC" >/dev/null 2>&1 \
    || die "服务 $SVC 未注册。首次部署请先跑 $PD_SETUP，本脚本只管更新"

  read_runtime

  step "拉取远程"
  if ! git fetch --all --tags --prune 2>&1 | sed 's/^/    /'; then
    die "git fetch 失败：检查网络、仓库地址、部署密钥（见 references/pitfalls.md）"
  fi

  # 工作区有未提交修改 → checkout -f 会丢。先亮出来再决定
  local dirty
  dirty="$(git status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    warn "工作区有未提交的本地修改，部署会丢弃："
    echo "$dirty" | head -15 | sed 's/^/    /'
    if [ "$FORCE" != "1" ]; then
      die "确认要丢弃请加 --force；想保留就先 git stash 或提交"
    fi
    warn "--force，继续（这些修改将被丢弃）"
  fi

  step "停止服务"
  systemctl stop "$SVC" 2>/dev/null || true
  ok "已停止（保证数据库是静止的，备份才一致）"

  backup_data

  if [ "$ACTION" = "rollback" ]; then
    do_rollback
  else
    do_deploy "$TARGET"
  fi

  # 参数快照：老部署（没有 .deploy/env）第一次跑完就自动补写一份，以后可以裸跑。
  # 只在文件不存在时写：已有的快照是权威配置，临时显式传的参数不应把它改掉。
  # 想改配置请重跑 setup.sh（它会重写），或直接编辑 .deploy/env。
  if [ ! -f "$DEPLOY_ENV_PATH" ]; then
    if deploy_env_save "$DEPLOY_ENV_PATH"; then
      ok "已生成 .deploy/env：本次参数已固化，以后可直接裸跑"
      if [ "$DEPLOY_ENV_PATH" != "$APP_DIR/.deploy/env" ]; then
        ok "实际路径：$DEPLOY_ENV_PATH"
      fi
    else
      warn "写 $DEPLOY_ENV_PATH 失败（不影响本次部署），下次仍需手动传 SVC / DATA_DIR / HEALTH"
    fi
  fi

  # ---- 收尾 ----
  local cur
  cur="$(git rev-parse HEAD)"
  echo ""
  echo -e "${c_ok}======================================================================${c_0}"
  echo -e "${c_ok}   部署完成${c_0}"
  echo -e "${c_ok}======================================================================${c_0}"
  echo "  当前版本： $(short "$cur")  $(git log -1 --format=%s "$cur" | cut -c1-50)"
  echo "  服务状态： $(systemctl is-active "$SVC" 2>/dev/null || echo unknown)"
  echo "  数据目录： $DATA_DIR（未被改动）"
  echo ""
  echo "  看历史：   sudo bash $PD_SELF --list"
  echo "  要回滚：   sudo bash $PD_SELF --rollback"
  echo ""
}

main
