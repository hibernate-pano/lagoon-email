---
name: one-huge-literal-breaks-the-whole-test-bundle
description: Data(多个字符串字面量拼接) 会拖垮类型检查器，报错在测试文件里却让整个 LagoonServerTests bundle 编不过，289 个服务端测试静默无法运行
type: gotcha
---

# 一个过大的字面量拼接能让整包测试无法编译

**What happened.** `Tests/LagoonServerTests/MIMEParserTests.swift:97` 把六个字符串字面量用 `+` 拼起来再包进 `Data(...)`：

```swift
let unterminated = Data(
    ("Content-Type: ...\r\n" + "\r\n" + "--b\r\n" + "Content-Type: ...\r\n" + "\r\n" + "部分正文").utf8
)
```

编译器报 `the compiler is unable to type-check this expression in reasonable time`。后果不是「一个测试挂了」，
而是**整个 `LagoonServerTests` target 编译失败** → `swift test` 直接 exit 1，289 个服务端测试一个都没跑。
README 里「373 条测试全绿」的说法因此在某个时点之后就不再为真，却没人发现——因为本地常用
`swift build --target Lagoon`（只建 app）验证，不建测试。

**Why.** Swift 的类型检查器对「大量字面量参与的、需要推导泛型的链式表达式」是指数级搜索；
`Data.init` 有多个重载，`+` 拼接又嵌套在 argument 位置，推导爆炸只与表达式形状有关，与代码是否正确无关。

**How to apply.**
- 测试里拼多段长文本时，先 `let raw = "..." + "..."` 落到一个有明确类型的局部变量，再 `Data(raw.utf8)`。
  拆一层就能把类型检查从「推导整个表达式」降为「推导一个字面量」。
- 验证命令要用 `swift build --build-tests`（或 `bash scripts/run-all-tests.sh`），不要只用 `swift build --target Lagoon`：
  否则一个测试文件的编译失败会完全不可见。
- 「N 条测试全绿」这类写在 README 里的数字要能一键复现，否则它迟早变成过期断言。

**Related.** —
