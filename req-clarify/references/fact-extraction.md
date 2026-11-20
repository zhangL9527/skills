# 代码事实抽取方法

目标：从代码库中抽出**可验证的现状事实**，每条带 `file:line`。事实要**全集**，不要抽样 —— 抽样是遗漏类缺陷漏检的头号原因。

> **取证位置**：所有代码读取都指向 **Stage 0 锁定的基线目录**（`master` / `main` 的只读导出），**不是工作区**。
> 工作区可能停在 feature 分支或半成品状态 —— 抽出来的是开发中间态，"现状"本身就是假的。
> `file:line` 一律相对基线目录。

## 通用原则

1. **先定作用域，再抽事实。** 作用域 = 本次需求改动的页面/模块/接口/服务，由方案条目圈定。作用域外的事实抽到也不上报。
2. **沿"调用链"抽，不要沿"目录"抽。** 从方案提到的入口出发，顺着调用链往下走；走到"共享的查询/写入入口"时**停下来横向展开** —— 共享入口是遗漏的高发区。
3. **抽"行为"不抽"名字"。** 名字会骗人（老代码里 `getXxx` 可能是删操作）。以实际读写了什么为准。
4. **每条事实必须能被单点验证。** "这里有五个按钮共用一个查询"要能指到具体行。

---

## 1. 入口事实（Entry Points）

**是什么**：用户能触达的所有操作入口 —— 页面按钮、菜单项、Tab、API 端点、消息入口。

**抽什么**：
| 维度 | 内容 |
|---|---|
| 入口标识 | 按钮文案 / 路由 / 接口路径 |
| 触发动作 | 实际做了什么（查询/写入/跳转/导出） |
| 权限点 | 权限码、角色限制 |
| **共享查询入口** | 该入口最终落到哪个 service/mapper/查询构造器 |

**检索模式**：
```
# 前端按钮
grep -rnE "onClick|<Button|<button|onPress" --include=*.{tsx,jsx,vue,html}
grep -rnE "btn_|button_|Button\b" --include=*.{tsx,jsx,vue}
# 权限码
grep -rnE "permission|permCode|hasPermission|can[A-Z]|authority" 
# 后端入口
grep -rnE "@(Get|Post|Put|Delete|Patch|Request)Mapping|app\.(get|post)|router\.(get|post)" 
grep -rnE "@(RestController|Controller)|@(Query|Mutation)Mutation|def (list|get|query)"
```

**常见坑**：
- **同族入口只登记了"新增的那个"，老的一个都没登记** —— 正是本流程要抓的缺陷类型。抽的时候以**页面为单位全量枚举**，不要以方案提到的按钮为单位。
- 按钮在配置/路由表里注册，前端是动态渲染的 —— 从配置表读，别只找 JSX。
- 同一个按钮文案在不同页面重复 —— 用 (页面, 按钮) 复合键标识。
- 批量操作、导入导出这类容易被忽略的入口。

---

## 2. 类型事实（Type / Enum）

**是什么**：业务类型的**全部取值**，以及**每个取值触发的差异化分支**。

**抽什么**：
```
类型名 / 取值集合（全集）
  └─ 每个取值在代码里被差异化处理的位置（switch / if 分支 / 策略类 / 映射表）
```

**检索模式**：
```
grep -rnE "enum [A-Za-z]+|const [A-Z_]+ *= *\[|Type\(|Interface" --include=*.{ts,java,kt,go,py}
grep -rnE "switch *\(.*(type|Type|kind|category|status|category)\)" -A 20
grep -rnE "if *\(.*(type|Type|kind|category) *(==|===|!=|!==)"
grep -rnE "Type\.[A-Z_]+|Type\.get\(" 
```

**关键动作 —— 逐取值追分支**：拿到枚举后，**对每个取值**问"这个值在哪些地方被单独判断？那里做什么？" 这张表就是"新增一个类型需要改哪些地方"的完整答案。

**常见坑**：
- **只抽枚举定义，不抽分支** —— 定义只是名字，分支才是行为。新增类型真正的影响面在分支里。
- 枚举值在前端、DB、后端各存一份，**三方命名可能不一致**（`TYPE_A` / `typeA` / `1`）。这种不一致本身是要澄清的。
- 用 `Map<Enum, Handler>` / 策略模式实现的，分支藏在注册表里。
- 隐式类型：数字魔法值、`"1"` 字符串约定，没有 enum 定义。

---

## 3. 字段事实（Field / Attribute）

**是什么**：涉及对象的**完整字段集**，以及每个字段的**所有写入路径**。

**抽什么**：
```
对象 / 表 → 完整字段清单（来自 DDL、Entity、Schema、迁移文件，不是从接口返回推断）
  └─ 每个字段的写入点：setter / builder / 对象字面量 / UPDATE 语句
  └─ 每个字段的读取点（是否影响展示、筛选、排序 —— 影响新类型下的取值）
```

**检索模式**：
```
# 表结构与迁移
find . -name "*.sql" -o -name "*schema*" -o -name "*migration*" -o -name "*.prisma" -o -name "*entity*"
grep -rnE "CREATE TABLE|ALTER TABLE|ADD COLUMN" --include=*.sql
# 字段写入点
grep -rnE "\.set[A-Z][A-Za-z]*\(|setattr\(|builder\.[a-z][A-Za-z]*\(|\.update\(\{"
grep -rnE "UPDATE .* SET|INSERT INTO"
# 模型定义
grep -rnE "class [A-Z][A-Za-z]+ *\{|@Column|@TableField|Column\(|z\.object\(|interface [A-Z]"
```

**关键动作 —— 写入路径穷举**：对每个字段，列出所有写它的地方。新增类型时，**每个写入路径可能都需要区别赋值**（新增时赋值 / 编辑时可改 / 流程流转时置位 / 批量任务时补默认值）。少一条写入路径就是一次"字段没给全"。

**常见坑**：
- **DTO / VO 与 Entity 字段不一致** —— 接口层少字段，DB 多字段，方案说的是哪一层？澄清时必须问清落库层。
- 字段有"多个来源"（前端传 / 后端算 / 定时任务补）—— 新类型下谁说了算。
- 隐式字段：创建人、租户 ID、乐观锁版本号、软删除标记 —— 新类型下是否同样写入。
- 枚举型字段的**默认值**：新增类型时该字段取哪个枚举值，方案常常漏。

---

## 4. 流程事实（Flow / State Machine）

**是什么**：状态集合 + 流转边 + 每条边的守卫条件、执行者、副作用。

**抽什么**：
```
状态集合（全集）
  └─ 流转边：from → to，触发条件，守卫条件，执行动作/副作用
```

**检索模式**：
```
grep -rnE "status|state|phase|stage|step" --include=*.{ts,java,kt,go,py}
grep -rnE "transition|flow|workflow|stateMachine|canTransition|nextState"
grep -rnE "approve|reject|submit|confirm|cancel|close|rollback" 
grep -rnE "STATUS_|_STATUS\b|Status\.[A-Z]+"
```

**关键动作 —— 画出现状图**：用 Mermaid 或节点表把**现状流程**画出来，再和方案描述的流程逐节点比对。这一步是抓"流程遗漏"的唯一可靠方式 —— 遗漏的节点在代码里是**存在**的，只要把现状图画全就能看见。

**常见坑**：
- 流程分支藏在 `if` 里而不是状态枚举里 —— 同样要抽。
- **"静默节点"**：不改变状态但有业务含义的动作（发通知、生成对账单、锁定库存）。方案经常只描述状态流转，漏掉这些中间动作。**这是最常见的流程遗漏形态。**
- 异常/超时分支、回退（rollback）路径 —— 方案基本不写，但要问。
- 状态机的**入口不止一个**（自动流转 vs 人工触发）。

---

## 5. 约束事实（Constraint）

**是什么**：校验规则、默认值、权限、幂等与并发约束。

**检索模式**：
```
grep -rnE "validate|Validator|@NotNull|@NotEmpty|@Assert|check[A-Z]|assert|guard"
grep -rnE "required|min|max|regex|pattern|unique"
grep -rnE "default|DEFAULT|DEFAULT_VALUE"
grep -rnE "idempoten|lock|version|optimistic|forUpdate"
```

**常见坑**：约束常常在前端和后端**各写一遍**，方案改了一处漏了另一处。

---

## 6. 副作用事实（Side Effect）

**是什么**：动作触发后除主数据之外还会发生什么。

**抽什么**：
```
发消息（MQ/邮件/短信/推送）、写日志/流水、建任务/工单、调第三方 API、
写快照/冗余表、更新统计计数、触发缓存失效、生成对账文件
```

**检索模式**：
```
grep -rnE "publish|emit|send|notify|mq|kafka|rabbit|producer|dispatch"
grep -rnE "@EventListener|@Subscribe|on\(|addListener"
grep -rnE "createTask|insertTask|job|schedule|cron"
grep -rnE "axios|fetch\(|httpClient|requests\.|RestTemplate|WebClient" 
```

**常见坑**：副作用是**跨系统**的，新类型通常需要不同的副作用策略，而方案几乎从不提。副作用也是排查"数据不对"的主要来源。

---

## 记录格式

每条事实写成可单点验证的一行：

```markdown
### F-ENTRY-003
- **类型**：入口事实
- **标识**：「导出」按钮（`订单列表页`）
- **行为**：导出当前筛选结果为 Excel
- **权限点**：`order:export`
- **证据**：`src/pages/OrderList.tsx:142`、`src/api/order.ts:31`
- **共享查询入口**：`src/service/orderService.ts:88` → `queryOrders()`
- **备注**：与 F-ENTRY-001~005 共用同一查询入口，未按 type 区分
```

**"共享查询入口"和"备注"这两栏是抓遗漏的关键** —— 它们记录了"哪些入口被同一条老逻辑牵连"，新增类型时这些正是要逐个确认的。
