# shell-as-mcp

TypeScript Shell-as-MCP Server：通过 **单文件 YAML 规范** 将 shell 命令映射为标准 MCP 工具。

---

## 1) YAML Spec 设计

每个 YAML 文件定义一个 MCP 工具，根键必须包含 `apiVersion`、`tool`、`execution`。

```yaml
apiVersion: v1
tool:
  name: <server>__<action>        # snake_case，例如 brew__install
  description: |-
    /**
     * 一句话说明工具用途（TSDoc 格式，唯一描述字段）。
     * @param param_name 参数说明
     */
  input:
    properties:
      param_name:
        type: string              # string | number | integer | boolean
        description: "..."
    required: [param_name]
  output:
    type: object
    properties:
      status:            { type: string }
      exit_code:         { type: number }
      stdout:            { type: string }
      stderr:            { type: string }
      command:           { type: string }
      execution_time_ms: { type: number }
execution:
  shell:
    mode: direct                  # direct | shell
    name: bash                    # 可选：bash | zsh | sh | pwsh | cmd
    path: /usr/bin/bash           # 可选，优先于 name
    args: ["-lc"]                 # 可选，未填使用默认
  env:
    static:
      KEY: VALUE
    fromParams:
      TOOL_ENV_KEY: inputParamName  # UPPER_SNAKE_CASE；不确定时加 TOOL_ 前缀
    fromRuntime:
      TARGET_ENV: SOURCE_ENV        # 从服务运行时环境映射，支持优先级列表
      TOOL_OUTPUT_DIR: [YTDLP_OUTPUT_DIR, SHELL_AS_MCP_OUTPUT_DIR]
  compatibility:
    targets:
      - os: macos
        kernel: darwin
        arch: arm64
        support: tested            # 可选：tested | declared
        notes: Apple Silicon only validated target
  workingDirectory: /tmp/work
  timeoutMs: 30000
  maxOutputBytes: 1048576
  # 脚本模式（推荐：bundle 中始终使用此模式）
  script:
    path: ./scripts/<tool_name>.sh  # 相对于 YAML 所在目录
    interpreter: bash
  # 命令模式（仅用于单一可执行文件 + 静态参数，禁止在 args 中使用 && || ; | > <）
  # command:
  #   executable: ffmpeg
  #   args: ["-version"]
```

**关键约束：**

- `tool.name` 格式为 `<server>__<action>`，全小写 snake_case
- `tool.description` 必须为 TSDoc `/** */` 块注释
- `execution.env.fromParams` 环境变量名用 UPPER_SNAKE_CASE；与系统保留名（`PATH`、`HOME`、`USER` 等）冲突时加 `TOOL_` 前缀
- `execution.compatibility` 是可选兼容性元数据（compatibility metadata）；若存在，`targets` 必须是非空数组，且每个 target 的 `os`、`kernel`、`arch` 都必须为非空字符串
- `targets[].support` 可选且仅允许 `tested` 或 `declared`；`targets[].notes` 可选且必须为字符串
- 若 target 标记为 `support: tested`，必须在同 bundle 的 `scripts/` 下提供对应 per-target smoke test：`{prefix}__smoke_test__{kernel}_{arch}.sh`（例如 `brew__smoke_test__darwin_arm64.sh`）
- **`execution.command` 禁用**：args 中含 `&&`、`||`、`;`、`|`、`>`、`<` 等 shell 操作符时禁止使用；多步逻辑必须用 `execution.script`
- 每个 YAML 只定义一个工具
- `execution.env.fromRuntime` 支持字符串数组，按从左到右优先级短路匹配；适合表达组级默认值到全局默认值的 fallback

### 1.1 compatibility 元数据（Compatibility Metadata）

`execution.compatibility.targets` 表达的是“已知运行目标（known runtime targets）”，不是“唯一允许执行的平台（hard platform gate）”。

- 推荐把每个 target 当作一个完整元组（tuple）来声明，避免把 `os`、`kernel`、`arch` 拆成独立列表后产生错误的笛卡尔积（cartesian product）含义。
- `support: tested` 表示该目标有实际验证证据；省略或 `declared` 表示声明可运行，但当前仓库未把它当作运行时拦截条件。
- `support: tested` 的证据载体为 per-target smoke test 脚本：`{prefix}__smoke_test__{kernel}_{arch}.sh`；lint 会进行存在性校验。
- 当前 loader 与 lint 会校验字段结构，但服务启动与工具暴露逻辑不会因为该字段而做平台过滤（platform filtering）。

### 1.2 healthz 契约（Health Check Contract）

`__healthz` 工具的职责（responsibility）是做**依赖可用性探测（dependency availability probe）**，不是业务功能执行（business execution）。

- 目标：快速判断某个 command bundle 的关键运行时依赖是否存在并可调用。
- 输出语义：`status=success` 表示依赖可用；`status=error` 表示依赖缺失或不可调用。
- 失败边界：healthz 失败只说明该 bundle 当前环境不满足运行条件，不应伪装为成功。
- 设计要求：healthz 必须保持轻量（lightweight）与可重复执行（idempotent），避免副作用。

### 1.3 0 参数工具与 Lint 规则（Zero-Parameter Tool Rule）

对 0 参数工具（zero-parameter tools，例如 healthz），YAML 输入契约必须满足：

- `tool.input` 必须存在且是 mapping（对象）。
- `tool.input.properties` 必须存在且是 mapping；允许为空对象。
- `tool.input.required` 对 0 参数工具应为空列表。
- 不允许为了“通过校验”引入虚拟参数（dummy parameter）。

Lint 对齐规则：

- Lint 校验 `tool.input.properties` 的**存在性与类型**，不再强制“非空”。
- 这样可确保 0 参数工具的合法表达与运行时行为（runtime behavior）一致。

完整规范参见 [`shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/shell-as-mcp-yaml.spec.md`](shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/shell-as-mcp-yaml.spec.md)。

---

## 2) 如何开发 shell_as_mcp_defs

`shell_as_mcp_defs/` 下每个子目录是一个 **command bundle**，结构如下：

```
shell_as_mcp_defs/<server>/
  spec_yaml/          # 每工具一个 YAML 定义文件
  scripts/            # 每工具一个 .sh 脚本（被 YAML 的 execution.script.path 引用）
  prompts/            # 可选：runprompt 提示词模板
```

**手动开发流程：**

1. 在 `spec_yaml/` 下创建 `<server>__<action>.yaml`，遵循第 1 节规范
2. 在 `scripts/` 下创建同名 `.sh`，通过 `$TOOL_*` 环境变量读入参数
3. 运行 `bash scripts/lint/lint_all.sh` 验证

**通过 `runprompt__generate_artifact` 工具生成：**

> ⚠️ **开发中（WIP）**：`runprompt__generate_artifact` 的自动生成功能仍在开发阶段，尚不稳定。`type-specs/` 下的规范文档可直接用于手动开发参考，但不建议依赖该工具在生产环境自动生成 bundle。

`runprompt__generate_artifact` 可让 LLM 一次生成完整 bundle（YAML + 脚本 + 可选 prompt），产物自动写入 `SHELL_AS_MCP_SPEC_DIR/<server_name>/`。

> **LLM 开发新 bundle 的指引（AI prompt）**
>
> 开发新的 `shell_as_mcp_defs` bundle 时：
>
> 1. 完整规范参见 `shell_as_mcp_defs/runprompt__generate_artifact/prompts/type-specs/`：
>    - `shell-as-mcp-yaml.spec.md` — YAML 结构与禁止模式
>    - `script.spec.md` — 对应 shell 脚本规范
>    - `runprompt-prompt.spec.md` — runprompt 提示词规范
> 2. 参考现有 bundle 示例：`brew/`、`ytdlp/`、`host_info/`、`ffmpeg/`
> 3. 所有工具入参必须通过 `execution.env.fromParams` 映射为 UPPER_SNAKE_CASE 环境变量，加 `TOOL_` 前缀；脚本只读 `$TOOL_*`，不直接读 `$1`
> 4. 脚本中尽早校验参数（fail fast）；敏感操作须在脚本内二次鉴权，不依赖调用方
> 5. `execution.command` 仅用于单行静态命令；多步逻辑一律用 `execution.script`

---

## 3) 预设工具

> 所有 bundle 位于 `shell_as_mcp_defs/`，启动时从 `SHELL_AS_MCP_SPEC_DIR` 加载。

### 3.1 host_info

| 工具 | 描述 |
| --- | --- |
| `host_info__get_host_context` | 采集主机系统上下文（OS、locale、timezone、hardware、~35 种开发工具版本），适合作为代码执行任务的第一步调用 |

**参数：**

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `include_hardware` | boolean | 否 | 是否包含 CPU 数和内存大小，默认 `true` |
| `filter_tools` | string | 否 | 逗号分隔的工具名（如 `python3,node`），空 = 检查全部 |
| `output_format` | string | 否 | `pretty`（默认）或 `compact` |

---

### 3.2 ffmpeg

| 工具 | 描述 | 必填参数 | 可选参数 |
| --- | --- | --- | --- |
| `ffmpeg__process_video_for_llm` | 视频预处理（裁剪/缩放/降帧/倍速/去音频/水印） | `input_path`, `output_path` | `start_time`, `end_time`, `max_resolution`, `fps`, `speed_factor`, `strip_audio`, `watermark_path` |
| `ffmpeg__process_audio_for_stt` | 音频预处理（片段/降采样/单声道/静音移除） | `input_path`, `output_path` | `start_time`, `end_time`, `sample_rate`, `channels`, `remove_silence`, `audio_format` |
| `ffmpeg__extract_frames_for_vision` | 视觉抽帧（低帧率或关键帧） | `input_path` | `output_dir`, `start_time`, `end_time`, `fps`, `keyframes_only`, `max_resolution` |
| `ffmpeg__create_video_summary` | 蒙太奇摘要视频（多输入采样拼接） | `input_paths`, `output_path` | `interval_sec`, `clip_duration_sec`, `merge_audio` |

### 3.2.1 ffmpeg 输出目录默认值策略

当前仅对 `ffmpeg__extract_frames_for_vision` 生效。

优先级如下：

1. 显式参数 `output_dir`
2. 组级环境变量 `FFMPEG_OUTPUT_DIR`
3. 全局环境变量 `SHELL_AS_MCP_OUTPUT_DIR`

该工具仍然保持“目录输出”契约不变，只是允许在未显式传参时，从运行时环境补齐默认目录。

---

### 3.3 brew

> ⚠️ `brew__install` / `brew__uninstall` / `brew__upgrade` 需将 `confirm_action=true` 以授权执行，脚本还会弹出 macOS 原生授权对话框。

| 工具 | 描述 | 必填参数 | 可选参数 |
| --- | --- | --- | --- |
| `brew__info` | 查询 formula/cask 详情（版本、依赖、homepage） | `package_name` | `cask` |
| `brew__search` | 搜索包 | `query` | `include_casks` |
| `brew__list_installed` | 列出已安装包 | — | `casks_only`, `formulae_only` |
| `brew__install` | 安装 formula/cask | `package_name`, `confirm_action` | `cask` |
| `brew__uninstall` | 卸载 formula/cask | `package_name`, `confirm_action` | `cask`, `force` |
| `brew__upgrade` | 升级 formula/cask | `package_name`, `confirm_action` | `cask` |

---

### 3.4 ytdlp

> `cookies` 参数接受 Netscape 格式 cookies 文件路径；也可先运行 `ytdlp__setup_cookies` 将 cookies 加密存储，后续工具在未指定 `cookies` 时自动回退使用。

| 工具 | 描述 | 必填参数 | 可选参数 |
| --- | --- | --- | --- |
| `ytdlp__setup_cookies` | 引导 macOS 用户通过浏览器扩展导出 cookies 并加密保存（macOS only） | — | `overwrite` |
| `ytdlp__download_video` | 下载视频（支持分辨率选择和时间段裁剪） | `url` | `resolution`, `startTime`, `endTime`, `output_dir`, `cookies`, `proxy` |
| `ytdlp__download_audio` | 下载音频 | `url` | `output_dir`, `cookies`, `proxy` |
| `ytdlp__download_transcript` | 下载字幕文本内容 | `url` | `language`, `cookies`, `proxy` |
| `ytdlp__download_video_subtitles` | 下载字幕文件 | `url` | `language`, `output_dir`, `cookies`, `proxy` |
| `ytdlp__list_subtitle_languages` | 列出视频可用字幕语言 | `url` | `cookies`, `proxy` |
| `ytdlp__get_video_metadata` | 获取视频完整元数据 JSON | `url` | `fields`, `cookies`, `proxy` |
| `ytdlp__get_video_metadata_summary` | 获取视频元数据摘要（标题/时长/频道等） | `url` | `cookies`, `proxy` |
| `ytdlp__get_video_comments` | 获取评论列表 | `url` | `max_count`, `sort`, `cookies` |
| `ytdlp__get_video_comments_summary` | 获取评论摘要 | `url` | `count`, `cookies`, `proxy` |
| `ytdlp__search_videos` | 搜索视频 | `query` | `count`, `offset`, `format` |

### 3.4.1 输出目录默认值策略

仅对 ytdlp 下载类工具生效：`ytdlp__download_video`、`ytdlp__download_audio`、`ytdlp__download_video_subtitles`。

优先级如下：

1. 显式参数 `output_dir`
2. 组级环境变量 `YTDLP_OUTPUT_DIR`
3. 全局环境变量 `SHELL_AS_MCP_OUTPUT_DIR`
4. 历史默认值 `~/Downloads`

脚本统一读取 `TOOL_OUTPUT_DIR`，bundle 通过 `execution.env.fromRuntime` 与 `execution.env.fromParams` 完成映射；这不会改变 `output_path` / `output_dir` 既有语义，只是为下载类工具补充默认值来源。

---

## 4) 运行方式

```bash
npm install
npm run build
npm start
```

### 4.1 通过 GitHub 仓库 `npx -y` 启动（stdio）

```bash
npx -y github:meomeo-dev/shell-as-mcp --transport stdio
```

若使用 `runprompt__generate_artifact` 工具，需额外安装 `runprompt`：

```bash
# Using uv (recommended)
uv pip install git+https://github.com/chr15m/runprompt
# Using pip
pip install "git+https://github.com/chr15m/runprompt.git"
```

### 4.2 启动参数与环境变量

| 参数 | 环境变量 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `--transport` | `SHELL_AS_MCP_TRANSPORT` | `stdio` | `stdio` 或 `streamable-http` |
| `--spec-dir` | `SHELL_AS_MCP_SPEC_DIR` | `./shell_as_mcp_defs` | YAML spec 目录（overlay） |
| `--host` | `SHELL_AS_MCP_HTTP_HOST` | `127.0.0.1` | HTTP 监听地址 |
| `--port` | `SHELL_AS_MCP_HTTP_PORT` | `3001` | HTTP 监听端口 |
| `--http-path` | `SHELL_AS_MCP_HTTP_PATH` | `/mcp` | HTTP 路径 |
| — | `SHELL_AS_MCP_SERVER_NAME` | `shell-as-mcp` | MCP server 名称 |
| — | `SHELL_AS_MCP_SERVER_VERSION` | `package.json` version | MCP server 版本 |

### 4.3 内置 Spec 与扩展目录

内置 `shell_as_mcp_defs/` 中的工具**始终从包内直接加载**；`SHELL_AS_MCP_SPEC_DIR` 是**扩展叠加目录**（overlay），额外加载其中的工具，同名工具以用户目录为准（覆盖内置）。

- 默认值为 `./shell_as_mcp_defs`（与内置路径相同时只加载一次）

---

## 5) mcpServers 配置

### 5.1 stdio（推荐本地使用）

```json
{
  "mcpServers": {
    "shell-as-mcp": {
      "command": "npx",
      "args": ["-y", "github:meomeo-dev/shell-as-mcp", "--transport", "stdio"],
      "env": {
        "SHELL_AS_MCP_SPEC_DIR": "/absolute/path/to/specs",
        "RUNPROMPT_MODEL": "openrouter/deepseek/deepseek-v3.2",
        "RUNPROMPT_BASE_URL": "https://openrouter.ai/api/v1",
        "RUNPROMPT_OPENROUTER_API_KEY": "sk-or-v1-xxxx",
        "https_proxy": "http://127.0.0.1:8890",
        "HTTPS_PROXY": "http://127.0.0.1:8890"
      }
    }
  }
}
```

### 5.2 streamable-http

```json
{
  "mcpServers": {
    "shell-as-mcp-http": {
      "command": "npx",
      "args": [
        "-y", "github:meomeo-dev/shell-as-mcp",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", "3001",
        "--http-path", "/mcp"
      ],
      "env": {
        "SHELL_AS_MCP_SPEC_DIR": "/absolute/path/to/specs",
        "SHELL_AS_MCP_SERVER_NAME": "shell-as-mcp-http"
      }
    }
  }
}
```

### 5.3 MCP 配置可用环境变量

下面这些环境变量可以直接放进 `mcpServers.<name>.env`。

#### 服务启动类

| 环境变量 | 作用 | 默认值 |
| --- | --- | --- |
| `SHELL_AS_MCP_TRANSPORT` | 传输模式：`stdio` 或 `streamable-http` | `stdio` |
| `SHELL_AS_MCP_SPEC_DIR` | 扩展 spec 目录（overlay） | `./shell_as_mcp_defs` |
| `SHELL_AS_MCP_HTTP_HOST` | HTTP 监听地址 | `127.0.0.1` |
| `SHELL_AS_MCP_HTTP_PORT` | HTTP 监听端口 | `3001` |
| `SHELL_AS_MCP_HTTP_PATH` | HTTP 路径 | `/mcp` |
| `SHELL_AS_MCP_SERVER_NAME` | MCP server 名称 | `shell-as-mcp` |
| `SHELL_AS_MCP_SERVER_VERSION` | MCP server 版本 | `package.json` version |

#### 输出目录默认值类

| 环境变量 | 作用 | 当前适用范围 |
| --- | --- | --- |
| `SHELL_AS_MCP_OUTPUT_DIR` | 全局输出目录兜底 | `ytdlp__download_video`、`ytdlp__download_audio`、`ytdlp__download_video_subtitles`、`ffmpeg__extract_frames_for_vision` |
| `YTDLP_OUTPUT_DIR` | ytdlp 组级输出目录 | `ytdlp__download_video`、`ytdlp__download_audio`、`ytdlp__download_video_subtitles` |
| `FFMPEG_OUTPUT_DIR` | ffmpeg 组级输出目录 | `ffmpeg__extract_frames_for_vision` |

#### runprompt 生成类

| 环境变量 | 作用 | 兼容回退 |
| --- | --- | --- |
| `RUNPROMPT_MODEL` | LLM 模型名 | `MODEL` |
| `RUNPROMPT_BASE_URL` | API Base URL | `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `BASE_URL` |
| `RUNPROMPT_OPENROUTER_API_KEY` | API Key | `OPENROUTER_API_KEY`, `API_KEY` |
| `RUNPROMPT_DEBUG_PROMPT` | 打印完整渲染提示词并启用 verbose 调试 | 无 |
| `SHELL_AS_MCP_RUNPROMPT_DIAGNOSTIC` | 输出 runprompt 启动诊断信息 | 无 |
| `SHELL_AS_MCP_RUNPROMPT_TIMEOUT_SEC` | runprompt Python 层超时秒数 | `120` |
| `SHELL_AS_MCP_RUNPROMPT_TOOL_ROOT` | runprompt 文件工具根目录 | 通常无需手动设置 |

#### 网络代理类

| 环境变量 | 作用 |
| --- | --- |
| `https_proxy` | 小写 HTTPS 代理环境变量 |
| `HTTPS_PROXY` | 大写 HTTPS 代理环境变量 |

一句话说完：如果你只是正常跑 server，通常只需要 `SHELL_AS_MCP_SPEC_DIR`；如果你要落地文件输出，再加 `SHELL_AS_MCP_OUTPUT_DIR` 或组级目录变量；如果你要用 `runprompt__generate_artifact`，再补齐 `RUNPROMPT_*`。

**`runprompt__generate_artifact` 环境变量（⚠️ 自动生成功能开发中）：**

| 变量 | 说明 | 兼容回退 |
| --- | --- | --- |
| `RUNPROMPT_MODEL` | LLM 模型名 | `MODEL` |
| `RUNPROMPT_BASE_URL` | API Base URL | `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `BASE_URL` |
| `RUNPROMPT_OPENROUTER_API_KEY` | API Key | `OPENROUTER_API_KEY`, `API_KEY` |

调试提示词：设置 `RUNPROMPT_DEBUG_PROMPT=1` 可在请求前打印完整渲染提示词并启用 `runprompt -v`。

---

## 6) 测试 & Lint

```bash
# 单元测试
npm test

# 运行 smoke tests（generic + current-target）
bash scripts/run_smoke_tests.sh

# 一键执行 build + pack + 严格协议握手冒烟
make regress-pack-smoke

# Lint（YAML 规范 + shellcheck + prompt 格式，全量扫描 shell_as_mcp_defs/）
bash scripts/lint/lint_all.sh
```

`lint_all.sh` 分四类自动发现并校验：

- `spec_yaml/*.yaml` → `validate_shell_as_mcp_yaml.sh`（结构/字段/禁止模式）
- `scripts/*.sh` → `validate_script.sh`（shellcheck）
- `prompts/*.prompt`（非 `_` 开头） → `validate_runprompt_prompt.sh`（frontmatter/schema）
- `spec_yaml/*.yaml`（含 `support: tested`）→ `validate_tested_has_smoke_test.sh`（校验对应 per-target smoke test 是否存在）

`run_smoke_tests.sh` 会先跑各 bundle 通用 smoke test（`*__smoke_test.sh`），再自动发现并执行当前平台匹配的 per-target smoke test（如 `*__smoke_test__darwin_arm64.sh`）。

`make regress-pack-smoke` 会执行 build、npm pack、以 tarball 启动 streamable-http 服务，并按严格握手顺序校验 `initialize`、`notifications/initialized`、`tools/list`。

单文件校验：

```bash
bash scripts/lint/validate_shell_as_mcp_yaml.sh shell_as_mcp_defs/brew/spec_yaml/brew__info.yaml
bash scripts/lint/validate_script.sh shell_as_mcp_defs/brew/scripts/brew__info.sh
bash scripts/lint/validate_tested_has_smoke_test.sh shell_as_mcp_defs/brew/spec_yaml/brew__info.yaml
```
