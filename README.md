# Todolist.app

[![Release](https://img.shields.io/github/v/release/Sad-Bee666/Todolist?display_name=tag&sort=semver)](https://github.com/Sad-Bee666/Todolist/releases)
[![License](https://img.shields.io/github/license/Sad-Bee666/Todolist)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://github.com/Sad-Bee666/Todolist)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange)](https://swift.org)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](https://github.com/Sad-Bee666/Todolist)

菜单栏常驻的原生 macOS 待办应用。事项以「截止时间 + 事项」呈现，支持手写填入、截图 OCR 提取、以及模型解析自然语言写入。

<img src="docs/screenshots/panel.png" width="380" alt="菜单栏面板">

MIT License · 无第三方依赖 · 纯 Swift / AppKit + SwiftUI

## 安装

从 [Releases](https://github.com/Sad-Bee666/Todolist/releases) 下载 `Todolist-x.y.z.dmg`，打开后把 Todolist 拖进 Applications。

## 从源码构建

```bash
./scripts/setup-signing.sh   # 一次性：创建本地 code signing 证书（见下）
./build.sh                   # 产出 dist/Todolist.app（有证书就用证书签名）
./install.sh                 # 复制到 /Applications 并启动（不可写时退回 ~/Applications）
./package.sh                 # 产出 dist/Todolist-x.y.z.dmg
```

### 为什么需要本地签名证书

ad-hoc 签名（`codesign -s -`）的 designated requirement 只有 `cdhash H"…"`，**每次重新构建 cdhash 都会变**，TCC 里已授予的「屏幕录制」权限随即匹配不上，表现为「明明勾了还是反复申请」。用一张固定的自签证书签名后，requirement 变成 `identifier "com.sad-bee666.todolist" and certificate root = H"…"`，重新构建不再失效。

`scripts/setup-signing.sh` 会在登录钥匙串里生成一张仅用于 code signing 的自签证书（`Todolist Local Signing`）并加入用户信任。它是一条**代码签名信任锚**：谁拿到这把私钥，就能签出你这台 Mac 信任的程序。不需要时可彻底移除：

```bash
security find-identity -v -p codesigning | grep "Todolist Local Signing"
security delete-identity -c "Todolist Local Signing"          # 删身份
security remove-trusted-cert -d <导出的 cert.pem>              # 撤销信任（需导出证书）
```

推送 `v*` 形式的 tag 会触发 GitHub Actions 自动构建并上传 DMG 到 Release。

- 需要 macOS 14+。
- 工具链只依赖 Xcode Command Line Tools。构建脚本显式传入 `-sdk` 与 `-module-cache-path`（沙箱环境下模块缓存必须落在项目内）。
- 应用是 `LSUIElement`（无 Dock 图标、无菜单栏主菜单），启动后只看右上角图标。

## 用法

| 操作 | 行为 |
| --- | --- |
| 鼠标移到菜单栏图标 | 自动展开面板（设置里可关） |
| 移开鼠标 | 未钉住时自动收起 |
| 点一下图标 | 钉住面板，方便输入 |
| 点面板外 / Esc | 收起 |
| 底部输入框回车 | 手写填入，**添加时自动解析**出事项与截止时间后写入（无需额外按钮） |
| ⌃⌥T / 「截图识别」 | 框选屏幕区域 → 本机 Vision 取字 → 自动解析 → 写入 |
| 「截图识别」右侧的模型菜单 | 列出**当前 API 配置**多选保留的模型，挑一个即刻调用 |
| 同一位置（未配置 Key 时） | 显示「配置模型」按钮，点开直接进设置去填 Key |
| 同一行的开关 | 「用 API 模型」：开=远端模型解析，关=本地规则解析；没填 Key 时标签会标「· 缺 Key」并仍走本地规则 |
| 「⋯」 | 清除已完成 / 打开数据文件夹 / 退出 |

列表排序：未完成按截止时间升序，无截止时间的置底；已完成沉底。过期项整体标红。

## AI 接口

OpenAI 兼容协议（`POST <Base URL>/chat/completions`），三档预设：

| 预设 | Base URL | 模型 |
| --- | --- | --- |
| DeepSeek（默认） | `https://api.deepseek.com/v1` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| 自定义 | 自填 | 自填 |

- Key 存在 `~/Library/Application Support/Todolist/secrets/api-key-<provider>.key`，权限 0600，按预设分开存放。刻意不用钥匙串：ad-hoc 签名的应用每次重建签名都会变，会反复弹授权框。
- **支持多份 API 配置**：设置 → 「API 管理」页左侧是所有配置，右侧是选中那条的编辑器（名称 / 提供商 / Base URL / 调用模型 / Key）。每份配置独立保存 Key（`secrets/api-key-<配置id>.key`），点「设为当前」决定面板与解析用哪一份；最后一 cannot 删除（至少保留一份）。
- 旧版单配置（`settings.json` 里的 `ai` 字段）会自动迁移成一份配置，原来的 provider 级 Key 也会搬到新账户上，只搬一次。
- 单份配置的字段顺序：Base URL → 模型提供商 → 调用模型。点「保存并测试」会请求 `GET <Base URL>/models`：既验证连通性，也把接口返回的模型列出来让你**多选**；勾选的模型保留成列表，之后在面板上挑一个实际调用。若接口不提供 `/models`，会退回一次对话探测并保留手填的模型名。
- 配置里 `models` 是多选列表、`model` 是当前调用项；旧版配置文件（只有单个 `model`）会被自动迁移成 `models: [model]`，当前模型若不在列表里也会自动补进去。
- Key 只从剪贴板读入：点「粘贴」把剪贴板内容填进输入框；打开设置页时若输入框为空、剪贴板里像 Key（单行、长度合理），会自动填入等你确认。
- **没有 Key 也能用**：自动降级为本地规则解析器（`MockAIService`），识别中文数字（「十点」「一点半」）、时间段（「上午九点到十点」取开始时刻）、相对日期（「明天」「下周三」「6月1日」），并把时间词从标题里剥干净。面板右下角圆点显示当前引擎（绿=远端模型，橙=本地规则）。
- 提示词在 `Sources/AIPrompts.swift`，注入了当前日期时间、时区与星期，用于把相对时间换算成绝对时间；输出契约为严格 JSON。
- 手写填入与截图识别共用同一条抽取管线，提交即解析；解析不出结构时，截图文字会回填到输入框供你改。

## 权限

⌃⌥T 走系统自带的 `/usr/sbin/screencapture`，需要**屏幕录制**授权，而且这份授权必须由应用自己发起申请——由子进程代为截屏时 TCC 会直接返回 denied 且不弹窗（日志里表现为 `does not allow prompting`）。

- 首次按 ⌃⌥T（或设置页点「请求权限」）会调起系统授权框；允许后**重开应用**生效
- 也可到 系统设置 → 隐私与安全性 → 屏幕录制 手动勾选 Todolist
- ad-hoc 签名每次重新构建都会变，授权会失效，需要重新勾选；只想改配置不想重授权就别重构建
- 免权限兜底：按 **⇧⌘4** 用系统截图，然后在面板「⋯」或设置页点「导入最近截图」，应用会读桌面最新截图走同一条 OCR + 解析管线
- 全局快捷键用 Carbon `RegisterEventHotKey`，不需要辅助功能权限
- **授权必须重开应用才生效**：勾选后仍然截到空白图，基本就是进程还是授权前启动的那一个
- 自检：`open -a /Applications/Todolist.app --args --self-test`，结果写入 `~/Library/Application Support/Todolist/selftest.txt`（报告截图尺寸、是否空白图、识别字数）

## 数据

`~/Library/Application Support/Todolist/todos.json`（原子写，损坏时自动另存 `.corrupt.json` 并重建）与同目录 `settings.json`。
调试可用环境变量 `TODOLIST_HOME` 覆盖数据目录。

## 代码结构

```
Sources/
  Models.swift            数据模型、AI 配置、AIServicing / OCRServicing 契约
  Store.swift             TodoStore / SettingsStore（JSON 持久化）
  Secrets.swift           API Key 存储（钥匙串 + 文件兜底）
  AppController.swift     装配、抽取管线、菜单栏与设置窗生命周期
  StatusItemController.swift  NSStatusItem + NSPopover + 悬停/钉住逻辑
  TodoPanelView.swift     下拉面板（SwiftUI）
  SettingsView.swift      设置窗（SwiftUI）
  OCRService.swift        screencapture + Vision
  HotKeyManager.swift     Carbon 全局快捷键
  AIClient.swift          OpenAI 兼容客户端 + 本地规则解析器
  AIPrompts.swift         提示词与 JSON 输出契约
  IMPort.swift            QQ / 微信预留接口（无实现）
  main.swift              入口
```

## 已验证

`docs/screenshots/` 下的截图是验收证据：

| 文件 | 内容 |
| --- | --- |
| `panel.png` | 面板全态（已配置 Key：模型菜单） |
| `panel-nokey.png` | 未配置 Key 时的面板（模型菜单位置换成「配置模型」按钮） |
| `panel-empty.png` | 空列表态 |
| `settings.png` | 设置窗「通用」页（快捷键 / 截图权限 / 行为） |
| `api-profiles.png` | 设置窗「API 管理」页（多份配置列表 + 编辑器） |
| `model-chooser.png` | 保存 Key 后弹出的可用模型多选框（全选/清空/完成） |

行为与链路验证：悬停开/合（真实光标移动，`[panel] open pinned=false` → `close`）、快捷键 `RegisterEventHotKey` 返回 true、本地假模型服务器上的真实 HTTP 往返（请求头/模型名/提示词注入日期均核对）、todos.json 落盘回读、错误分支（不可达地址 / 空 Key / 非 JSON），以及用真实系统截图跑通 `ScreenOCRService.recognizeText`。

未做端到端运行的部分：`screencapture -i` 的交互框选需要真人拖拽与首次「屏幕录制」授权。

## License

MIT，见 [LICENSE](LICENSE)。

## 预留的 IM 接入点

本版本**只留接口，不含收发功能**：

- `IMChannel`（`.qq` / `.wechat`）、`IMInboundMessage`、`IMOutboundMessage`
- `protocol IMBridge`：`channel` / `isRunning` / `onMessage` / `start()` / `stop()` / `send(_:)`
- `QQBridge`、`WeChatBridge`：占位实现，调用即抛 `.notConfigured`
- `IMBridgeRegistry`：通道注册表，`AppController.init` 已注册两个占位 bridge
- `protocol TodoIngest`：`AppController` 已实现，IM 文本可直接走与截图/粘贴完全相同的抽取管线

接入时只需实现 `IMBridge` 的三个方法，把 `onMessage` 接到 `(IMBridgeRegistry 持有者).ingest(text:source:)`。
