#!/usr/bin/env bash
# 扫描候选代码库：当前目录 + 一层子目录，标出仓库、端归属、分支情况
#
# 用法: scan-repos.sh [基准目录]
#   基准目录省略时取当前终端目录。
#
# 用途: 引导使用者确认「项目地址（前端/后端）」时，用扫描结果做预填，
#       避免让使用者凭空想路径。
#
# 输出: 人类可读表格 + 末尾 TSV 段（机器可读，供 agent 直接取用）

set -uo pipefail

BASE="${1:-$PWD}"
if ! BASE="$(cd "$BASE" 2>/dev/null && pwd -P)"; then
  echo "基准目录不存在: ${1}" >&2
  exit 1
fi

# ---------- 收集候选目录（仓库根，不是仓库内部的子目录） ----------
CANDIDATES=()
is_repo_root() {
  local d="$1" top
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$d" && pwd -P)" ]
}

if is_repo_root "$BASE"; then
  CANDIDATES+=("$BASE")
fi
for d in "$BASE"/*/; do
  [ -d "$d" ] || continue
  d="${d%/}"
  [ "$d" = "$BASE" ] && continue
  if is_repo_root "$d"; then
    CANDIDATES+=("$d")
  fi
done

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "基准目录: $BASE"
  echo "未发现任何 git 仓库（当前目录本身及其一层子目录均不是仓库根）"
  echo
  echo "TSV"
  echo -e "name\tpath\tkind\tbranch\thas_master\thas_main\tdirty\tmarkers"
  exit 0
fi

# ---------- 逐仓采集 ----------
ROWS=""
BACKEND_LIST=""
FRONTEND_LIST=""
OTHER_LIST=""

for d in "${CANDIDATES[@]}"; do
  name="$(basename "$d")"

  # 当前分支（detached 时为空）
  branch="$(git -C "$d" branch --show-current 2>/dev/null)"
  [ -z "$branch" ] && branch="(detached HEAD)"

  # 是否有 master / main
  has_master="否"
  git -C "$d" rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1 && has_master="有"
  has_main="否"
  git -C "$d" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 && has_main="有"

  # 是否有提交
  if git -C "$d" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    commit="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
    dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  else
    commit="(无提交)"
    dirty="-"
  fi

  # 端归属标记
  markers=""
  is_backend="否"
  is_frontend="否"
  for f in pom.xml build.gradle build.gradle.kts settings.gradle go.mod Cargo.toml pyproject.toml; do
    if [ -f "$d/$f" ]; then
      markers="${markers}${markers:+,}$f"
      is_backend="是"
    fi
  done
  for f in "$d"/*.sln; do
    [ -f "$f" ] || continue
    markers="${markers}${markers:+,}$(basename "$f")"
    is_backend="是"
  done
  # package.json 不足以判定前端 —— 多仓工作区根常放空壳 package.json 当骨架。
  # 必须命中真实前端框架依赖才算前端仓。
  fw_note=""
  if [ -f "$d/package.json" ]; then
    markers="${markers}${markers:+,}package.json"
    if grep -qE '"(vue|react|vite|@angular/core|svelte|nuxt|next|uni-app|taro|webpack)"' "$d/package.json" 2>/dev/null; then
      is_frontend="是"
    else
      fw_note="package.json 无前端框架依赖，多为工作区骨架而非前端仓"
    fi
  fi

  kind="未判定"
  if [ "$is_backend" = "是" ] && [ "$is_frontend" = "是" ]; then
    kind="前后端"
  elif [ "$is_backend" = "是" ]; then
    kind="后端"
  elif [ "$is_frontend" = "是" ]; then
    kind="前端"
  fi

  note=""
  if [ "$commit" = "(无提交)" ]; then
    note="⚠ 无提交，只能取工作区现状"
  elif [ "$has_master" = "否" ] && [ "$has_main" = "否" ]; then
    note="⚠ 无 master/main，只能取工作区现状"
  fi
  [ -n "$fw_note" ] && note="${note}${note:+ }${fw_note}"

  line="$name	$d	$kind	$branch	$has_master	$has_main	$dirty	${markers:--}	$commit	$note"
  ROWS="${ROWS}${line}
"

  case "$kind" in
    后端|前后端) BACKEND_LIST="${BACKEND_LIST}${d}
" ;;
    前端) FRONTEND_LIST="${FRONTEND_LIST}${d}
" ;;
    *) OTHER_LIST="${OTHER_LIST}${d}
" ;;
  esac
done

print_group() {
  local title="$1" list="$2"
  [ -z "$list" ] && return 0
  echo "== ${title} =="
  local n=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    n=$((n + 1))
    local row
    row="$(printf '%s' "$ROWS" | grep -F "$(printf '%s\t' "$(basename "$d")")" | head -1)"
    local branch dirty masters mains commit note
    branch="$(printf '%s' "$row" | cut -f4)"
    masters="$(printf '%s' "$row" | cut -f5)"
    mains="$(printf '%s' "$row" | cut -f6)"
    dirty="$(printf '%s' "$row" | cut -f7)"
    markers="$(printf '%s' "$row" | cut -f8)"
    commit="$(printf '%s' "$row" | cut -f9)"
    note="$(printf '%s' "$row" | cut -f10)"
    echo "  ${n}. $d"
    echo "     分支=$branch  master=$masters  main=$mains  提交=$commit  未提交=${dirty}  标记=${markers}"
    [ -n "$note" ] && echo "     $note"
  done <<< "$list"
  echo
}

echo "代码库扫描基准: $BASE"
echo "发现 ${#CANDIDATES[@]} 个候选仓库"
echo
print_group "后端候选" "$BACKEND_LIST"
print_group "前端候选" "$FRONTEND_LIST"
print_group "未判定（无构建标记）" "$OTHER_LIST"

echo "TSV"
echo -e "name\tpath\tkind\tbranch\thas_master\thas_main\tdirty\tmarkers\tcommit\tnote"
printf '%s' "$ROWS"
