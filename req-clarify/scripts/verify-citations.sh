#!/usr/bin/env bash
# req-clarify · 代码引用校验器
#
# 用途：校验产物文档里的每一处 `文件:行号` 引用是否真实存在。
#       问题澄清的价值全靠代码证据支撑 —— 引用失效，问题上产品就答不准。
#
# 用法: verify-citations.sh --baseline <基线目录> [--baseline <基线目录>] -- <文档文件...>
#   基线目录：prepare-baseline.sh 产出的基线树（<基线根>/<repo名>/<分支>-<提交> 下的
#             tree-<分支>-<提交>）—— 校验必须对着**出证据时那份代码**，否则工作区一换分支就全是误报。
#   支持多份基线：前后端双仓时各传一个 --baseline，引用在所有基线里搜，命中后标注
#                 [后端@master-d1b127a03] 形式（端 + 版本，取自 .baseline-info 的 LABEL + 槽位目录名）。
#
# 输出：
#   OK          引用有效
#   OUT-OF-RANGE 行号超出文件范围
#   FILE-NOT-FOUND 文件找不到
#   末尾附「引用内容预览」，供人工核对语义是否对得上

set -uo pipefail

BASELINES=()
DOCS=()
SEEN_DASHDASH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINES+=("${2:-}"); shift 2 ;;
    --) SEEN_DASHDASH=1; shift ;;
    *)
      if [[ $SEEN_DASHDASH -eq 1 ]]; then
        DOCS+=("$1"); shift
      else
        # 兼容老用法：第一个位置参数视作基线，其余视作文档
        if [[ ${#BASELINES[@]} -eq 0 ]]; then
          BASELINES+=("$1"); shift
        else
          DOCS+=("$1"); shift
        fi
      fi
      ;;
  esac
done

if [[ ${#BASELINES[@]} -eq 0 ]]; then
  echo "用法: verify-citations.sh --baseline <基线目录> [--baseline <基线目录>] -- <文档文件...>" >&2
  exit 1
fi

# 规范化基线目录：若传的是基线槽位这一层（含 .baseline-info 但无 tree-*），
# 自动下沉到其中的 tree-* 目录。
NORMALIZED_BASELINES=()
BASEINFO_PATHS=()
for b in "${BASELINES[@]}"; do
  [[ -z "$b" ]] && continue
  if [[ ! -d "$b" ]]; then
    echo "警告: 基线目录不存在，跳过: $b" >&2
    continue
  fi
  b="$(cd "$b" && pwd)"
  tree_dir="$(find "$b" -maxdepth 1 -type d -name 'tree-*' 2>/dev/null | head -n 1)"
  if [[ -n "$tree_dir" ]]; then
    NORMALIZED_BASELINES+=("$tree_dir")
  else
    NORMALIZED_BASELINES+=("$b")
  fi
  BASEINFO_PATHS+=("$b/.baseline-info")
done

if [[ ${#NORMALIZED_BASELINES[@]} -eq 0 ]]; then
  echo "错误: 没有有效的基线目录" >&2
  exit 1
fi

if [[ ${#DOCS[@]} -eq 0 ]]; then
  echo "请至少指定一个文档文件（用 -- 分隔基线与文档）" >&2
  exit 1
fi

# 给每个基线一个标签：优先读 .baseline-info 里的 LABEL（后端/前端），
# 拼上槽位目录名（<分支>-<提交>）→ 「后端@master-d1b127a03」，一眼看出证据端 + 版本
label_for() {
  local info="$1" base_parent slot raw
  base_parent="$(dirname "$info")"
  slot="$(basename "$base_parent")"
  raw=""
  if [[ -f "$info" ]]; then
    while IFS='=' read -r k v; do
      [[ "$k" == "LABEL" ]] && raw="$v"
    done < "$info"
  fi
  if [[ -n "$raw" && "$raw" != "（无）" ]]; then
    printf '%s@%s' "$raw" "$slot"
  else
    printf '%s' "$slot"
  fi
}

CITE_RE='[A-Za-z0-9_][A-Za-z0-9_./-]*\.(ts|tsx|js|jsx|vue|java|kt|kts|go|py|rb|php|cs|sql|xml|yaml|yml|json|md):[0-9]+'

ok=0; bad=0; preview=""

for doc in "${DOCS[@]}"; do
  [[ -f "$doc" ]] || { echo "跳过（文件不存在）: $doc" >&2; continue; }

  cites="$(grep -ohE "$CITE_RE" "$doc" 2>/dev/null | sort -u)"

  while IFS= read -r cite; do
    [[ -z "$cite" ]] && continue
    path="${cite%:*}"
    num="${cite##*:}"

    # 在所有基线里找源文件。带路径的直接按路径在每份基线下找；只有文件名的全仓搜。
    found=""
    found_label=""
    found_root=""
    for i in "${!NORMALIZED_BASELINES[@]}"; do
      base="${NORMALIZED_BASELINES[$i]}"
      info="${BASEINFO_PATHS[$i]}"
      label="$(label_for "$info")"
      if [[ "$path" == *"/"* ]]; then
        c="$base/$path"
        [[ -f "$c" ]] && { found="$c"; found_label="$label"; found_root="$base"; break; }
      else
        c="$(find "$base" -name "$path" \
              -not -path "*/node_modules/*" -not -path "*/.git/*" \
              -not -path "*/dist/*" -not -path "*/build/*" 2>/dev/null | head -n 1)"
        [[ -n "$c" && -f "$c" ]] && { found="$c"; found_label="$label"; found_root="$base"; break; }
      fi
    done

    if [[ -z "$found" ]]; then
      echo "FILE-NOT-FOUND  $cite   （在 ${doc}）"
      bad=$((bad+1)); continue
    fi

    total="$(wc -l < "$found" | tr -d ' ')"
    if (( num > total )); then
      echo "OUT-OF-RANGE    $cite   （$found 共 $total 行）"
      bad=$((bad+1)); continue
    fi

    rel="${found#$found_root/}"
    content="$(sed -n "${num}p" "$found" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    preview+=$(printf '[%s] %-40s → %s\n' "$found_label" "$cite" "$content")
    preview+=$'\n'
    ok=$((ok+1))
  done <<< "$cites"
done

echo ""
echo "════════════════════════════════════════════════════════════"
# 基线信息（prepare-baseline.sh 写的）—— 校验的是哪份代码，必须说清楚。逐份打印。
for info in "${BASEINFO_PATHS[@]}"; do
  [[ -f "$info" ]] || continue
  echo "── $(label_for "$info")基线 ──"
  reused=""
  while IFS='=' read -r k v; do
    case "$k" in
      BRANCH) echo "  基线分支: $v" ;;
      COMMIT) echo "  基线提交: $v" ;;
      MODE)   echo "  基线模式: $v" ;;
      REUSED_FROM) reused="$v" ;;
    esac
  done < "$info"
  [[ -n "$reused" ]] && echo "  复用自: $reused"
done
echo "────────────────────────────────────────────────────────────"
echo "引用有效: $ok    失效: $bad"
echo "════════════════════════════════════════════════════════════"
if [[ -n "$preview" ]]; then
  echo "── 引用内容预览（人工核对语义是否对得上）──"
  printf '%s' "$preview"
fi

[[ $bad -eq 0 ]] || exit 1
