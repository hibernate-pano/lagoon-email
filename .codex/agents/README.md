# Lagoon 专家团使用说明

项目级自定义 agent（project-scoped，Codex 官方格式：`.codex/agents/*.toml`）。
凡是在本仓库开 Codex 会话，直接点名即可调度；跨项目不生效。

| agent | 名字 | 职责 | 何时点名 |
|---|---|---|---|
| `lagoon_lead` | 齐活林（主理人） | 并行调度四条线 → 三级独立确认 → 交叉核验 → verdict 表 | 全面体检、发版前评审、任何要多维度交叉确认的决策 |
| `lagoon_pm` | 许清楚（产品） | 宪法否决权、需求取舍、竞品对标 | 新功能评审、宪法边界判定、想法太大要砍 |
| `lagoon_architect` | 高见远（架构） | 同步只读、schema、外键、布局权威、契约 | 架构评审、疑难根因、跨层契约判定 |
| `lagoon_engineer` | 寇豆码（工程） | 最小改动实现、回归测试、守卫脚本 | 功能实现、缺陷修复、测试补齐 |
| `lagoon_qa` | 严过关（QA） | 降级路径、闸门真实性、变异验证 | 发版前质检、fallback 覆盖审计 |

## 常用调度句式

- 全面体检：`让 lagoon_lead 带队，对当前工作区做一次深入体检（参考 2026-10-05 那次的阵型和输出格式），报告落盘到仓库根目录`
- 发版前评审：`让 lagoon_lead 带队评审 main @ HEAD 是否可交付，verdict 表先行`
- 新功能：`先让 lagoon_pm 判需求（做/不做/改做），过了再让 lagoon_architect 定结构，最后 lagoon_engineer 实现`
- 修缺陷：`lagoon_engineer 修，修完 lagoon_qa 做变异验证`
- 单点咨询：`让 lagoon_architect 看一下这个设计是否违反单一几何权威`（只读线默认 `sandbox_mode = read-only`，只有 lead 和 engineer 可写）

## 规则

- 主理人工作流强制：并行独立评审 → 三级确认（P0/P1 须第二人独立复现 + 主理人逐行核验）→ 交叉核验 → verdict 表。不要省步骤，不要临时换阵型（2026-10-05 已证明这套阵型有效）。
- 交付硬门槛永远是 `bash scripts/run-all-tests.sh` → `ALL CHECKS PASSED`，不是裸 `swift test`。
- 评审报告落盘到仓库根目录 `*.md` 才算完成（本项目交付惯例）。
- 中文回复，输出说重点。
