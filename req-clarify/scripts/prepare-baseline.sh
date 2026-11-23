#!/usr/bin/env bash
# req-clarify · 代码基线准备脚本
#
# 用途：把「这次澄清对照哪份代码」这件事钉死。
#       开发常常忘记切分支，工作区停在 feature 分支上 —— 扫出来的"现状"其实是
#       开发中间态，澄清出来的"缺陷"有一半是伪缺陷。
#       本脚本只认 master / main（可用 --branch 显式覆盖），并把该分支的代码
#       导出一份**只读副本**，后续所有读取都基于这份副本 —— 不动使用者的工作区。
#
# 用法: prepare-baseline.sh <repo路径> [基线根目录] [--branch <分支>] [--label <后端|前端>]
#   基线根目录：基线快照落在这里。默认 ${TMPDIR:-/tmp}/req-clarify-baseline
#                —— **不在产物目录里**，产物目录只放 Markdown。
#   实际路径   ：<基线根目录>/<repo名>/<分支>-<提交>/
#                内容寻址：同一 (repo, 分支, 提交) 永远落在同一路径 → 自动复用，
#                不需要显式传参指定"上一迭代的基线目录"。
#   --branch   ：指定基线分支（默认 master，无则 main）
#   --label    ：报告标题前缀（如「后端」「前端」），便于区分两份基线。
#
# 输出：基线信息报告（stdout），并写入 <基线目录>/.baseline-info
#
# 三种情形（脚本自己判断，不猜）：
#   A. master/main 存在且覆盖完整 → 用分支导出的副本（严格基线）
#   B. master/main 存在，但有源文件未被跟踪 → 分支副本 + 补入工作区未跟踪源文件
#   C. 无 master/main（无提交 / 非 git 仓库）→ 直接用工作区，并明确警告

set -uo pipefail

REPO="${1:-}"
BASE_ROOT="${2:-}"
BRANCH_OVERRIDE=""
LABEL=""

# 先吃掉位置参数之后的 flags
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "用法: prepare-baseline.sh <repo路径> [基线根目录] [--branch <分支>] [--label <后端|前端>]" >&2
  exit 1
fi
if [[ ! -d "$REPO" ]]; then
  echo "错误: 目录不存在: $REPO" >&2
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"
RAW_LABEL="$LABEL"
[[ -n "$LABEL" ]] && LABEL="$LABEL · "
[[ -z "$BASE_ROOT" ]] && BASE_ROOT="${TMPDIR:-/tmp}/req-clarify-baseline"

SRC_EXTS="ts tsx js jsx vue java kt kts go py rb php cs sql xml yaml yml json prisma graphql"

# ---------- 判定是否 git 仓库 ----------
IS_GIT=0
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1

# ---------- 解析基线分支 ----------
BRANCH=""
COMMIT=""
if [[ $IS_GIT -eq 1 ]]; then
  if [[ -n "$BRANCH_OVERRIDE" ]]; then
    if git -C "$REPO" rev-parse --verify --quiet "$BRANCH_OVERRIDE^{commit}" >/dev/null 2>&1; then
      BRANCH="$BRANCH_OVERRIDE"
    fi
  else
    for b in master main; do
      if git -C "$REPO" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1; then
        BRANCH="$b"; break
      fi
    done
  fi
  if [[ -n "$BRANCH" ]]; then
    COMMIT="$(git -C "$REPO" rev-parse --short "$BRANCH" 2>/dev/null)"
  fi
fi

# ---------- 工作区状态 ----------
WT_BRANCH="(非 git 仓库)"
WT_DIRTY="未知"
if [[ $IS_GIT -eq 1 ]]; then
  WT_BRANCH="$(git -C "$REPO" branch --show-current 2>/dev/null)"
  [[ -z "$WT_BRANCH" ]] && WT_BRANCH="(detached HEAD)"
  WT_DIRTY="$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
fi

# ---------- 基线路径：内容寻址 <根>/<repo名>/<分支>-<提交> ----------
# 同一 (repo, 分支, 提交) 永远落在同一路径 → 自动复用，不需要显式指定"上一迭代的基线目录"。
SLOT="${BASE_ROOT}/${REPO_NAME}"
if [[ -n "$BRANCH" ]]; then
  BASE_DIR="${SLOT}/${BRANCH}-${COMMIT:-nocommits}"
else
  BASE_DIR="${SLOT}/worktree"
fi
mkdir -p "$BASE_DIR" || { echo "错误: 无法创建 $BASE_DIR" >&2; exit 1; }
INFO="$BASE_DIR/.baseline-info"

# ---------- 复用判定：目标槽位已存在且是干净分支基线 → 直接复用 ----------
# 仅当：① 本次锁定了分支+提交；② 槽位已有 .baseline-info 且 BRANCH+COMMIT 一致；
#       ③ 其 MODE=branch（干净分支基线，无 supplement/未降级工作区）。
REUSED_FROM=""
REUSE_TREE=""
if [[ -n "$BRANCH" && -n "$COMMIT" && -f "$INFO" ]]; then
  prev_branch="" prev_commit="" prev_mode=""
  while IFS='=' read -r k v; do
    case "$k" in
      BRANCH) prev_branch="$v" ;;
      COMMIT) prev_commit="$v" ;;
      MODE)   prev_mode="$v" ;;
    esac
  done < "$INFO"
  if [[ "$prev_branch" == "$BRANCH" && "$prev_commit" == "$COMMIT" && "$prev_mode" == "branch" ]]; then
    REUSE_TREE="$(find "$BASE_DIR" -maxdepth 1 -type d -name 'tree-*' 2>/dev/null | head -n 1)"
    [[ -n "$REUSE_TREE" ]] && REUSED_FROM="$REUSE_TREE"
  fi
fi

count_src() {  # count_src <dir> —— 统计源文件数
  local d="$1" pat="" e cnt
  for e in $SRC_EXTS; do
    if [[ -n "$pat" ]]; then pat="$pat -o"; fi
    pat="$pat -name *.$e"
  done
  cnt=$(find "$d" -type d \( -name node_modules -o -name .git -o -name dist -o -name build \
        -o -name target -o -name vendor -o -name .next -o -name coverage \) -prune \
        -o -type f \( $pat \) -print 2>/dev/null | wc -l)
  printf '%s' "${cnt// /}"
}

MODE=""
BASE_TREE=""
SUPPLEMENTED=0
WT_SRC="$(count_src "$REPO")"

if [[ -n "$BRANCH" ]]; then
  # ---------- 情形 A / B：分支存在，导出副本 ----------
  # 目录名带上分支与提交号 —— 同一基线重复运行会复用同一目录，不会残留旧文件
  BASE_TREE="$BASE_DIR/tree-${BRANCH}-${COMMIT:-nocommits}"

  if [[ -n "$REUSE_TREE" ]]; then
    # ---------- 复用：同一 (repo,分支,提交) 槽位已存在且是干净分支基线 → 直接用 ----------
    BASE_TREE="$REUSE_TREE"
    FINAL=$(count_src "$BASE_TREE")
    MODE="branch"
  else
    mkdir -p "$BASE_TREE"
    git -C "$REPO" archive "$BRANCH" 2>/dev/null | tar -x -C "$BASE_TREE" 2>/dev/null
    ARCHIVED=$(count_src "$BASE_TREE")

    # 分支没跟踪、但工作区里有的源文件 —— 补进去（这些文件在任何分支里都没有版本）
    # 【收紧】只补 src/ 下的源文件：文档/图片/临时产物不是"现状"，补进来只会污染基线
    if [[ $IS_GIT -eq 1 && $WT_SRC -gt $ARCHIVED ]]; then
      while IFS= read -r f; do
        rel="${f#"$REPO"/}"
        case "$rel" in
          src/*) ;;                       # 只补 src/ 下的
          *) continue ;;
        esac
        case "$rel" in
          *.ts|*.tsx|*.js|*.jsx|*.vue|*.java|*.kt|*.kts|*.go|*.py|*.rb|*.php|*.cs|*.sql|*.xml|*.yaml|*.yml|*.json) ;;
          *) continue ;;
        esac
        mkdir -p "$BASE_TREE/$(dirname "$rel")" 2>/dev/null
        cp "$REPO/$rel" "$BASE_TREE/$rel" 2>/dev/null && SUPPLEMENTED=$((SUPPLEMENTED+1))
      done < <(git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null)
    fi

    FINAL=$(count_src "$BASE_TREE")
    # 只要没补任何文件，基线就是纯 master 副本 → 严格基线
    if [[ $SUPPLEMENTED -eq 0 ]]; then
      MODE="branch"
    else
      MODE="branch+supplement"
    fi
  fi
else
  # ---------- 情形 C：无 master/main，直接用工作区 ----------
  MODE="worktree"
  BASE_TREE="$REPO"
  FINAL="$WT_SRC"
fi

{
  echo "MODE=$MODE"
  echo "BRANCH=${BRANCH:-（无）}"
  echo "COMMIT=${COMMIT:-（无提交）}"
  echo "TREE=$BASE_TREE"
  echo "WORKTREE_BRANCH=$WT_BRANCH"
  echo "WORKTREE_DIRTY=$WT_DIRTY"
  echo "SRC_FILES=$FINAL"
  echo "REPO=$REPO"
  echo "LABEL=${RAW_LABEL:-（无）}"
  echo "REUSED_FROM=${REUSED_FROM:-}"
} > "$INFO"

# ---------- 报告 ----------
echo "════════════════════════════════════════════════════════════"
echo "${LABEL}代码基线"
echo "════════════════════════════════════════════════════════════"
echo "基线分支    : ${BRANCH:-（无 —— 未能锁定）}"
echo "基线提交    : ${COMMIT:-（无提交）}"
echo "基线目录    : $BASE_TREE"
echo "源文件数    : $FINAL"
echo "工作区分支  : $WT_BRANCH"
echo "工作区改动  : ${WT_DIRTY} 处"

if [[ -n "$REUSED_FROM" ]]; then
  echo ""
  echo "♻ 复用已存在的基线槽位（BRANCH+COMMIT 一致、MODE=branch，跳过 git archive）"
fi

case "$MODE" in
  branch)
    echo ""
    echo "✔ 基线 = ${BRANCH}@${COMMIT}（分支内容完整覆盖工作区源文件）"
    ;;
  branch+supplement)
    echo ""
    echo "⚠ 基线 = ${BRANCH}@${COMMIT} + ${SUPPLEMENTED} 个未跟踪源文件"
    echo "  这些文件在 $BRANCH 里根本没有版本（未被 git 跟踪），"
    echo "  只能取自工作区。**该分支不是完整基线** —— 结论要标注这一点。"
    ;;
  worktree)
    echo ""
    echo "⚠ 未能锁定基线：$([[ $IS_GIT -eq 1 ]] && echo '该仓库无 master/main 提交' || echo '该目录不是 git 仓库')"
    echo "  已退化为读取**工作区现状**。工作区分支：$WT_BRANCH"
    echo "  **必须向使用者说明**：本次证据取自工作区，若工作区不是主干代码，结论会失真。"
    ;;
esac

if [[ $IS_GIT -eq 1 && -n "$BRANCH" && "$WT_BRANCH" != "$BRANCH" ]]; then
  echo ""
  echo "ℹ 工作区当前在 '$WT_BRANCH'，基线读的是 '$BRANCH' —— 不影响本次读取（读的是副本），"
  echo "  但你自己看代码时记得别被工作区版本误导。"
fi

echo ""
echo "后续所有读取都基于：$BASE_TREE"
echo "基线槽位：$BASE_DIR"
echo "基线根目录：$BASE_ROOT"
echo "提示：基线在缓存目录，**不在产物目录里** —— 产物目录只放 Markdown。"
echo "════════════════════════════════════════════════════════════"
