# Artifact Spec: runprompt-prompt (dotprompt-compatible)

Goal: produce one valid executable Dotprompt `.prompt` file for use in shell-as-mcp runprompt flow.

---

## 1. 文件格式与命名约定

### 1.1 扩展名与结构

- 文件扩展名：`.prompt`
- 局部模板 (Partial)：使用下划线前缀命名，如 `_header.prompt`
- 文件结构：可选的 YAML Frontmatter（`---` 包裹）+ Handlebars 模板 body

```
---
[YAML Frontmatter]
---
[Handlebars 模板 body]
```

- Frontmatter 完全可选；若无需配置，可只写模板 body
- Frontmatter 必须位于文件头部：以 `---` 开始，以 `---` 结束
- 行尾支持 LF 和 CRLF（等价处理）

### 1.2 name 与 variant 的文件名推断规则

| 文件名 | 推断 name | 推断 variant |
|--------|-----------|-------------|
| `greet.prompt` | `greet` | (无) |
| `greet.formal.prompt` | `greet` | `formal` |
| `greet.casual.prompt` | `greet` | `casual` |

Frontmatter 中显式声明的 `name`/`variant` 优先级高于文件名推断。

### 1.3 局部模板命名

`_footer.prompt` 注册为 `footer`，在模板中通过 `{{> footer}}` 引用。
局部模板不进行 Frontmatter 解析；注释应使用 `{{!-- --}}` Handlebars 注释。

---

## 2. YAML Frontmatter 字段完整参考

### 2.1 顶层字段总表

| 字段 | 类型 | 必填 | 默认值 | 描述 |
|------|------|------|--------|------|
| `name` | `string` | 否 | 从文件名推断 | 提示词标识名称 |
| `variant` | `string` | 否 | 从文件名推断 | 变体名称（如 formal/casual） |
| `model` | `string` | 否（推荐填写） | 实现默认值 | 模型标识符 |
| `config` | `object` | 否 | `{}` | 传递给模型的参数 |
| `input` | `object` | 否 | 接受任意 Map | 输入变量定义 |
| `output` | `object` | 否 | — | 期望输出格式定义 |
| `tools` | `string[]` | 否 | `[]` | 工具名称列表 |
| `toolConfig` | `object` | 否 | — | 工具调用配置（实现相关） |
| `metadata` | `Map<string,any>` | 否 | `{}` | 任意元数据，供代码/工具消费 |
| `ext.*` | 命名空间字段 | 否 | — | 扩展字段，点分隔命名空间 |

### 2.2 model 字段

`model` 为模型标识符字符串，格式由底层实现定义。示例：

```yaml
model: googleai/gemini-2.5-flash
model: openrouter/deepseek/deepseek-v3.2
model: vertexai/gemini-2.5-pro
```

### 2.3 name 与 variant 字段

显式声明覆盖文件名推断：

```yaml
name: greetingPrompt
variant: formal
```

### 2.4 tools 与 toolConfig 字段

`tools` 引用已在实现中注册的工具名（字符串列表）。`toolConfig` 为工具调用行为配置（实现相关）：

```yaml
tools:
  - searchWeb
  - calculateMath
toolConfig:
  mode: AUTO
```

内联工具定义（含参数 schema）：

```yaml
tools:
  - name: searchWeb
    description: 搜索互联网
    parameters:
      query: string, 搜索查询词
      maxResults?: number, 最大结果数
```

### 2.5 config 字段（模型参数）

| 子字段 | 类型 | 示例值 | 描述 |
|--------|------|--------|------|
| `temperature` | `number` | `0.7` | 随机度（0=确定性，2.0=最高随机） |
| `maxOutputTokens` | `number` | `1024` | 最大输出 token 数 |
| `topK` | `number` | `40` | Top-K 采样参数 |
| `topP` | `number` | `0.95` | 核采样参数（0–1） |
| `stopSequences` | `string[]` | `["END"]` | 停止生成的触发字符串 |
| `presencePenalty` | `number` | `0.0` | 存在惩罚系数（-2.0–2.0） |
| `frequencyPenalty` | `number` | `0.0` | 频率惩罚系数（-2.0–2.0） |
| `responseMimeType` | `string` | `"application/json"` | 响应 MIME 类型提示 |
| `version` | `string` | `"gemini-2.5-flash"` | 模型版本锁定 |

`config` 为通用 Map，额外字段原样传递给模型实现。

### 2.6 input 字段

| 子字段 | 类型 | 描述 |
|--------|------|------|
| `input.schema` | Picoschema \| JSON Schema | 输入变量结构定义（见第 3 节） |
| `input.default` | `Map<string,any>` | 默认值，与实际传入值浅合并 |

```yaml
input:
  default:
    name: "Guest"
    language: "zh"
  schema:
    name: string, 用户姓名
    language?: string, 语言偏好
```

### 2.7 output 字段

| 子字段 | 类型 | 允许值 | 描述 |
|--------|------|--------|------|
| `output.format` | `string` | `json` \| `text` \| `media` | 期望的输出格式 |
| `output.schema` | Picoschema \| JSON Schema | — | 期望输出结构（`output.format: json` 时使用） |

`output.format` 三种值语义：
- `json`：结构化 JSON 输出，SHOULD 配合 `output.schema`
- `text`：纯文本输出
- `media`：媒体输出（图片/视频/音频等）

Schema 验证是下游 SDK 的责任，dotprompt 本身只解析和暴露 schema。

### 2.8 metadata 与 ext 扩展字段

`metadata` 存放任意键值对，供代码消费；`ext.*` 以点分隔命名空间自动收集到 `ext` 对象：

```yaml
metadata:
  customKey:
    customValue: 123
ext1.foo: bar
ext1.sub1.foo: baz
```

---

## 3. Picoschema 语法规范

Picoschema 是 dotprompt 的简洁 schema 描述语言，可直接写在 `input.schema` / `output.schema` 下。

### 3.1 标量类型

| 类型 | 语法示例 | JSON Schema 等价 |
|------|----------|-----------------|
| `string` | `name: string` | `{type: "string"}` |
| `number` | `price: number` | `{type: "number"}` |
| `integer` | `age: integer` | `{type: "integer"}` |
| `boolean` | `active: boolean` | `{type: "boolean"}` |
| `null` | `empty: null` | `{type: "null"}` |
| `any` | `data: any` | `{}` (无类型限制) |

不支持上述以外的标量类型，用则报错。

### 3.2 可选字段（`?` 修饰）

字段名后追加 `?`，该字段不计入 `required[]`，类型变为 `[type, "null"]`：

```yaml
title?: string          # → {type: ["string", "null"]}
score?: number          # → {type: ["number", "null"]}
```

### 3.3 数组与对象修饰

**数组** — `fieldName(array[, 描述]): elementType`：

```yaml
tags(array): string                    # string 数组
items(array, 商品列表): number          # 带描述的 number 数组
variants?(array): string               # 可选的 string 数组
```

数组的元素类型也可以是嵌套对象（缩进写法）：

```yaml
products(array):
  id: string
  price: number
```

**对象** — 默认写法（子字段直接缩进），或显式 `(object)`：

```yaml
address(object, 收件人地址):
  street: string
  city: string
  zip?: string
```

Picoschema 对象默认 `additionalProperties: false`。

### 3.4 枚举类型

语法：`fieldName(enum[, 描述]): [VAL1, VAL2, ...]`：

```yaml
status(enum): [PENDING, APPROVED, REJECTED]
color?(enum, 颜色选择): [RED, BLUE, GREEN]   # 可选枚举，含 null
```

### 3.5 通配符字段 `(*)`

在对象块内使用 `(*): type` 允许任意额外属性（等价 `additionalProperties`）：

```yaml
attributes(object, 自定义属性):
  (*): any, 允许任意键值
```

### 3.6 字段描述写法

类型名后接逗号再接描述文本；仅第一个逗号作为类型/描述分隔符，描述中可含额外逗号：

```yaml
price: number, 当前商品价格（含税）
note: string, the description, which has, multiple commas
```

### 3.7 完整 Picoschema 示例

```yaml
input:
  schema:
    userId: string, 用户唯一 ID
    age?: integer, 年龄（可选）
    tags(array, 标签列表): string
    address(object, 地址):
      city: string
      zip?: string
    status(enum): [ACTIVE, INACTIVE]
    metadata(object, 扩展数据):
      (*): any
```

### 3.8 JSON Schema 直通

若 schema 顶层含 `type` 属性，自动视为原生 JSON Schema，绕过 Picoschema 解析：

```yaml
output:
  schema:
    type: object          # ← 触发 JSON Schema 直通
    properties:
      name: {type: string}
    required: [name]
```

---

## 4. Handlebars 模板语法规范

### 4.1 基础插值与 HTML **不转义**（⚠️ 重要）

| 语法 | 描述 |
|------|------|
| `{{var}}` | 变量插值 |
| `{{obj.key}}` | 点路径访问 |
| `{{a.b.c}}` | 深层路径 |
| `{{../var}}` | 访问父上下文 |
| `{{.}}` / `{{this}}` | 当前上下文引用 |
| `{{{var}}}` | 三花括号（标准 Handlebars 原样输出） |
| `\{{var}}` | 输出字面量 `{{var}}` |

> ⚠️ **Dotprompt 与标准 Handlebars 的关键差异**：`{{var}}` 默认**不执行 HTML 转义**。
> 即 `{{name}}` 当 name=`<b>Pavel</b>` 时，输出 `<b>Pavel</b>` 而非 `&lt;b&gt;Pavel&lt;/b&gt;`。
> 这与标准 Handlebars 行为相反，在处理含 HTML 特殊字符的内容时须特别注意。

**注释**：

| 语法 | 描述 |
|------|------|
| `{{! text }}` | 单行注释（输出中不可见） |
| `{{!-- text --}}` | 多行注释（输出中不可见） |

### 4.2 条件与迭代

**条件**：

```handlebars
{{#if condition}}
  条件为真时的内容
{{else}}
  条件为假时的内容
{{/if}}

{{#unless condition}}
  条件为假时的内容
{{/unless}}
```

**迭代**（`#each` 内可用 `@index`、`@key`、`@first`、`@last`）：

```handlebars
{{#each items}}
  {{@index}}. {{this}}
{{/each}}
```

**上下文切换**：

```handlebars
{{#with user}}
  Name: {{name}}, Email: {{email}}
{{/with}}
```

### 4.3 Dotprompt 专属 Helpers（7 个，MUST 全部支持）

#### `{{role}}` — 角色切换

两种语法形式均有效：

```handlebars
{{role "system"}}系统提示词内容（内联形式）

{{#role "user"}}
用户消息（block 形式）
{{/role}}
```

支持的角色值：`"system"`、`"user"`、`"model"`。

#### `{{history}}` — 历史消息注入

在此位置插入所有历史 messages（通过 `data.messages` 传入）；无历史时静默处理：

```handlebars
{{role "system"}}系统提示词
{{history}}
{{role "user"}}当前用户消息
```

#### `{{json}}` — JSON 序列化

```handlebars
{{json value}}               {{! 紧凑 JSON }}
{{json value indent=2}}      {{! 2 空格缩进 }}
{{json this indent=4}}       {{! 当前上下文，4 空格缩进 }}
```

#### `{{media}}` — 媒体内联（见第 5 节）

```handlebars
{{media url=imageUrl}}
{{media url=videoUrl contentType="video/mp4"}}
```

#### `{{section}}` — 命名段落标记

在消息内容中插入带 `purpose` 标记的分隔符，供下游组织消息结构：

```handlebars
{{section "intro"}}
介绍段落内容
{{section "main"}}
主要内容
```

#### `{{#ifEquals}}` — 严格相等比较

使用严格相等（`===`），不做类型转换（`5 !== "5"`）：

```handlebars
{{#ifEquals userType "admin"}}
  拥有管理员权限
{{else}}
  标准用户权限
{{/ifEquals}}
```

#### `{{#unlessEquals}}` — 严格不等比较

```handlebars
{{#unlessEquals status "disabled"}}
  功能可用
{{/unlessEquals}}
```

### 4.4 Partials（局部模板）

```handlebars
{{> partialName}}                      {{! 基础引用 }}
{{> greeting name=username}}           {{! 传递具名参数 }}
{{> userProfile this}}                 {{! 传递当前上下文 }}
```

局部模板文件以 `_` 前缀命名（如 `_footer.prompt`），注册名去掉下划线（`footer`）。

### 4.5 空白控制（Tilde）

| 语法 | 效果 |
|------|------|
| `{{~var}}` | 去除**左侧**空白/换行 |
| `{{var~}}` | 去除**右侧**空白/换行 |
| `{{~var~}}` | 去除两侧空白 |

示例：`Hello   {{~name~}}   World` → `HelloBeautifulWorld`

---

## 5. 多模态支持（Media）

`{{media}}` helper 将媒体引用注入消息内容数组中。

**参数**：
- `url`（必填）：媒体地址，支持 HTTP URL 和 base64 data URL
- `contentType`（可选）：MIME 类型；`mime` 是其别名

**完整语法**：

```handlebars
{{media url=imageUrl}}
{{media url=videoUrl contentType="video/mp4"}}
{{media url=audioUrl contentType="audio/mpeg"}}
{{media url="data:image/jpeg;base64,/9j/4AAQ..." contentType="image/jpeg"}}
{{media contentType=contentType url=url}}
```

**支持的 contentType**：

| 类别 | 示例值 |
|------|--------|
| 图片 | `image/jpeg`、`image/png`、`image/webp`、`image/gif` |
| 视频 | `video/mp4`、`video/webm` |
| 音频 | `audio/mpeg`、`audio/wav`、`audio/ogg` |

输出为消息内容数组中的一个 media part：`{media: {url: "...", contentType: "..."}}`

---

## 6. 多轮对话（Multi-turn / History）

### 6.1 传入历史消息

渲染时通过 `data.messages` 传入历史，格式为：

```yaml
messages:
  - role: user
    content: [{text: "你好"}]
  - role: model
    content: [{text: "你好！有什么可以帮你？"}]
```

### 6.2 模板写法

`{{history}}` 负责在该位置展开历史消息列表：

```handlebars
{{role "system"}}你是一位有帮助的助手。
{{history}}
{{role "user"}}{{userMessage}}
```

历史消息自动附加 `metadata.purpose: "history"` 标记。若模板中无显式 `{{history}}`，历史消息自动附加在最后一条 system 消息之后。

### 6.3 input.default 与历史结合

```yaml
input:
  default:
    userName: "访客"
  schema:
    userName: string
    userMessage: string
```

`input.default` 提供缺省值，与调用方传入的输入浅合并（shallow merge）。

---

## 7. shell-as-mcp runprompt 兼容约束

以下约束专属于 shell-as-mcp runprompt 流，必须遵守：

1. 输出文件 MUST 是纯 `.prompt` 文本，**不得**包含 Markdown 代码围栅（`` ``` ``）或说明文字。
2. Frontmatter MUST 以 `---` 作为第一行起始。
3. Frontmatter MUST 包含 `model` 字段（shell-as-mcp runprompt 专属约束；Dotprompt 官方规范中 `model` 为可选项）。
4. 模板 body MUST 非空（必须有实质性的提示词文本）。
5. 输入变量 SHOULD 可通过 JSON 字段传递（避免依赖运行时注入的不可序列化对象）。
6. 若生成结构化输出（`output.format: json`），`output.schema` 定义与模板 body 中的输出指令 MUST 保持一致。
7. 仅使用规范内定义的 Handlebars helpers；自定义 helper 须在执行环境中显式注册。

---

## 8. One-shot 参考示例集

### 示例 1：文本摘要（text 输出）

```yaml
---
name: summarize-text
model: openrouter/deepseek/deepseek-v3.2
input:
  schema:
    text: string, 需要摘要的原文
output:
  format: text
---
Summarize the following text in Chinese, keeping it under 150 words:

{{text}}
```

### 示例 2：数据提取（json 输出，含完整 schema）

```yaml
---
name: extract-person-info
model: googleai/gemini-2.5-flash
input:
  schema:
    text: string
output:
  format: json
  schema:
    name?: string, 人物全名
    age?: integer, 年龄
    occupation?: string, 职业
    skills(array): string
---
Extract the requested information from the given text.
If a piece of information is not present, omit that field.

Text: {{text}}
```

### 示例 3：多角色对话模板（role helper）

```yaml
---
name: customer-support
model: googleai/gemini-2.5-pro
config:
  temperature: 0.3
input:
  schema:
    productName: string
    userQuery: string
output:
  format: text
---
{{#role "system"}}
You are a helpful customer support agent for {{productName}}.
Always be polite and concise.
{{/role}}

{{role "user"}}
{{userQuery}}
```

### 示例 4：历史消息模板（history helper）

```yaml
---
name: chat-assistant
model: googleai/gemini-2.5-flash
input:
  default:
    assistantName: "Assistant"
  schema:
    assistantName: string
    userMessage: string
output:
  format: text
---
{{role "system"}}
You are {{assistantName}}. Be helpful and friendly.
{{history}}
{{role "user"}}
{{userMessage}}
```

### 示例 5：多模态图片描述（media helper）

```yaml
---
name: describe-image
model: googleai/gemini-2.5-pro
input:
  schema:
    imageUrl: string, 图片 URL 或 base64 data URL
    prompt?: string, 额外的描述提示
output:
  format: text
---
{{role "system"}}
You are an expert image analyst. Describe the image in detail.

{{role "user"}}
Please analyze this image:
{{media url=imageUrl contentType="image/jpeg"}}

{{#if prompt}}
Additional context: {{prompt}}
{{/if}}
```

### 示例 6：完整 frontmatter 演示（含 ifEquals + section）

```yaml
---
name: adaptive-assistant
variant: formal
model: googleai/gemini-2.5-flash
config:
  temperature: 0.7
  topK: 20
  topP: 0.8
input:
  default:
    userType: "guest"
  schema:
    userType: string
    query: string
    language?: string, 语言偏好
output:
  format: json
  schema:
    answer: string, 回答内容
    confidence?: number, 置信度 0-1
metadata:
  team: platform
  version: "2.0"
---
{{role "system"}}
{{#ifEquals userType "admin"}}
You have admin-level access. Full information may be disclosed.
{{else}}
You have standard access. Follow privacy guidelines.
{{/ifEquals}}

{{section "instructions"}}
Answer user queries accurately and concisely.
{{#if language}}Respond in: {{language}}{{/if}}

{{role "user"}}
{{query}}
```

---

## 9. 严格输出约束（Strict Output Constraints）

当 `artifact_type=runprompt-prompt` 时，LLM 输出 MUST 遵循：

- **MUST NOT** 在 frontmatter 之前输出任何说明文字
- **MUST NOT** 使用 Markdown 代码围栏（`` ``` `` 或 ` ```prompt `）包裹输出
- **MUST NOT** 输出多个候选 prompt（只输出一个）
- **MUST NOT** 在文件末尾追加任何解释或注释
- **MUST** 以 `---` 作为文件第一行（有 frontmatter 时）
- **MUST** 保持模板 body 非空
- **MUST** 确保所有 Handlebars block helper 正确关闭（`{{/if}}`、`{{/each}}`、`{{/role}}` 等）
- **MUST** 确保 `output.schema` 中声明的字段与模板 body 指令一致（有 `output.format: json` 时）
- **SHOULD** 在 `input.schema` 中声明所有模板使用的变量

---

## 10. 跨规范一致性（Cross-Spec Consistency for shell-as-mcp）

当该 `.prompt` 用于生成 shell-as-mcp bundle（含 YAML + 脚本）时，提示词内容应与 type-specs 保持一致：

- 若 YAML 中存在 `execution.compatibility.targets[*].support: tested`，提示词 **MUST** 要求生成对应的 per-target smoke test 脚本：`{prefix}__smoke_test__{kernel}_{arch}.sh`。
- 提示词 **SHOULD** 同时要求存在 generic smoke test 锚点：`{prefix}__smoke_test.sh`，以便 lint 推导 `{prefix}`。
- 提示词 **SHOULD** 要求 smoke tests 可由 `bash scripts/run_smoke_tests.sh` 统一执行，并保持无网络、低副作用（low side-effect）。
