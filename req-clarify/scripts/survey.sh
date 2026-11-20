#!/usr/bin/env bash
# req-clarify · 代码库侦察脚本
#
# 用途：机械定位六类代码事实的候选位置（file:line），供 AI 做语义判定。
#       脚本只负责「找到在哪」，不负责「是不是缺陷」。
#
# 用法: survey.sh <基线目录> [输出文件] [--label <后端|前端>]
#   基线目录：prepare-baseline.sh 产出的基线树（<迭代夹>/.baseline-backend 或 .baseline-frontend
#             下的 tree-<分支>-<提交>）—— 不要直接指向工作区，否则会读到非 master/main 的代码。
#   输出文件省略时打印到 stdout
#   --label：报告标题前缀（如「后端」「前端」），双仓各跑一次时便于区分两份输出。
#
# 注意：输出是「线索雷达」，不是「事实清单」。必须逐条打开文件确认后才能写进
#       01-代码事实基线.md。

set -uo pipefail

REPO="${1:-}"
LABEL=""
if [[ -z "$REPO" ]]; then
  echo "用法: survey.sh <repo路径> [输出文件] [--label <后端|前端>]" >&2
  exit 1
fi
shift
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    *) [[ -z "$OUT" ]] && OUT="$1"; shift ;;
  esac
done
[[ -n "$LABEL" ]] && LABEL="$LABEL · "
if [[ ! -d "$REPO" ]]; then
  echo "错误: 目录不存在: $REPO" >&2
  exit 1
fi
REPO="$(cd "$REPO" && pwd)"

CONTENT=""

# ---------- 搜索引擎选择：git repo 用 git grep（尊重 .gitignore），否则用 grep ----------
IS_GIT=0
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT=1
fi

EXTS=(ts tsx js jsx vue java kt kts go py rb php cs sql xml yaml yml json prisma graphql)
INCLUDE_ARGS=()
for e in "${EXTS[@]}"; do INCLUDE_ARGS+=(--include="*.$e"); done
EXCLUDE_ARGS=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build
              --exclude-dir=target --exclude-dir=vendor --exclude-dir=.next --exclude-dir=coverage
              --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv
              --exclude-dir=out --exclude-dir=bin --exclude-dir=obj)

# find 用的排除目录（find 不认 --exclude-dir，必须用 -type d -prune）
FIND_PRUNE=(node_modules .git dist build target vendor .next coverage __pycache__ .venv venv bin obj)

# 构造 find 的 -name 表达式
FIND_EXPR=""
for d in "${FIND_PRUNE[@]}"; do
  if [[ -n "$FIND_EXPR" ]]; then FIND_EXPR="${FIND_EXPR} -o"; fi
  FIND_EXPR="${FIND_EXPR} -name ${d}"
done

# 列出仓库内所有文件（跳过构建产物目录）
find_files() {
  find "$REPO" -type d \( $FIND_EXPR \) -prune -o -type f -print 2>/dev/null
}

# search <标题> <ERE 正则> [每节最多行数]
search() {
  local title="$1" pat="$2" limit="${3:-120}"
  CONTENT+=$'\n'"════════════════════════════════════════════════════════════"$'\n'
  CONTENT+="【${title}】  pattern: ${pat}"$'\n'
  CONTENT+="════════════════════════════════════════════════════════════"$'\n'

  local hits
  if [[ $IS_GIT -eq 1 ]]; then
    local pathspec=()
    for e in "${EXTS[@]}"; do pathspec+=("*.$e"); done
    hits="$(git -C "$REPO" grep -n -I -E -e "$pat" -- "${pathspec[@]}" 2>/dev/null | head -n "$limit")"
  else
    hits="$(grep -rnE "${INCLUDE_ARGS[@]}" "${EXCLUDE_ARGS[@]}" -e "$pat" "$REPO" 2>/dev/null \
            | sed "s|^$REPO/||" | head -n "$limit")"
  fi

  if [[ -z "$hits" ]]; then
    CONTENT+="  (无命中)"$'\n'
  else
    CONTENT+="$hits"$'\n'
    local n; n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    CONTENT+="  … 共显示 ${n} 行（上限 ${limit}，若接近上限请用更精确的 pattern 复查）"$'\n'
  fi
}

# ---------- 文件清单 ----------
CONTENT+="════════════════════════════════════════════════════════════"$'\n'
CONTENT+="【0】${LABEL}仓库概况"$'\n'
CONTENT+="════════════════════════════════════════════════════════════"$'\n'
CONTENT+="路径: $REPO"$'\n'
if [[ $IS_GIT -eq 1 ]]; then
  CONTENT+="Git:  $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"$'\n'
  CONTENT+="分支: $(git -C "$REPO" branch --show-current 2>/dev/null)"$'\n'
  CONTENT+="跟踪文件数: $(git -C "$REPO" ls-files 2>/dev/null | wc -l | tr -d ' ')"$'\n'
else
  CONTENT+="Git:  非 git 仓库"$'\n'
  CONTENT+="文件数: $(find_files | wc -l | tr -d ' ')"$'\n'
fi

# ---------- 基线信息（prepare-baseline.sh 写的） ----------
BASEINFO="$(dirname "$REPO")/.baseline-info"
if [[ -f "$BASEINFO" ]]; then
  CONTENT+="—— 基线 ——"$'\n'
  while IFS='=' read -r k v; do
    case "$k" in
      BRANCH)   CONTENT+="基线分支: $v"$'\n' ;;
      COMMIT)   CONTENT+="基线提交: $v"$'\n' ;;
      MODE)     CONTENT+="基线模式: $v"$'\n' ;;
    esac
  done < "$BASEINFO"
fi
CONTENT+=""$'\n'
CONTENT+="— 表结构 / 迁移 / 模型定义文件（字段事实的基线）—"$'\n'

if [[ $IS_GIT -eq 1 ]]; then
  CONTENT+="$(git -C "$REPO" ls-files 2>/dev/null \
    | grep -iE '(schema|migration|migrate|\.sql$|entity|model|domain|prisma|dto|vo)\.' \
    | grep -viE '(node_modules|\.min\.|\.lock$)' | head -60)"$'\n'
else
  CONTENT+="$(find "$REPO" -type d \( $FIND_EXPR \) -prune -o \
    -type f \( -iname '*schema*' -o -iname '*migration*' -o -iname '*.sql' -o -iname '*entity*' -o -iname '*model*' -o -iname '*prisma*' \) \
    -print 2>/dev/null | sed "s|^$REPO/||" | head -60)"$'\n'
fi

# ---------- 一、入口事实 ----------
search "1.1 前端按钮 / 交互入口" \
  '(<Button|<button|onClick=|onPress=|handle[A-Z][A-Za-z]*\(|@(click|tap)|el-button|a-button|TextButton)' 120
search "1.2 权限码 / 角色判定" \
  '(permission|PermCode|hasPermission|can[A-Z][A-Za-z]+\(|authority|roleCode|@RequiresPermissions|@PreAuthorize|isAdmin)' 80
search "1.3 后端接口入口" \
  '(@(Get|Post|Put|Delete|Patch|Request)Mapping|@(RestController|Controller)|app\.(get|post|put|delete)\(|router\.(get|post|put|delete)\(|@(Query|Mutation)Mutation|@app\.route)' 120
search "1.4 共享查询 / 写入入口（service / mapper / repository 方法定义）★遗漏高发区" \
  '(function |const |async |public |private |def )(query|list|get|find|search|save|create|update|insert|add|delete)[A-Z][A-Za-z]*[ ]*[(]' 120

# ---------- 二、类型事实 ----------
search "2.1 枚举 / 常量集合定义" \
  '(enum [A-Za-z_]+|(export )?const [A-Z_]{3,} *= *\[|(export )?type [A-Za-z_]+ *= *[^=]|public enum |val [A-Z_]+ *= *enum)' 80
search "2.2 类型差异化分支（新增类型必须逐个表态）★最高价值" \
  '(switch *\(.*(type|Type|kind|category|status|Kind|Category)|if *\(.*(type|Type|kind|category|Kind|Category) *(==|===|!=|!==)|(type|Type) *== *[A-Z_]+)' 150
search "2.3 类型映射表 / 策略注册" \
  '(Map<|Record<|switchMap|\.set\(|\.put\(.*(Type|type)|handlers\[|registry\[|strategy\[)' 80

# ---------- 三、字段事实 ----------
search "3.1 字段写入点（setter / builder / 字面量 / UPDATE）★字段缺口判定依据" \
  '(\.set[A-Z][A-Za-z]*\(|setattr\(|builder\.[a-z][A-Za-z]*\(|\.update\(\{|UPDATE [a-z_]+ SET|INSERT INTO)' 150
search "3.2 模型 / 实体字段定义" \
  '(class [A-Z][A-Za-z_]+ *\{|@Column|@TableField|@TableName|Column\(|z\.object\(|interface [A-Z][A-Za-z_]+ *\{|CREATE TABLE)' 100
search "3.3 字段默认值 / 约束" \
  '(default|DEFAULT|notNull|not null|NOT NULL|@NotNull|@NotEmpty|@Min|@Max|unique|UNIQUE)' 100

# ---------- 四、流程事实 ----------
search "4.1 状态定义 / 状态枚举" \
  '(Status|STATE|_STATUS|status *[:=]|state *[:=]|phase *[:=]|stage *[:=])' 120
search "4.2 流转 / 审批 / 状态变更" \
  '(transition|stateMachine|workflow|approve|reject|submit|confirm|cancel|rollback|nextState|canTransition)' 120
search "4.3 静默节点线索（不改状态但调用副作用的分支）★最常见流程遗漏" \
  '(if *\(.*status *(==|===|!=|!==)|else if *\(.*status|updateStatus|setStatus|changeStatus)' 100
search "4.4 静默节点强线索：副作用函数调用点（与 4.3 配对，逐个确认该调用前后 status 是否改变）" \
  '(generate|send|publish|notify|create|insert|update|write|push|sync|report|post)[A-Z][A-Za-z]*[ ]*[(]' 100

# ---------- 五、约束事实 ----------
search "5.1 校验规则" \
  '(validate|Validator|@Valid|@Validated|assert|check[A-Z][A-Za-z]*\(|required|regexp|must |should )' 100
search "5.2 幂等 / 并发 / 锁" \
  '(idempoten|optimistic|version|forUpdate|selectForUpdate|lock|Lock|distributed)' 80

# ---------- 六、副作用事实 ----------
search "6.1 消息 / 事件" \
  '(publish|emit|send|notify|producer|dispatch|kafka|rabbit|mq\.|@EventListener|@Subscribe|onMessage)' 100
search "6.2 定时任务 / 异步" \
  '(schedule|cron|@Scheduled|@Async|setInterval|setTimeout|Task|job|Job|worker)' 100
search "6.3 外部调用" \
  '(axios|fetch\(|httpClient|requests\.|RestTemplate|WebClient|HttpClient|okhttp|gaxios)' 100
search "6.4 流水 / 快照 / 统计" \
  '(log|Log|history|snapshot|Snapshot|stat|Stat|counter|Counter|record)' 80

# ---------- 收尾 ----------
CONTENT+=""$'\n'
CONTENT+="════════════════════════════════════════════════════════════"$'\n'
CONTENT+="【Z】下一步"$'\n'
CONTENT+="════════════════════════════════════════════════════════════"$'\n'
CONTENT+="1. 本文件只是「线索」，不是「事实」。必须逐条打开文件确认行为后才能写入事实基线。"$'\n'
CONTENT+="2. 重点追三条线："$'\n'
CONTENT+="   a) 1.4 的共享查询/写入入口 —— 新增类型后哪些老入口会被牵连"$'\n'
CONTENT+="   b) 2.2 的类型差异化分支 —— 每个分支都要对新类型表态"$'\n'
CONTENT+="   c) 4.3 的静默节点 —— 状态不变但有副作用的分支，最常被方案漏掉"$'\n'
CONTENT+="3. 抽取时要求「全集」：枚举值全列、字段全列、入口全列、流程节点全列。"$'\n'
CONTENT+="4. 把确认后的事实写入 01-代码事实基线.md（每条带 file:line）。"$'\n'

if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
  printf '%s' "$CONTENT" > "$OUT"
  echo "已写入: $OUT"
  echo "提示: 这是线索雷达，逐条打开确认后再写入事实基线。"
else
  printf '%s' "$CONTENT"
fi
