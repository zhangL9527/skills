#!/usr/bin/env bash
# req-clarify · 问题清单自洽校验器
#
# 用途：机械校验「问题清单.md」的内部一致性 —— 计数、编号、交叉引用、基线标识。
#       这类错是人眼最容易漏、读者却一眼就发现的（"说 19 条其实 18 条"、"合计 20 处但只列 18 条"），
#       一处错就足以让产品怀疑整份文档的严谨度 —— 所以必须机器过一遍，不能靠自觉。
#
# 用法: check-issue-list.sh [--baseline <基线目录>]... <问题清单.md>
#   --baseline 可重复（前后端各一个）。基线目录 = prepare-baseline.sh 产出的槽位目录
#   （<基线根>/<repo名>/<分支>-<提交>）—— 传了就额外校验：文档头部写的
#   「路径@分支@提交」必须与真实基线槽位对得上（防止凭记忆写错提交号）。
#
# 检查项：
#   1. 头部「待澄清 N 条（高 x / 中 y / 低 z）」 vs 汇总表实际
#   2. 「怎么用这份文档」段的总数 / 高中级数 / 低级数 vs 汇总表实际
#   3. 「下一步」段的两个数字 vs 汇总表实际
#   4. 版本记录最后一行的「本轮提疑点数」「剩余」 vs 汇总表实际
#   5. 汇总表 Q 编号连续、无重复、无跳号
#   6. 排查范围表：每行「需要改」处数 == 该行「对应问题」列里的 Q 条数
#   7. 排查范围表：合计行 == 各行之和（排查处数 / 需要改 / 不受影响）
#   8. 排查范围「对应问题」列引用的 Q 必须在汇总表里存在
#   9. 全文出现的 Q-xxx 引用必须能对上；REQ-xxx 引用必须能对上（文档里有 REQ 表才查）
#  10. 头部基线行必须写成 路径@分支@提交
#
# 退出码：0 = 全过；1 = 有 FAIL；2 = 用法/文件错误

set -uo pipefail

BASELINES=()
DOC=""
SEEN_DD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINES+=("${2:-}"); shift 2 ;;
    --) SEEN_DD=1; shift ;;
    *)
      if [[ $SEEN_DD -eq 1 ]]; then DOC="$1"; shift; else DOC="$1"; shift; fi
      ;;
  esac
done

if [[ -z "$DOC" ]]; then
  echo "用法: check-issue-list.sh [--baseline <基线目录>]... <问题清单.md>" >&2
  exit 2
fi
[[ -f "$DOC" ]] || { echo "错误: 文件不存在: $DOC" >&2; exit 2; }

fail=0
warn=0
ok()  { printf '  OK    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
wrn() { printf '  WARN  %s\n' "$1"; warn=$((warn + 1)); }

# 取某个 "## 标题" 段落的正文（到下一个 "## " 为止）
section() {
  awk -v s="$1" 'index($0,s)==1{f=1;next} f&&/^## /{exit} f' "$DOC"
}

digits() { printf '%s' "$1" | grep -oE '[0-9]+' | head -1; }

echo "══ 问题清单自洽校验: $DOC ══"
echo ""

# ── 汇总表事实 ────────────────────────────────────────────────────────────────
sum_rows="$(section '## 汇总表' | awk -F'|' '/^\|[[:space:]]*Q-[0-9]+[[:space:]]*\|/ {
  id=$2; lv=$4;
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",id);
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",lv);
  print id"\t"lv
}')"
total="$(printf '%s\n' "$sum_rows" | awk 'END{print NR+0}')"
n_high="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="高"' | awk 'END{print NR+0}')"
n_mid="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="中"' | awk 'END{print NR+0}')"
n_low="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="低"' | awk 'END{print NR+0}')"

if [[ "$total" -eq 0 ]]; then
  bad "汇总表里没有解析到任何 Q-xxx 行 —— 表格结构变了，先修脚本"
  echo ""
  echo "══════════════════════════════════════"
  echo "FAIL: $fail    WARN: $warn"
  echo "══════════════════════════════════════"
  exit 1
fi

# ── 1. 头部计数 ───────────────────────────────────────────────────────────────
hdr="$(grep -m1 -E '\*\*待澄清\*\*' "$DOC" || true)"
hdr_total="$(digits "$(printf '%s' "$hdr" | grep -oE '待澄清[^0-9]*[0-9]+' || true)")"
if [[ -z "$hdr_total" ]]; then
  wrn "头部没有找到「待澄清 N 条」计数"
else
  if [[ "$hdr_total" == "$total" ]]; then
    ok "头部待澄清条数 = ${total}（与汇总表一致）"
  else
    bad "头部写「待澄清 $hdr_total 条」，汇总表实际 $total 条"
  fi
fi

hdr_lv="$(printf '%s' "$hdr" | grep -oE '高[[:space:]]*[0-9]+' | head -1)"
hdr_h="$(digits "$hdr_lv")"
hdr_lv="$(printf '%s' "$hdr" | grep -oE '中[[:space:]]*[0-9]+' | head -1)"
hdr_m="$(digits "$hdr_lv")"
hdr_lv="$(printf '%s' "$hdr" | grep -oE '低[[:space:]]*[0-9]+' | head -1)"
hdr_l="$(digits "$hdr_lv")"
if [[ -n "$hdr_h$hdr_m$hdr_l" ]]; then
  if [[ "$hdr_h" == "$n_high" && "$hdr_m" == "$n_mid" && "$hdr_l" == "$n_low" ]]; then
    ok "头部级别分布 高 $n_high / 中 $n_mid / 低 ${n_low}（与汇总表一致）"
  else
    bad "头部写 高 $hdr_h / 中 $hdr_m / 低 ${hdr_l}，汇总表实际 高 $n_high / 中 $n_mid / 低 $n_low"
  fi
else
  wrn "头部没有「高 x / 中 y / 低 z」分布"
fi

# ── 2. 「怎么用这份文档」段 ──────────────────────────────────────────────────
use="$(section '## 怎么用这份文档')"
u_total="$(digits "$(printf '%s' "$use" | grep -oE '共[[:space:]]*[0-9]+[[:space:]]*条' | head -1)")"
u_mid="$(digits "$(printf '%s' "$use" | grep -oE '高/中级问题（共[[:space:]]*[0-9]+' | head -1)")"
u_low="$(digits "$(printf '%s' "$use" | grep -oE '低级别问题（[[:space:]]*[0-9]+' | head -1)")"
[[ -n "$u_total" ]] && { [[ "$u_total" == "$total" ]] && ok "「怎么用」段总数 = $total" || bad "「怎么用」段写「共 $u_total 条」，汇总表实际 $total 条"; }
[[ -n "$u_mid" ]]  && { [[ "$u_mid" == "$((n_high + n_mid))" ]] && ok "「怎么用」段高/中级共 $((n_high + n_mid)) 条" || bad "「怎么用」段写高/中级共 $u_mid 条，实际 $((n_high + n_mid)) 条"; }
[[ -n "$u_low" ]]  && { [[ "$u_low" == "$n_low" ]] && ok "「怎么用」段低级别 $n_low 条" || bad "「怎么用」段写低级别 $u_low 条，实际 $n_low 条"; }

# ── 3. 「下一步」段 ───────────────────────────────────────────────────────────
nxt="$(section '## 下一步')"
x_q="$(digits "$(printf '%s' "$nxt" | grep -oE '[0-9]+[[:space:]]*个问题' | head -1)")"
x_c="$(digits "$(printf '%s' "$nxt" | grep -oE '这[[:space:]]*[0-9]+[[:space:]]*条' | head -1)")"
[[ -n "$x_q" ]] && { [[ "$x_q" == "$total" ]] && ok "「下一步」段问题数 = $total" || bad "「下一步」段写 $x_q 个问题，汇总表实际 $total 条"; }
[[ -n "$x_c" ]] && { [[ "$x_c" == "$total" ]] && ok "「下一步」段结论条数 = $total" || bad "「下一步」段写 $x_c 条结论，汇总表实际 $total 条"; }

# ── 4. 版本记录最后一行 ───────────────────────────────────────────────────────
ver="$(section '## 版本记录' | awk -F'|' '/^\|[[:space:]]*v[0-9]+[[:space:]]*\|/ {
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$6);
  print $4"\t"$6
}' | tail -n 1)"
v_n="$(printf '%s' "$ver" | cut -f1)"
v_left="$(printf '%s' "$ver" | cut -f2)"
if [[ -n "$v_n" ]]; then
  [[ "$v_n" == "$total" ]] && ok "版本记录「本轮提疑点数」= $total" || bad "版本记录写「本轮提疑点数 ${v_n}」，汇总表实际 $total 条"
  [[ "$v_left" == "$total" ]] && ok "版本记录「剩余」= $total" || bad "版本记录写「剩余 ${v_left}」，实际应为 ${total}（v1 首版无遗留）"
fi

# ── 5. Q 编号连续性 ───────────────────────────────────────────────────────────
ids="$(printf '%s\n' "$sum_rows" | cut -f1)"
dup="$(printf '%s\n' "$ids" | sort | uniq -d | tr '\n' ' ')"
[[ -n "$dup" ]] && bad "汇总表有重复编号: $dup" || ok "汇总表无重复编号"
cont_ok=1
idx=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  idx=$((idx + 1))
  exp_id="$(printf 'Q-%03d' "$idx")"
  if [[ "$ref" != "$exp_id" ]]; then
    bad "Q 编号不连续：第 ${idx} 行是 ${ref}，应为 ${exp_id}"
    cont_ok=0
    break
  fi
done <<< "$ids"
if [[ "$cont_ok" -eq 1 ]]; then
  ok "Q 编号连续（Q-001 … Q-$(printf '%03d' "$total")）"
fi

# ── 6/7. 排查范围表 ───────────────────────────────────────────────────────────
range="$(section '## 排查范围')"
sum_need=0; sum_safe=0; sum_scan=0; row_bad=0
while IFS=$'\t' read -r dim need safe qlist; do
  [[ -z "$dim" ]] && continue
  nq="$(printf '%s' "$qlist" | grep -oE 'Q-[0-9]+' | awk 'END{print NR+0}')"
  if [[ "$nq" != "$need" ]]; then
    bad "排查范围「${dim}」写「需要改 $need 处」，但「对应问题」列只列了 $nq 条问题"
    row_bad=1
  fi
  sum_need=$((sum_need + need)); sum_safe=$((sum_safe + safe))
done < <(printf '%s' "$range" | awk -F'|' '/^\|[[:space:]]*[①-⑦]/ {
  dim=$2; need=$4; safe=$5; qlist=$6;
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",dim);
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",need);
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",safe);
  print dim"\t"need"\t"safe"\t"qlist
}')

# 排查处数（第 3 列，单独再扫一遍）
sum_scan="$(printf '%s' "$range" | awk -F'|' '/^\|[[:space:]]*[①-⑦]/ {
  v=$3; gsub(/[^0-9]/,"",v); s+=v+0
} END{print s+0}')"

[[ "$row_bad" -eq 0 ]] && ok "排查范围每行「需要改处数」== 该行「对应问题」条数"

total_row="$(printf '%s' "$range" | awk -F'|' '/^\|[[:space:]]*\*\*合计\*\*/ {
  a=$3; b=$4; c=$5;
  gsub(/[^0-9]/,"",a); gsub(/[^0-9]/,"",b); gsub(/[^0-9]/,"",c);
  print a"\t"b"\t"c
}' | tail -n 1)"
if [[ -n "$total_row" ]]; then
  t_scan="$(printf '%s' "$total_row" | cut -f1)"
  t_need="$(printf '%s' "$total_row" | cut -f2)"
  t_safe="$(printf '%s' "$total_row" | cut -f3)"
  [[ "$t_scan" == "$sum_scan" ]] && ok "排查范围合计「排查存量功能」= $sum_scan" || bad "排查范围合计写 $t_scan 处，各行相加为 $sum_scan 处"
  [[ "$t_need" == "$sum_need" ]] && ok "排查范围合计「需要改」= $sum_need" || bad "排查范围合计写「需要改 ${t_need}」，各行相加为 $sum_need"
  [[ "$t_safe" == "$sum_safe" ]] && ok "排查范围合计「确认不受影响」= $sum_safe" || bad "排查范围合计写「确认不受影响 ${t_safe}」，各行相加为 $sum_safe"
fi

# ── 7b. 免打扰清单条数 vs 合计「确认不受影响」 ────────────────────────────────
safe_rows="$(printf '%s' "$range" | awk -F'|' '/^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {n++} END{print n+0}')"
if [[ -n "${total_row}" && "$safe_rows" -gt 0 ]]; then
  [[ "$safe_rows" == "$t_safe" ]] && ok "免打扰清单 $safe_rows 条 == 合计「确认不受影响」$t_safe" \
    || bad "免打扰清单列了 $safe_rows 条，合计却写「确认不受影响 ${t_safe}」"
fi

# ── 8/9. 交叉引用 ────────────────────────────────────────────────────────────
while read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s\n' "$ids" | grep -qx "$ref" || bad "排查范围引用了不存在的 $ref"
done < <(printf '%s' "$range" | grep -oE 'Q-[0-9]+' | sort -u)

missed=""
while read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s\n' "$ids" | grep -qx "$ref" || missed="$missed $ref"
done < <(grep -oE 'Q-[0-9]+' "$DOC" | sort -u)
[[ -n "$missed" ]] && bad "全文引用了汇总表里没有的问题编号:$missed" || ok "全文 Q-xxx 引用均能对上汇总表"

if grep -qE '^\|[[:space:]]*REQ-[0-9]+' "$DOC"; then
  req_ids="$(grep -oE '^\|[[:space:]]*REQ-[0-9]+' "$DOC" | grep -oE 'REQ-[0-9]+' | sort -u)"
  badreq=""
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    printf '%s\n' "$req_ids" | grep -qx "$ref" || badreq="$badreq $ref"
  done < <(grep -oE 'REQ-[0-9]+' "$DOC" | sort -u)
  [[ -n "$badreq" ]] && bad "全文引用了未定义的 $badreq" || ok "全文 REQ-xxx 引用均能对上门店条目表"
fi

# 汇总表里每条问题都应在排查范围表出现（影响维度为「—」的除外）
uncovered=""
while read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s' "$range" | grep -q "$ref" || uncovered="$uncovered $ref"
done < <(printf '%s\n' "$ids")
[[ -n "$uncovered" ]] && wrn "这些汇总表问题未出现在排查范围表里（确认是否漏登记）:$uncovered"

# ── 10. 基线标识 ─────────────────────────────────────────────────────────────
for side in 后端 前端; do
  line="$(grep -m1 -E "\\*\\*${side}代码库\\*\\*" "$DOC" || true)"
  [[ -z "$line" ]] && continue
  if printf '%s' "$line" | grep -qE '@[^@[:space:]]+@[^@[:space:]]+'; then
    ok "${side}基线行写成 路径@分支@提交"
  elif printf '%s' "$line" | grep -qE '无（本次仅|无$'; then
    ok "${side}基线行标注为「无」"
  else
    bad "${side}基线行没写成 路径@分支@提交（必须与实际基线目录一致，不能凭记忆写）"
  fi
done

# ── 10b. 基线提交号与真实基线槽位对得上 ───────────────────────────────────────
for b in "${BASELINES[@]}"; do
  [[ -z "$b" || ! -d "$b" ]] && continue
  slot="$(basename "$(cd "$b" && pwd)")"
  commit="$(printf '%s' "$slot" | grep -oE '[0-9a-f]{7,40}$' || true)"
  branch="${slot%-${commit}}"
  [[ -z "$commit" ]] && continue
  if grep -q "@${branch}@${commit}" "$DOC"; then
    ok "文档写出的基线 ${branch}@${commit} 与真实基线槽位一致"
  else
    bad "文档头部没有出现 @${branch}@${commit} —— 基线标识与实际基线目录对不上（多半是凭记忆写的提交号）"
  fi
done

echo ""
echo "══════════════════════════════════════"
echo "FAIL: $fail    WARN: $warn"
echo "══════════════════════════════════════"
[[ $fail -eq 0 ]] || exit 1
exit 0
