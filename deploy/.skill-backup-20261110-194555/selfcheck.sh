#!/usr/bin/env bash
# =====================================================================
#  git-repo-deploy · 一键体检
#
#  用法（不需要 root，但有些项需要 root 才看得全）：
#    bash deploy/selfcheck.sh
#    sudo bash deploy/selfcheck.sh
#    sudo -E SVC=myapp WEB_PORT=8090 APP_DIR=/data/web/myapp bash deploy/selfcheck.sh
#    cd /data/web/app && sudo bash /opt/git-repo-deploy/selfcheck.sh  解耦用法
#
#  全部自动推断，也可以手动传：SVC / APP_DIR / DATA_DIR / WEB_PORT / HEALTH
#  配置文件自动发现：DEPLOY_ENV_FILE > deploy/deploy.conf > 中央索引 >
#  /etc/git-repo-deploy/<目录名>.conf > .deploy/env；命令行显式传入优先。
#  脚本可放在 /opt/git-repo-deploy 等仓库外目录，cd 到项目目录即可裸跑。
#  发现 ✗ 的项，最后会汇总出可复制的修复命令。
# =====================================================================
set -uo pipefail

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

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_0=$'\033[0m'
PASS=0; WARN=0; FAIL=0
FIXES=()

sec() { echo -e "\n\033[36m▶ $*\033[0m"; }
pass() { echo -e "  ${c_ok}✓${c_0} $*"; PASS=$((PASS+1)); }
warn() { echo -e "  ${c_warn}!${c_0} $*"; WARN=$((WARN+1)); }
fail() { echo -e "  ${c_err}✗${c_0} $*"; FAIL=$((FAIL+1)); }
note() { echo -e "    ${c_dim}$*${c_0}"; }

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
fix()  { FIXES+=("$*"); }
# 体检给出的修复命令要指向脚本真实位置；解耦部署时脚本不在项目 deploy/ 里。
SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_SELF="$SC_DIR/$(basename "${BASH_SOURCE[0]}")"
SC_SETUP="$SC_DIR/setup.sh"
SC_PULL="$SC_DIR/pull-deploy.sh"

# 参数初始化必须放在 derive_name 定义之后：原版在定义前就调用它，
# 裸跑时 def_name 为空、SVC 变成空串，八组检查会全部找错对象。
SC_SCRIPT_PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo "$PWD")"
if [ -d "$SC_SCRIPT_PARENT/.git" ]; then
  APP_DIR="${APP_DIR:-$SC_SCRIPT_PARENT}"
else
  APP_DIR="${APP_DIR:-$PWD}"
fi
DEPLOY_ENV_PATH="$(deploy_env_path "$APP_DIR")"
deploy_env_load "$DEPLOY_ENV_PATH"
def_name="$(derive_name "$APP_DIR")"
SVC="${SVC:-$def_name}"
DATA_DIR="${DATA_DIR:-$APP_DIR/data}"
HEALTH="${HEALTH:-/api/ping}"
WEB_PORT="${WEB_PORT:-}"
NGX_CONF="/etc/nginx/conf.d/$SVC.conf"

echo -e "${c_dim}APP_DIR=$APP_DIR  SVC=$SVC  DATA_DIR=$DATA_DIR${c_0}"
if [ "${DEPLOY_ENV_LOADED:-0}" = "1" ]; then
  echo -e "${c_dim}参数来源：$DEPLOY_ENV_PATH（命令行显式传入的优先）${c_0}"
else
  echo -e "${c_dim}参数来源：命令行 / 脚本默认值；没有配置文件，重跑 setup.sh 可生成${c_0}"
fi

# ---------------------------------------------------------------- 1. 服务
sec "1/8 服务状态"
if ! command -v systemctl >/dev/null 2>&1; then
  fail "没有 systemctl（这不是 systemd 系统？）"
elif ! systemctl cat "$SVC" >/dev/null 2>&1; then
  fail "服务 $SVC 未注册"
  fix "首次部署：sudo -E APP_DIR=$APP_DIR bash $SC_SETUP；或传对服务名：SVC=真实服务名"
else
  pass "unit 存在：/etc/systemd/system/$SVC.service"
  STATE="$(systemctl is-active "$SVC" 2>/dev/null || true)"
  case "$STATE" in
    active) pass "服务运行中";;
    failed) fail "服务 failed"
            fix "journalctl -u $SVC -n 50 --no-pager  然后 systemctl restart $SVC";;
    *)      fail "服务状态：$STATE"
            fix "systemctl start $SVC && journalctl -u $SVC -n 50 --no-pager";;
  esac
  if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
    pass "开机自启已启用"
  else
    warn "开机自启未启用"
    fix "systemctl enable $SVC"
  fi
fi

# 从 unit 里读出真实的运行账号、端口、启动命令、数据目录
RUN_USER=""; PORT=""; START=""
if systemctl cat "$SVC" >/dev/null 2>&1; then
  RUN_USER="$(systemctl show -p User --value "$SVC" 2>/dev/null)"
  [ -n "$RUN_USER" ] || RUN_USER=root
  PORT="$(systemctl show -p Environment --value "$SVC" 2>/dev/null \
    | tr ' ' '\n' | sed -n 's/^PORT=//p' | head -1)"
  START="$(systemctl show -p ExecStart --value "$SVC" 2>/dev/null \
    | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' | head -1)"
fi

# ---------------------------------------------------------------- 2. 启动命令
sec "2/8 启动命令"
if [ -z "$START" ]; then
  warn "读不到 ExecStart"
else
  BIN="${START%% *}"
  if [ -x "$BIN" ] || command -v "$BIN" >/dev/null 2>&1; then
    pass "可执行文件存在：$BIN"
  else
    fail "启动用的可执行文件不存在：$BIN"
    note "常见原因：换过 Node 版本 / 删了 .venv / nvm 装的 node 不在 systemd 的 PATH 里"
    fix "重跑 $SC_SETUP 重新渲染 unit；或把 ExecStart 改成绝对路径后 systemctl daemon-reload"
  fi
  ENTRY_FILE="$(printf '%s\n' "$START" | tr ' ' '\n' | grep -E "^$APP_DIR/" | head -1)"
  if [ -n "$ENTRY_FILE" ]; then
    if [ -f "$ENTRY_FILE" ]; then
      pass "入口文件存在：$ENTRY_FILE"
    else
      fail "入口文件不存在：$ENTRY_FILE"
      fix "cd $APP_DIR && git status  看代码是否完整；必要时 sudo bash $SC_PULL --force"
    fi
  fi
fi

# ---------------------------------------------------------------- 3. 端口
sec "3/8 端口监听"
if [ -z "$PORT" ]; then
  warn "unit 里没读到 PORT 环境变量，跳过"
elif command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
    pass "127.0.0.1:$PORT 正在监听"
  else
    fail "没有任何进程监听 $PORT"
    fix "journalctl -u $SVC -n 50 --no-pager   看进程为什么没起来"
  fi
else
  warn "没有 ss 命令（apt install iproute2）"
fi

# ---------------------------------------------------------------- 4. 探针
sec "4/8 内部探针"
if [ -z "$PORT" ]; then
  warn "跳过（端口未知）"
else
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT$HEALTH" 2>/dev/null || echo 000)"
  case "$CODE" in
    200|204) pass "GET $HEALTH → $CODE";;
    000)     fail "GET $HEALTH 连不上（服务没在监听，或路径被 Nginx 之外的东西挡住）"
             fix "curl -v http://127.0.0.1:$PORT$HEALTH";;
    404)     warn "GET $HEALTH → 404（服务活着，但健康检查路径不对）"
             fix "重跑部署时指定真实路径：HEALTH=/ 或 HEALTH=/healthz";;
    *)       warn "GET $HEALTH → $CODE（服务有响应，自行确认是否符合预期）";;
  esac
fi

# ---------------------------------------------------------------- 5. Nginx
sec "5/8 Nginx 反向代理"
if [ ! -f "$NGX_CONF" ]; then
  warn "没有 $NGX_CONF（可能用了 NO_NGINX=1，或服务名传错了）"
else
  pass "配置存在：$NGX_CONF"

  if [ -z "$WEB_PORT" ]; then
    WEB_PORT="$(sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9]\+\).*/\1/p' "$NGX_CONF" | head -1)"
  fi
  [ -n "$WEB_PORT" ] || WEB_PORT=80

  if grep -q 'proxy_buffering off' "$NGX_CONF"; then
    pass "实时推送已关缓冲（SSE 不会卡住）"
  else
    warn "配置里没找到 proxy_buffering off"
    note "如果项目有 SSE / 长轮询，大屏和进度墙可能完全不刷新"
  fi

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      pass "nginx -t 通过"
    else
      fail "nginx -t 报错"
      fix "sudo nginx -t   看具体行号；同机多实例常见 duplicate upstream / duplicate zone"
    fi
  fi

  if systemctl is-active --quiet nginx 2>/dev/null; then
    pass "nginx 运行中"
  else
    fail "nginx 没在运行"
    fix "systemctl restart nginx && journalctl -u nginx -n 30 --no-pager"
  fi

  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$WEB_PORT/" 2>/dev/null || echo 000)"
  case "$CODE" in
    200) pass "对外 $WEB_PORT → 200";;
    401) pass "对外 $WEB_PORT → 401（口令生效，正常）";;
    403) pass "对外 $WEB_PORT → 403（IP 白名单生效，正常）";;
    000) fail "对外 $WEB_PORT 无响应"
         fix "sudo tail -30 /var/log/nginx/error.log";;
    502|504) fail "对外 $WEB_PORT → $CODE（Nginx 连不上后端）"
         note "后端端口不对 / 进程没起 / upstream 名字被另一个实例占了"
         fix "sudo tail -30 /var/log/nginx/error.log 并核对 $NGX_CONF 里的 proxy_pass 端口";;
    *)   warn "对外 $WEB_PORT → $CODE";;
  esac
fi

# ---------------------------------------------------------------- 6. 权限
sec "6/8 文件权限"
if [ -d "$APP_DIR" ]; then
  OWNER="$(stat -c %U "$APP_DIR" 2>/dev/null || echo '?')"
  if [ -n "$RUN_USER" ] && [ "$OWNER" != "$RUN_USER" ]; then
    warn "代码目录属主是 $OWNER，但服务以 $RUN_USER 运行"
    note "git 命令会报 dubious ownership；写文件会 Permission denied"
    fix "chown -R $RUN_USER:$RUN_USER $APP_DIR"
  else
    pass "代码目录属主：$OWNER"
  fi
fi

if [ -d "$DATA_DIR" ]; then
  if [ -n "$RUN_USER" ] && command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    if sudo -u "$RUN_USER" test -w "$DATA_DIR" 2>/dev/null; then
      pass "数据目录对 $RUN_USER 可写"
    else
      fail "数据目录对 $RUN_USER 不可写"
      fix "chown -R $RUN_USER:$RUN_USER $DATA_DIR && chmod 755 $DATA_DIR"
    fi
  else
    pass "数据目录存在：$DATA_DIR"
  fi
  SZ="$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
  note "占用：$SZ"
else
  warn "数据目录不存在：$DATA_DIR（首次启动会自动创建；如果不是首次，检查路径是否传错）"
fi

# 加固项与目录位置冲突（ProtectHome=true 会把 /home 藏起来）
if systemctl cat "$SVC" >/dev/null 2>&1; then
  if systemctl show -p ProtectHome --value "$SVC" 2>/dev/null | grep -q yes; then
    case "$APP_DIR$DATA_DIR" in
      *"/home/"*|*"/root/"*)
        fail "unit 开了 ProtectHome=true，但代码/数据在 /home 或 /root 下 —— 服务必然 ENOENT"
        fix "删掉 unit 里的 ProtectHome=true（或设 false）后 systemctl daemon-reload && systemctl restart $SVC"
        ;;
      *) pass "ProtectHome 与目录位置不冲突";;
    esac
  else
    pass "ProtectHome 未强制开启"
  fi
fi

# ---------------------------------------------------------------- 7. git 状态
sec "7/8 版本与仓库"
if [ -d "$APP_DIR/.git" ]; then
  if git -C "$APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    pass "git 可读（$(
      git -C "$APP_DIR" log -1 --format='%h %ad %s' --date=short 2>/dev/null | cut -c1-60
    ))"
    DIRTY="$(git -C "$APP_DIR" status --porcelain 2>/dev/null | head -5)"
    if [ -n "$DIRTY" ]; then
      warn "有未提交改动（下次部署会被丢弃）"
      echo "$DIRTY" | sed 's/^/      /'
    else
      pass "工作区干净"
    fi
    case "$DATA_DIR" in
      "$APP_DIR"/*) DREL="${DATA_DIR#"$APP_DIR"/}";; *) DREL="";;
    esac
    if [ -n "$DREL" ] && [ -n "$(git -C "$APP_DIR" ls-files --error-unmatch "$DREL" 2>/dev/null)" ]; then
      fail "$DREL/ 被 git 跟踪了 —— 下次部署会覆盖线上数据"
      fix "echo '$DREL/' >> $APP_DIR/.gitignore && git -C $APP_DIR rm -r --cached '$DREL'"
    elif [ -n "$DREL" ]; then
      pass "数据目录（$DREL/）没有被 git 跟踪"
    else
      warn "数据目录不在代码目录内，跳过 git 跟踪检查"
    fi
  else
    fail "git 读不了这个仓库（dubious ownership）"
    fix "git config --global --add safe.directory $APP_DIR"
  fi
  [ -f "$APP_DIR/.deploy/history" ] && \
    note "最近一次部署：$(tail -1 "$APP_DIR/.deploy/history" | awk '{print $1, substr($2,1,7), $4}')"
else
  warn "不是 git 仓库 —— pull-deploy.sh 不可用（这种部署方式等于手工拷贝，不能回滚）"
fi

# ---------------------------------------------------------------- 8. 系统资源
sec "8/8 系统资源"
if command -v node >/dev/null 2>&1; then
  note "Node：$(node -p 'process.versions.node' 2>/dev/null)"
fi
AVAIL="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${AVAIL:-}" ] && [ "$AVAIL" -lt 1024 ] 2>/dev/null; then
  fail "根分区只剩 ${AVAIL}MB —— 数据库写入会失败（SQLITE_FULL）"
  fix "清理日志：journalctl --vacuum-size=200M；或把数据目录迁到别的盘"
else
  [ -n "${AVAIL:-}" ] && pass "根分区可用 $((AVAIL/1024))GB"
fi

LOAD="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '?')"
note "负载：$LOAD  内存：$(free -h 2>/dev/null | awk 'NR==2{print $3"/"$2}' || echo '?')"

if [ "$FAIL" -gt 0 ]; then
  sec "最近日志（末尾 15 行，帮助定位）"
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true
fi

# ---------------------------------------------------------------- 汇总
echo ""
echo "======================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e " ${c_ok}体检通过${c_0}：$PASS 项正常，$WARN 项提醒，0 项故障"
else
  echo -e " ${c_err}发现 $FAIL 项故障${c_0}：$PASS 项正常，$WARN 项提醒"
fi
echo "======================================================================"
if [ "${#FIXES[@]}" -gt 0 ]; then
  echo "  建议依次执行："
  i=1
  for f in "${FIXES[@]}"; do
    echo "   $i) $f"
    i=$((i+1))
  done
fi
echo ""
[ "$FAIL" -eq 0 ] || exit 1
