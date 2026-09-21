# Todo 功能设计方案

> 状态：**设计提案（未实现）**。本文档是 pi.nvim todo 功能的完整设计，参考 subagent
> 模块（`extensions/subagent.ts` + `lua/pi/subsessions/`）的分层架构。
>
> 关联调研：市面 agent todo 功能调研 + pi 后端能力调研（2026-06，见 §2）。

---

## 1 · 背景：todo 功能解决什么问题

对主流 agent（Claude Code、OpenAI Codex、opencode、Cline/Roo Code、Cursor、goose）
的调研表明，todo 功能的本质是**两件事**，缺一不可：

1. **给模型看的 —— 对抗长任务"漂移"（核心价值）。** Anthropic 官方工程博客
   《Effective context engineering for AI agents》将 todo list 归为 "agentic
   memory"（结构化记笔记）：长任务中上下文被大量工具结果填满，早期指令影响力
   衰减（context rot），agent 会忘步骤、重复劳动、跑偏。todo 把计划**外化为
   结构化状态**，并在压缩（compaction）后仍能存活，让模型可以自我监控进度。
2. **给用户看的 —— 可观察性与可预期性。** Claude Code 工具描述原文：todo
   "向用户展示做事的全面性，帮助用户理解任务进度"；Cursor 1.2 changelog：
   "使长程任务更易理解和追踪"。

## 2 · 现状

### 2.1 其他工具如何实现（调研结论）

实现方式高度收敛，共性如下：

| 维度 | 收敛做法 | 代表 |
|---|---|---|
| 形态 | **LLM 调用的工具**，不是纯 UI 构造 | Claude Code `TodoWrite`、Codex `update_plan`、opencode `todowrite`、Cline `update_todo_list` |
| schema | 每项 `content` + `status`（pending / in_progress / completed）；Claude Code 额外有 `activeForm`（进行时文案，供 spinner 显示）；opencode 额外有 `priority`、`id` | Claude Code / Codex / opencode 为 JSON 数组；Cline/Roo 为 markdown 勾选框字符串 |
| 写入语义 | **全量替换**：每次调用提交完整清单，不做增量 patch | 全部 |
| 状态纪律 | 任何时刻**恰好一个 in_progress**；完成立即标记，不攒批 | Claude Code / Codex prompt 明确规定 |
| 上下文注入 | 静态纪律写进系统提示 + **低频提醒**（N 轮未更新时注入 reminder，谓词触发而非每轮）+ 工具结果固定回注 | Claude Code 的 "gentle reminder" system-reminder；Cline 的 `remindClineInterval` 强提醒 |
| UI 渲染 | 终端 spinner 行 / 聊天内嵌组件 / 专用面板；in_progress 项高亮 | Claude Code 显示 `activeForm`；Cline 顶栏进度百分比 |
| 持久化 | 状态随会话存取，压缩后存活 | opencode 存会话 DB；goose "每一轮都展示、压缩后依然存在" |

已知坑：模型对工具的调用意愿不一（Cursor 需在 prompt 里显式要求才稳定触发）；
提醒过于频繁会污染上下文（各家用谓词触发而非每轮注入）。

### 2.2 pi 后端现状

- **pi 内核没有内置 todo 工具，也没有任何 todo 专属 RPC 事件**（`docs/rpc.md`
  全文零命中）。官方仅提供示例扩展 `examples/extensions/todo.ts`：
  `registerTool` 注册单工具 `todo`（action: list/add/toggle/clear），状态存
  tool result 的 `details` 字段（`{action, todos[], nextId}`），通过监听
  `session_start` / `session_tree` 扫描分支中的 toolResult 重建状态——
  因此分支切换后状态自动正确。
- 通用事件链路完备：`tool_execution_start/update/end` 会携带工具名、参数和
  `result.details` 下发到 RPC 客户端。
- 扩展侧上下文注入能力完备：`before_agent_start`（可改系统提示、注入持久
  message）、`context`（每次 LLM 调用前**非破坏性**修改消息，深拷贝、不落盘）。
- `setWidget`（`extension_ui_request`）是持久面板的官方通道，RPC 模式下传
  字符串数组。

### 2.3 pi.nvim 现状

- 无任何 todo 相关代码；但 subagent 模块提供了完整可复用的架构范本：
  - `extensions/subagent.ts`：`registerTool` + `promptSnippet`（让工具出现在
    系统提示的 Available tools 段）+ `before_agent_start` 注入**字节恒定**的
    纪律文本（ORCHESTRATOR_NOTE，保护 prompt-cache 前缀）；
  - `lua/pi/cli.lua`：进程启动时按配置注入 bundled extension；
  - `lua/pi/subsessions/tool_ui.lua`：工具标签、本地化、`result_details()`
    安全解析；
  - `lua/pi/ui/chat/tools.lua`：`renderers` 表按工具名派发专属渲染；
  - 事件路由（manager.lua）与回放路径（replay 同样携带 `details`）已存在，
    新工具零改动可用。
- `Config.options` 有按功能分区的配置先例（`subagent = {...}`）。

## 3 · 目标与非目标

### 目标

1. 会话内的 LLM 驱动 todo：模型可在复杂任务中建立、推进、核销任务清单，
   长任务与压缩后不丢失进度。
2. 用户可观察：chat 历史中的 todo 工具块渲染为三态清单（✓/◐/○），
   in_progress 项醒目；提供**持久视图**随时查看当前进度。
3. 上下文管理健壮：静态纪律 + 谓词触发的动态提醒 + 每次调用全量状态，
   且不破坏 prompt-cache 前缀、不污染会话历史。
4. 架构与 subagent 模块同构：TS 扩展负责 agent 侧，Lua 负责渲染与用户侧，
   职责边界清晰。

### 非目标

- 不做跨会话/跨项目的持久 todo 存储（那是任务管理系统，不是 agentic memory）。
- 不做 todo 项之间的依赖图（blocks/blockedBy）——Claude Code v2 的 Task 工具
  才引入依赖，复杂度收益不成比例，留作后续演进。
- 不在 Lua 侧实现任何工具逻辑（工具必须注册在 agent 进程内才能进入 LLM
  上下文）。

## 4 · 整体架构

```
┌─ pi 进程（agent 侧）────────────────────────────────────┐
│ extensions/todo.ts                                      │
│  ├─ registerTool("todo_write")   全量替换写清单           │
│  ├─ before_agent_start           注入字节恒定纪律文本      │
│  ├─ context                      谓词触发的动态状态注入    │
│  │                              （提醒 + 当前清单，非落盘）│
│  ├─ session_start/session_tree   从分支 toolResult 重建   │
│  └─ appendEntry                  压缩存活的检查点          │
└──────────────┬──────────────────────────────────────────┘
               │ 通用 RPC 事件（无需新增事件类型）
               │ tool_execution_start/end（携带 details）
┌──────────────┴──────────────────────────────────────────┐
│ pi.nvim（Lua 侧）                                        │
│  ├─ lua/pi/todo/init.lua       状态镜像 + 侧栏面板        │
│  │                              （与 PiSessions 上下堆叠）│
│  ├─ lua/pi/todo/tool_ui.lua    标签/本地化/details 解析   │
│  ├─ lua/pi/ui/chat/tools.lua   renderers.todo_write       │
│  ├─ lua/pi/cli.lua             注入 extensions/todo.ts    │
│  └─ config.lua                 options.todo = {...}       │
└──────────────────────────────────────────────────────────┘
```

### 关键架构决策

**D1 — 状态所有权在扩展内，不经 host 隧道。**
subagent 的动作类工具需要隧道（`__pi_subagent__` select）回 Neovim，因为
spawn 进程是 Lua 侧能力。todo 是纯数据，扩展内即可闭环；状态持久化复用官方
示例的 **tool result `details`** 方案——天然分支正确（branch/fork 后扫描分支
重建），且回放路径自动携带。Lua 侧只做**只读镜像**（从 `tool_execution_end`
的 `details` 更新面板），不回写。

**D2 — 单工具、全量替换语义。**
见 §5 工具列表。这是 Claude Code / Codex / opencode 收敛的方案，模型误用面
最小（不存在"忘了先 add 再 toggle"的状态机错误）。

**D3 — 上下文注入分三层，动静分离。**
见 §6。静态纪律走 `before_agent_start`（字节恒定，保 cache）；动态状态走
`context` 事件（非破坏性、不落盘、压缩后自动存活）；工具结果回注固定文本。
任何动态内容都不进系统提示。

**D4 — 父进程与子进程都注入。**
subagent.ts 只注入父进程（子进程用 subagent-child.ts），因为嵌套编排有害；
todo 对长任务子会话同样有益且无嵌套风险，注入方式同 title.ts/vision.ts
（无条件注入，`todo.enabled = false` 时跳过）。

**D5 — 持久视图是与 PiSessions 同栏堆叠的侧栏面板（side 模式）。**
PiSessions（`lua/pi/ui/sessions.lua`）本身已是 per-tab 的侧栏窗口
（`topleft/botright {width}vsplit` + `winfixwidth`），todo 面板作为它的
**伴随窗口上下堆叠在同一列**：先开 sessions 的 vsplit，焦点置于其中再
`split` 出 todo 窗口（两个窗口各持独立 buffer，`winfixwidth` 保持列宽、
todo 窗口 `winfixheight` 固定高度）。这是 Vim 原生窗口布局，无需引入
wm 式布局引擎。面板有自己的 `:PiTodo` 开关，可独立于 PiSessions 存在；
sessions 侧栏打开时两者共用一列、上下排列。
float 模式下堆叠同样可行（`nvim_open_win` 绝对定位，todo float 放在
sessions float 正下方），但首版 float 模式退化为独立小 float 或不显示，
见 §11。`setWidget` 通道废弃不用——widget 是 chat 布局内的文本行，
与"侧栏面板"的形态目标不符，且减少一条扩展→客户端的耦合。

## 5 · 工具列表

### 5.1 唯一工具：`todo_write`

| 属性 | 值 |
|---|---|
| name | `todo_write`（区别于官方示例的 `todo`，避免与用户已装扩展撞名） |
| label | `Todo Write` |
| promptSnippet | `Create and update the session task list to track progress on multi-step work` |
| 语义 | **全量替换**：每次调用提交完整清单；空数组清空 |

```jsonc
{
  "todos": [
    {
      "content":    "Run the test suite",          // 必填，祈使句
      "status":     "pending",                      // 必填：pending | in_progress | completed
      "activeForm": "Running the test suite"        // 可选；in_progress 项建议提供，供 spinner/面板显示
    }
  ]
}
```

字段说明与模型纪律（写进 description，参考 Claude Code/Codex prompt）：
- **何时用**：3 步以上的复杂任务、多事项、用户显式要求、任务有歧义需先列
  高层计划。**何时不用**：单步、琐碎、纯问答。
- **纪律**：任何时刻恰好一个 `in_progress`；完成一项立即标记，不攒批；只有
  真正完成（测试通过、实现完整）才标 `completed`，受阻时保持 `in_progress`
  并新增一项描述阻塞。
- `content` 用祈使句（"Run tests"），`activeForm` 用进行时（"Running
  tests"）。
- 全量提交：每次调用包含完整清单；项的稳定身份由**内容**标识（不引入 id
  字段——见 §5.2 否决理由）。

### 5.2 否决的备选方案

| 方案 | 否决理由 |
|---|---|
| 多 action 单工具（官方示例的 list/add/toggle/clear） | 增量操作引入状态机错误面（toggle 错 id、忘 add 先 toggle）；与主流全量替换语义相悖；`id` 编号在清单重排后易漂移 |
| 四件套（TaskCreate/Get/List/Update，Claude Code v2） | 依赖图复杂度对 pi.nvim 场景收益不成比例；四个工具的描述占用更多提示词预算 |
| 独立 `todo_read` | 冗余：当前清单由 `context` 事件持续注入（§6），模型随时可见，无需主动读 |
| markdown 勾选框字符串（Cline/Roo 风格） | 需要 harness 解析、无法携带 `activeForm`、结构化程度低 |

### 5.3 工具结果

- `content`：固定回注文本 + 紧凑清单镜像，例如
  `Todos updated (2/5 completed). Continue tracking progress with todo_write.`
- `details`：`{ todos: TodoItem[], completed: number, total: number }` ——
  供 Lua 侧渲染与状态镜像，也是分支重建的数据源。

## 6 · 上下文管理机制

三层注入，动静分离（对应 D3）：

### L1 · 静态纪律（`before_agent_start`，字节恒定）

追加 TODO_NOTE 到系统提示——与 subagent.ts 的 ORCHESTRATOR_NOTE、vision.ts
的 CAPABILITY_NOTE 同一模式：**文本必须字节恒定**，任何动态内容（清单、计数、
时间戳）都会击穿 pi 的 prompt-cache 前缀。工具的存在感由 `promptSnippet`
在 Available tools 段自然建立，NOTE 只承载纪律：

> 何时建立清单 / 全量替换语义 / 恰好一个 in_progress / 完成立即标记 /
> activeForm 约定。

### L2 · 动态状态与提醒（`context` 事件，非破坏性）

`context` 在每次 LLM 调用前触发，`event.messages` 是深拷贝——修改**不落盘**、
不污染会话历史，且压缩后依然生效（每次调用都重新注入）。这是比 Claude
Code 的 system-reminder 更强且更省的机制：

- **状态注入**：清单非空时，在消息尾部附加一条合成的简短消息（如
  `[todo] 2/5 completed — in progress: Running the test suite` + 未完成项
  列表），保证最新计划始终处于上下文的高注意力区域。
- **过期提醒**：距上次 `todo_write` 调用超过 N 个 turn（默认 3，可配）且
  仍有未完成项时，附加温和提醒（"todo list 已 N 轮未更新，若仍在多步任务中
  请用 todo_write 同步进度"）。谓词触发，不每轮注入。
- 两种注入都只在条件满足时发生；清单为空则完全不注入。

### L3 · 持久化与恢复

- **分支正确性**：`session_start` / `session_tree` 时扫描分支中
  `toolName == "todo_write"` 的 toolResult，取最新 `details` 重建（同官方
  示例）。
- **压缩存活**：每次成功写入后 `pi.appendEntry` 存一份检查点；恢复时若分支
  扫描无果（旧 tool result 被压缩掉）则回退到检查点。L2 的状态注入保证即使
  全部恢复路径失效，模型也只丢失清单而不丢失"该用 todo"的纪律。

### 注入预算

L1 约 100 token（恒定）；L2 状态注入按紧凑格式渲染（每项一行，超出 10 项
截断为计数），典型 <300 token 且仅在清单非空时出现。不追求 Claude Code 的
"验证 subagent nudge"等高级策略，留作后续。

## 7 · UI 渲染

### 7.1 工具块渲染（`tools.lua` 新增 `renderers.todo_write`）

- 图标：`TOOL_ICONS` 增加 `todo_write`（nf-md 清单类图标）。
- `on_start`：摘要行（`todo·write (5 项)` 样式，本地化 zh/en 同
  `subsessions/tool_ui.lua` 的 LABELS 模式）。
- `on_end`：解析 `details.todos` 渲染三态清单：
  - `✓` completed（dim）、`◐`/accent 高亮 in_progress（显示 `activeForm`，
    缺省回退 `content`）、`○` pending；
  - 头部进度计数 `2/5 completed`；
  - 折叠：沿用 `input_visible`/`output_visible` 阈值，折叠态显示单行进度。
- 回放路径自动可用（replay 携带 `details`）。

### 7.2 持久视图：与 PiSessions 上下堆叠的侧栏面板

形态对齐 PiSessions（`sessions.lua` 的成熟模式）：

```
┌────────────┬──────────────────────────┐
│ sessions   │                          │
│  ...       │        chat / code       │
│────────────│                          │
│ todo       │                          │
│  2/5 done  │                          │
│  ◐ Running │                          │
│  ○ ...     │                          │
└────────────┴──────────────────────────┘
```

- **窗口**：`lua/pi/todo/init.lua` 管理 per-tab 的 todo 窗口（`wins[tab]`，
  同 `sessions.lua` 的模式）。side 模式下：sessions 侧栏已开则在其窗口内
  `split` 堆叠；未开则自己开一个同宽的 vsplit 列。`winfixwidth` +
  `winfixheight`；堆叠高度遵循 sessions 的维度约定：`todo.height < 1` 取
  共栏（sessions + todo）高度的比例——默认 `0.5` 即与 sessions 均分，且
  每次刷新按当前栏高重新推导，手动 `:resize` 的漂移会被拉回配置比例；
  `todo.height >= 1` 为绝对行数。内容超出面板高度时滚动，不再按内容收缩。
- **buffer**：独立 scratch buffer，渲染三态清单 + 进度计数，内容与 §7.1
  工具块渲染共用同一个纯函数（`lua/pi/todo/tool_ui.lua` 出行字符串，
  tools.lua 与面板各取所需）。
- **刷新**：Lua 状态镜像更新（`tool_execution_end` 钩子）→ 重渲染面板，
  与 `sessions.lua` 的 `request_refresh()` 同一节奏；回放路径同样触发。
- **命令**：`:PiTodo` 开关面板（对齐 `:PiSessions` 的 toggle 语义）；
  `todo.auto_open` 配置会话开始且有未完成项时自动展开。
- **float 模式**：首版退化为独立的居中/贴边小 float（复用
  `open_float_win` 的写法），或与 sessions float 上下堆叠，见 §11。`

### 7.3 Lua 状态镜像

`lua/pi/todo/init.lua` 在 manager 的 `tool_execution_end` 路由上挂轻量钩子
（按工具名匹配），维护"当前会话最新清单"快照，供 :PiTodo 与状态栏类集成
消费。纯只读，不回写扩展状态。

## 8 · 配置

```lua
todo = {
    enabled = true,            -- 注入 extensions/todo.ts
    remind_after_turns = 3,    -- L2 过期提醒阈值；0 = 关闭提醒
    max_items = 20,            -- 单项数上限（超出拒绝并提示模型精简）
    panel = {
        auto_open = false,     -- 有未完成项时自动展开面板
        height = 0.5,          -- 堆叠时与 sessions 共栏的配比（<1 比例，0.5 = 均分；>=1 绝对行数）
        position = "below",    -- 相对 sessions 侧栏：above | below
        hide_when_empty = true,
    },
}
```

## 9 · 测试策略

- **单元（plenary）**：`lua/pi/todo/` 状态镜像的 details 解析、渲染器的
  on_start/on_end 输出行、折叠阈值逻辑（参照现有 tools renderer 测试）。
- **扩展侧**：todo.ts 的全量替换语义、恰好一个 in_progress 的校验、分支重建、
  appendEntry 回退（参照 pi 扩展测试方式，或直接对纯函数做单测）。
- **headless e2e**：模拟 RPC 事件序列驱动 `tool_execution_end`，断言
  历史缓冲区渲染、面板 buffer 内容与堆叠窗口布局（列宽、相对位置）。
- **GUI（xdotool）**：侧栏面板与工具块的视觉验证截图。
- 门禁：`make test`、`make style`、`make lint`、`make docs-links`。

## 10 · 落地拆分

1. `extensions/todo.ts`：工具 + L1/L2/L3 上下文管理（纯扩展，可独立用 pi
   TUI 验证）。
2. `lua/pi/cli.lua` + `config.lua`：注入与配置。
3. `lua/pi/todo/tool_ui.lua` + `tools.lua` renderer：工具块渲染。
4. `lua/pi/todo/init.lua`（per-tab 堆叠面板 + `:PiTodo`）+ 与
   `sessions.lua` 的共栏布局协调。
5. 文档（usage.md / configuration.md / keymaps.md / highlight-groups.md
   按需）+ 测试。

每步独立可合入：1+2 即获得完整 agent 侧能力（TUI 可用）；3 起是 pi.nvim
的渲染增强。

## 11 · 开放问题

1. **in_progress 校验的严格度**：发现多个 in_progress 时是拒绝写入（要求模型
   修正）还是静默取第一个？倾向拒绝——自纠正错误比静默降规更利于模型学习，
   与 subagent 的 normalize_item 失败即报错一致。
2. **float 模式下面板形态**：与 sessions float 上下堆叠（绝对定位，实现
   直接）还是独立小 float？首版取实现更简单的，side 模式是主战场。
3. **子进程注入**：子会话（subagent child）同样注入 todo.ts 是否会导致
   子agent 过度规划小任务？可用 prompt 纪律约束，或加 `todo.child = false`
   开关，待实测。
