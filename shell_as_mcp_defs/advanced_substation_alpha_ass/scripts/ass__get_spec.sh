#!/usr/bin/env bash
set -euo pipefail

TOOL_SECTION="${TOOL_SECTION:-all}"

VALID_SECTIONS="all script_info v4_styles events tags colors example"
is_valid=0
for s in $VALID_SECTIONS; do
  if [[ "$TOOL_SECTION" == "$s" ]]; then
    is_valid=1
    break
  fi
done

if [[ "$is_valid" -eq 0 ]]; then
  echo "Error: invalid section '${TOOL_SECTION}'. Allowed: ${VALID_SECTIONS}" >&2
  exit 1
fi

print_script_info() {
  cat <<'EOF'
### [Script Info] 区块（全局设置）

此区块定义了字幕与视频匹配的基本环境。

- **Title**: 字幕的标题（任意文本）。
- **ScriptType**: 必须是 `v4.00+`，代表这是 ASS 格式。
- **WrapStyle**: 换行模式。通常设为 `0`（智能换行）或 `2`（不自动换行，仅在遇到 `\N` 时换行）。
- **ScaledBorderAndShadow**: 设为 `yes`。确保边框和阴影的大小会随着视频分辨率的缩放而等比缩放。
- **PlayResX / PlayResY**: 非常重要！定义字幕的虚拟分辨率（例如 `PlayResX: 1920`, `PlayResY: 1080`）。
  所有的字体大小（Fontsize）和绝对坐标（\pos）都是基于这个分辨率计算的。
  建议与目标视频分辨率保持一致。
EOF
}

print_v4_styles() {
  cat <<'EOF'
### [V4+ Styles] 区块（样式表）

在这里定义好样式后，可以在 [Events] 中直接调用，避免重复写代码。

必须先有一行 Format 声明字段顺序，然后是具体的 Style。

  Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
  Style: Default,Microsoft YaHei,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,50,1

核心参数解析：
- Name: 样式名称（如 Default, Title, Note）。
- Fontname: 字体名称（如 Arial, Microsoft YaHei）。
- Fontsize: 字体大小（基于 PlayResY）。
- PrimaryColour: 主体颜色（见颜色规范）。
- OutlineColour: 描边颜色。
- BackColour: 阴影颜色。
- Bold / Italic: 粗体 / 斜体（0 为关，-1 或 1 为开）。
- Outline / Shadow: 描边宽度 / 阴影深度（像素值）。
- Alignment: 对齐方式（使用小键盘 1-9 布局）。
    1: 左下, 2: 中下, 3: 右下
    4: 左中, 5: 正中, 6: 右中
    7: 左上, 8: 中上, 9: 右上
- MarginL/R/V: 左/右/垂直边距（像素）。
EOF
}

print_events() {
  cat <<'EOF'
### [Events] 区块（字幕事件）

每一行具体的字幕都在这里。同样需要先声明 Format。

  Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
  Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Hello {\c&H0000FF&}World{\c}!

核心参数解析：
- Layer: 图层（整数）。当字幕重叠时，层数大的会覆盖层数小的（默认设为 0 即可）。
- Start / End: 开始和结束时间。格式严格为 H:MM:SS.cs（小时:分钟:秒.百分之一秒）。
  例如 0:01:23.45。
- Style: 引用的 [V4+ Styles] 中的样式名。
- Text: 字幕文本。这里可以使用 {} 包裹的特效标签（Override Tags）。
EOF
}

print_tags() {
  cat <<'EOF'
### 常用行内特效标签（Override Tags）

行内特效标签必须写在花括号 {} 内，作用于它之后的文本。

1. 基础排版
- \N: 强制换行（最常用）。
- \b1 / \b0: 开启/关闭粗体。
- \i1 / \i0: 开启/关闭斜体。
- \fs<数字>: 改变字体大小。例如 {\fs30}。

2. 颜色与透明度
- \c&HBBGGRR& 或 \1c&HBBGGRR&: 改变主体颜色。
- \3c&HBBGGRR&: 改变描边颜色。
- \alpha&HAA&: 改变整体透明度（00 为完全不透明，FF 为完全透明）。

3. 定位与动画
- \an<数字>: 覆盖默认对齐方式（小键盘 1-9）。例如 {\an8} 强制顶部居中。
- \pos(x,y): 绝对定位。将字幕的对齐锚点固定在坐标 (x,y) 处。例如 {\pos(960,100)}。
- \fad(t1,t2): 淡入淡出。t1 为淡入毫秒数，t2 为淡出毫秒数。
  例如 {\fad(500,500)} 表示半秒淡入，半秒淡出。
EOF
}

print_colors() {
  cat <<'EOF'
### ASS 颜色代码规范（特殊注意）

ASS 的颜色代码与网页常用的 RGB HEX 代码不同，它采用的是 AABBGGRR（透明度-蓝-绿-红）格式。

格式: &H[透明度][蓝][绿][红]&
  - 在 [V4+ Styles] 中通常带透明度，如 &H00FFFFFF
  - 在 Text 行内使用 \c 标签时，通常只写 BGR，如 &HFFFFFF&

反向顺序: 网页红色是 #FF0000，但在 ASS 中红色是 &H0000FF&（蓝00，绿00，红FF）。

常用颜色对照表（行内标签格式）：
- 纯白：&HFFFFFF&
- 纯黑：&H000000&
- 纯红：&H0000FF&
- 纯绿：&H00FF00&
- 纯蓝：&HFF0000&
- 黄色：&H00FFFF&  (蓝00，绿FF，红FF)
- 青色：&HFFFF00&
EOF
}

print_example() {
  cat <<'EOF'
### 案例

[Script Info]
Title: 单词标注富文本测试
ScriptType: v4.00+
WrapStyle: 0
ScaledBorderAndShadow: yes
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,50,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,This is a {\c&H00A5FF&}significant{\fs30\c&H00FFFF&}(adj.重要的){\fs60\c&HFFFFFF&} improvement.
Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,Here is another {\c&H00A5FF&}example{\fs30\c&H00FFFF&}(n.例子){\fs60\c&HFFFFFF&} for you to test.
EOF
}

case "$TOOL_SECTION" in
  all)
    print_script_info
    echo ""
    print_v4_styles
    echo ""
    print_events
    echo ""
    print_tags
    echo ""
    print_colors
    echo ""
    print_example
    ;;
  script_info)
    print_script_info
    ;;
  v4_styles)
    print_v4_styles
    ;;
  events)
    print_events
    ;;
  tags)
    print_tags
    ;;
  colors)
    print_colors
    ;;
  example)
    print_example
    ;;
esac
