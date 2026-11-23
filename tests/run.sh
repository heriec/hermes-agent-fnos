#!/bin/bash
# 跑全部测试：bash tests/run.sh
set -u
cd "$(dirname "$0")/.." || exit 1

fails=0
for t in tests/test_*.sh; do
    echo "── $t"
    if bash "$t"; then :; else fails=$((fails + 1)); fi
    echo
done

if [ "$fails" = 0 ]; then
    echo "全部通过"
else
    echo "$fails 个测试文件失败"
fi
[ "$fails" = 0 ]