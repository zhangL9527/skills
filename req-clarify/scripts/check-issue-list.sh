#!/usr/bin/env bash
# req-clarify · 问题清单自洽校验器
#
# 用途：机械校验「问题清单.md」的内部一致性 —— 计数、编号、交叉引用。
#       交付给产品的问题清单只保留问题本身（汇总表 + 每条问题），
#       排查范围、免打扰清单、版本记录、基线信息都在对话里，不进交付物 ——
#       所以本脚本只校验"问题"这一层。
#
# 用法: check-issue-list.sh <问题清单.md>
#
# 检查项：
#   1. 头部「待澄清 N 条（高 x / 中 y / 低 z）」 vs 问题汇总表实际
#   2. 「怎么用这份文档」段（可选段，缺省则跳过）的总数 / 高中级数 / 低级数 vs 汇总表实际
#   3. 「执行流程」段的两个数字 vs 汇总表实际
#   4. 汇总表 Q 编号连续、无重复、无跳号
#   5. 每条问题的正文小节标题存在且与汇总表一一对应（不多不少）
#   6. 汇总表每行都有「给产品（一句话）」与「给开发」两段
#   7. 全文出现的 Q-xxx / REQ-xxx 引用必须能对上
#
# 退出码：0 = 全过；1 = 有 FAIL；2 = 用法/文件错误

set -uo pipefail

DOC="${1:-}"
if [[ -z "$DOC" ]]; then
  echo "用法: check-issue-list.sh <问题清单.md>" >&2
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

# 抽取 Q-xxx 引用（排除 REQ-xxx 里的 "Q-" 误匹配）
qrefs() { grep -oE '(^|[^A-Za-z0-9_])Q-[0-9]+' "$1" | grep -oE 'Q-[0-9]+'; }

echo "══ 问题清单自洽校验: $DOC ══"
echo ""

# ── 交付物纯净度：分析过程类内容不该出现在产品文档里 ──────────────────────────
for junk in "排查范围" "免打扰" "版本记录" "后端代码库" "前端代码库" "方案文档"; do
  if grep -q "$junk" "$DOC"; then
    bad "文档里出现了「${junk}」—— 这是分析过程/取证信息，不该出现在给产品的问题清单里"
  fi
done
if grep -qE '^\*\*版本\*\*|^\*\*方案文档\*\*' "$DOC"; then
  bad "文档头部还有「版本 / 方案文档 / 代码库」字段行 —— 交付物只保留问题本身"
fi

# ── 问题汇总表事实 ────────────────────────────────────────────────────────────
sum_rows="$(section '## 问题汇总' | awk -F'|' '/^\|[[:space:]]*Q-[0-9]+[[:space:]]*\|/ {
  id=$2; lv=$3;
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",id);
  gsub(/^[[:space:]]+|[[:space:]]+$/,"",lv);
  print id"\t"lv
}')"
total="$(printf '%s\n' "$sum_rows" | awk 'END{print NR+0}')"
n_high="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="高"' | awk 'END{print NR+0}')"
n_mid="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="中"' | awk 'END{print NR+0}')"
n_low="$(printf '%s\n' "$sum_rows" | awk -F'\t' '$2=="低"' | awk 'END{print NR+0}')"

if [[ "$total" -eq 0 ]]; then
  bad "「问题汇总」表里没有解析到任何 Q-xxx 行 —— 表格结构变了，先修脚本"
  echo ""
  echo "══════════════════════════════════════"
  echo "FAIL: $fail    WARN: $warn"
  echo "══════════════════════════════════════"
  exit 1
fi

ids="$(printf '%s\n' "$sum_rows" | cut -f1)"

# ── 1. 头部计数 ───────────────────────────────────────────────────────────────
hdr="$(grep -m1 -E '\*\*待澄清\*\*' "$DOC" || true)"
hdr_total="$(digits "$(printf '%s' "$hdr" | grep -oE '待澄清[^0-9]*[0-9]+' || true)")"
if [[ -z "$hdr_total" ]]; then
  wrn "头部没有找到「待澄清 N 条」计数"
else
  [[ "$hdr_total" == "$total" ]] && ok "头部待澄清条数 = ${total}（与问题汇总一致）" \
    || bad "头部写「待澄清 $hdr_total 条」，问题汇总实际 $total 条"
fi

hdr_h="$(digits "$(printf '%s' "$hdr" | grep -oE '高[[:space:]]*[0-9]+' | head -1)")"
hdr_m="$(digits "$(printf '%s' "$hdr" | grep -oE '中[[:space:]]*[0-9]+' | head -1)")"
hdr_l="$(digits "$(printf '%s' "$hdr" | grep -oE '低[[:space:]]*[0-9]+' | head -1)")"
if [[ -n "$hdr_h$hdr_m$hdr_l" ]]; then
  if [[ "$hdr_h" == "$n_high" && "$hdr_m" == "$n_mid" && "$hdr_l" == "$n_low" ]]; then
    ok "头部级别分布 高 $n_high / 中 $n_mid / 低 ${n_low}（与问题汇总一致）"
  else
    bad "头部写 高 $hdr_h / 中 $hdr_m / 低 ${hdr_l}，问题汇总实际 高 $n_high / 中 $n_mid / 低 $n_low"
  fi
else
  wrn "头部没有「高 x / 中 y / 低 z」分布"
fi

# ── 2. 「怎么用这份文档」段 ──────────────────────────────────────────────────
use="$(section '## 怎么用这份文档')"
u_total="$(digits "$(printf '%s' "$use" | grep -oE '共[[:space:]]*[0-9]+[[:space:]]*条' | head -1)")"
u_mid="$(digits "$(printf '%s' "$use" | grep -oE '高/中级问题（共[[:space:]]*[0-9]+' | head -1)")"
u_low="$(digits "$(printf '%s' "$use" | grep -oE '低级别问题（[[:space:]]*[0-9]+' | head -1)")"
[[ -n "$u_total" ]] && { [[ "$u_total" == "$total" ]] && ok "「怎么用」段总数 = $total" || bad "「怎么用」段写「共 $u_total 条」，问题汇总实际 $total 条"; }
[[ -n "$u_mid" ]]  && { [[ "$u_mid" == "$((n_high + n_mid))" ]] && ok "「怎么用」段高/中级共 $((n_high + n_mid)) 条" || bad "「怎么用」段写高/中级共 $u_mid 条，实际 $((n_high + n_mid)) 条"; }
[[ -n "$u_low" ]]  && { [[ "$u_low" == "$n_low" ]] && ok "「怎么用」段低级别 $n_low 条" || bad "「怎么用」段写低级别 $u_low 条，实际 $n_low 条"; }

# ── 3. 「执行流程」段 ───────────────────────────────────────────────────────────
nxt="$(section '## 执行流程')"
x_q="$(digits "$(printf '%s' "$nxt" | grep -oE '[0-9]+[[:space:]]*个问题' | head -1)")"
x_c="$(digits "$(printf '%s' "$nxt" | grep -oE '这[[:space:]]*[0-9]+[[:space:]]*条' | head -1)")"
[[ -n "$x_q" ]] && { [[ "$x_q" == "$total" ]] && ok "「执行流程」段问题数 = $total" || bad "「执行流程」段写 $x_q 个问题，问题汇总实际 $total 条"; }
[[ -n "$x_c" ]] && { [[ "$x_c" == "$total" ]] && ok "「执行流程」段结论条数 = $total" || bad "「执行流程」段写 $x_c 条结论，问题汇总实际 $total 条"; }

# ── 4. Q 编号连续性 ───────────────────────────────────────────────────────────
dup="$(printf '%s\n' "$ids" | sort | uniq -d | tr '\n' ' ')"
[[ -n "$dup" ]] && bad "问题汇总有重复编号: $dup" || ok "问题汇总无重复编号"

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
[[ "$cont_ok" -eq 1 ]] && ok "Q 编号连续（Q-001 … Q-$(printf '%03d' "$total")）"

# ── 5. 正文小节与汇总表一一对应 ───────────────────────────────────────────────
body_ids="$(grep -oE '^### Q-[0-9]+' "$DOC" | grep -oE 'Q-[0-9]+' | sort -u)"
missing=""
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s\n' "$body_ids" | grep -qx "$ref" || missing="$missing $ref"
done <<< "$ids"
[[ -n "$missing" ]] && bad "汇总表里这些问题没有对应的正文小节:$missing" || ok "汇总表每条问题都有正文小节"

extra=""
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s\n' "$ids" | grep -qx "$ref" || extra="$extra $ref"
done <<< "$body_ids"
[[ -n "$extra" ]] && bad "正文里这些问题没进汇总表:$extra" || ok "正文小节与汇总表一一对应"

# ── 6. 每条问题都有「给产品」与「给开发」两段 ─────────────────────────────────
n_gp="$(grep -c '^\*\*给产品（一句话）\*\*' "$DOC")"
n_gd="$(grep -c '^\*\*给开发（证据与选项）\*\*' "$DOC" || true)"
[[ "$n_gp" == "$total" ]] && ok "每条问题都有「给产品（一句话）」段" || bad "「给产品（一句话）」段有 $n_gp 个，应为 $total 个"
[[ "$n_gd" == "$total" ]] && ok "每条问题都有「给开发」段" || bad "「给开发」段有 $n_gd 个，应为 $total 个"

# ── 7. 交叉引用 ───────────────────────────────────────────────────────────────
missed=""
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  printf '%s\n' "$ids" | grep -qx "$ref" || missed="$missed $ref"
done < <(qrefs "$DOC" | sort -u)
[[ -n "$missed" ]] && bad "全文引用了汇总表里没有的问题编号:$missed" || ok "全文 Q-xxx 引用均能对上问题汇总"

if grep -qE '^\|[[:space:]]*REQ-[0-9]+' "$DOC"; then
  req_ids="$(grep -oE '^\|[[:space:]]*REQ-[0-9]+' "$DOC" | grep -oE 'REQ-[0-9]+' | sort -u)"
  badreq=""
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    printf '%s\n' "$req_ids" | grep -qx "$ref" || badreq="$badreq $ref"
  done < <(grep -oE 'REQ-[0-9]+' "$DOC" | sort -u)
  [[ -n "$badreq" ]] && bad "全文引用了未定义的 $badreq" || ok "全文 REQ-xxx 引用均能对上门店条目表"
fi

echo ""
echo "══════════════════════════════════════"
echo "FAIL: $fail    WARN: $warn"
echo "══════════════════════════════════════"
[[ $fail -eq 0 ]] || exit 1
exit 0
