---
name: guardrail-raw-string-tokenizer-desync
description: ci-guardrails.sh 的 Swift tokenizer 不认 #"..."#，正则里的内部引号会错位吞代码产生假阳性；修它时注意 heredoc 里单数引号会炸 bash 解析
type: gotcha
---

# guardrail 的 raw string 错位：假阳性 `sql-interpolation-concat`，且修脚本本身有个引号坑

**What happened.** 给 `UnsubscribeScanner` 写 `#"https?://[^\s<>"']+"#` 后 CI 报
`Sources/.../UnsubscribeScanner.swift:94: sql-interpolation-concat` —— 那行既没有 SQL 也没有
拼接。根因：`ci-guardrails.sh` 的 Perl tokenizer 只认 `"""` 和 `"`，把 `#"..."#` 当普通引号，
在正则字符类的**内部 `"`** 处开/闭字符串，token 流从此错位，一路吞掉后续代码直到下一个 `"`；
吞进去的 `seen.insert(...)` 命中 `\bINSERT\b` → 假阳性（行号=raw string 起始行）。README 声称
"raw string 已支持"，实际旧代码只是**碰巧**能抓 `#"SELECT ... \#(id)"#` 夹具（内容恰在前两个
引号之间）。

**修复**（已落盘）：tokenizer 增加 `(\#+)"` 分支，按 `"` + 同数量 `#`（且后跟非 `#`）定界，
`\x` 转义成对跳过但保留字符（保证 `\#(` 仍命中 `$INTERP`）。`bash scripts/test-guardrails.sh`
24 夹具仍全过——改这个脚本必须跑它。

**How to apply.**
- 在该脚本 `<<'PERL' ... PERL` heredoc（位于 `"$( )"` 内）里写注释/代码时，**单引号必须成对**：
  `[^"']` 这种单个 `'` 会让 `bash -n` 报 "unexpected EOF while looking for matching `''"——
  bash 对这段 body 做引号态扫描，配不平就找不到 `PERL` 终结符。双引号不受此限（基线里就有
  奇数个 `"`）。排查手法：`git stash` 对比 `bash -n`，再按插入行二分。
- Swift 测试里出现 `sql-interpolation-concat` 却找不到 SQL 时，先看该行附近有没有
  `#"..."#` 且**内部含引号**的正则——大概率是 tokenizer 错位而非真违规。

**Related.** [[one-huge-literal-breaks-the-whole-test-bundle]] —— 同属"测试/CI 基础设施静默
出错"家族。
