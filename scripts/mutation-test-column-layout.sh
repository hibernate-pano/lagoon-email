#!/usr/bin/env bash
# 变异测试 —— 验证守卫测试真的会抓错（不是摆设）
#
# 背景：本项目已复发 3 次「测试全绿但行为是错的」。原因是守卫测试只断言了
# 弱不变量（"各栏不越界"），而真正的失败模式（合计溢出、下限被击穿）
# 能顺利通过弱断言。
#
# 本脚本把生产代码改回旧行为/错误行为，确认新守卫**变红**。
# 绿测试证明"没写错"，变红才证明"抓得住"。
#
# 用法：bash scripts/mutation-test-column-layout.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SOLVER=""
for f in $(find Sources -name "*ColumnWidth*" -o -name "*ColumnLayout*" -o -name "*SplitLayout*" 2>/dev/null); do
  SOLVER="$f"
done

if [ -z "$SOLVER" ]; then
  echo "找不到宽度求解器源文件，先让工程师实现后再跑本脚本"
  exit 2
fi

echo "求解器文件: $SOLVER"
BACKUP="/tmp/mutation-$(date +%s).swift"
cp "$SOLVER" "$BACKUP"
restore() { cp "$BACKUP" "$SOLVER"; }
trap restore EXIT

run_tests() {
  swift test --disable-sandbox --filter "ColumnWidth|ColumnLayout" 2>&1 | tail -25
}

echo
echo "=== 变异 1：把加权补偿退化为等分（权重失效）==="
# 预期：权重测试必须变红
sed -i.bak 's|weight\[i\] / sumOfWeights|1.0 / Double(active.count)|g' "$SOLVER" 2>/dev/null
sed -i.bak2 's|\* weight| / Double(active.count)|g' "$SOLVER" 2>/dev/null
run_tests | grep -E "error:|XCTAssert|failed|passed" | head -10
restore

echo
echo "=== 变异 2：去掉合计不变量（允许溢出）==="
# 预期：sum(widths) == totalWidth 的断言必须变红
python3 - "$SOLVER" <<'PYEOF' 2>/dev/null || true
import sys,re
p=sys.argv[1]
s=open(p).read()
# 把最终的按权重分配改成直接返回被拖栏+min，模拟"忘了重分配"
s=s.replace('return widths','widths[0]=max(widths[0],minWidths[0]); return widths',1)
open(p,'w').write(s)
PYEOF
run_tests | grep -E "error:|XCTAssert|failed|passed" | head -10
restore

echo
echo "=== 变异 3：clamp 方向反了（min/max 颠倒）==="
sed -i.bak3 's|min(maxWidths\[i\], |min(minWidths[i], |g' "$SOLVER" 2>/dev/null
run_tests | grep -E "error:|XCTAssert|failed|passed" | head -10
restore

echo
echo "=== 恢复完成，验证工作区干净 ==="
diff -q "$BACKUP" "$SOLVER" && echo "✅ 已还原" || echo "❌ 还原失败！"
rm -f "$SOLVER".bak "$SOLVER".bak2 "$SOLVER".bak3