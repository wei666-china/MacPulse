#!/bin/bash
#
# MacPulse 出门检查。三件事:本地化三查、编译、测试。
#
# 这个脚本是门禁的**唯一定义**——pre-push 钩子和 GitHub Actions 都只是调它。
# 三处各写一份的下场是漂移:某天在 CI 里加了第四项检查、钩子还停在三项,
# 于是「本地过了」和「CI 过了」不再是同一句话,门禁就开始骗人。
#
# 用法:./Tools/preflight.sh
#
# 环境变量:
#   MACPULSE_LIVE_NETWORK_TESTS=1   额外跑真网络用例(3 条)。结果随当时网速
#                                   浮动,所以默认不跑——偶尔变红的门禁等于没有。
#   MACPULSE_TEST_LOG=<path>        测试日志落点。默认带进程号,两个会话同时
#                                   跑 preflight 时日志不互相截断。
#   MACPULSE_MAX_SKIP=<n>           跳过数超过 n 判失败。真机上跳过一片说明
#                                   传感器读不到了,那是该报警的事;CI 虚拟机
#                                   没硬件,别设或设大。默认不拦只打印。
#
# set -o pipefail 不是可选项:没有它,下面 `swift test | tee` 的退出码取自
# tee(永远是 0),测试全红脚本照样返回成功。假绿灯比没有门禁更坏。
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

LOG="${MACPULSE_TEST_LOG:-/tmp/macpulse-test-$$.log}"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }

step "1/3 本地化三查"
# 放在最前面:文案格式符错位零点几秒就报出来,没道理排在分钟级的编译后面。
# 这类错误编译器不查、测试不覆盖、运行时直接输出乱码,而且乱的是英文界面
# ——你不会天天切到英文去用,所以只有门禁拦得住。
python3 Tools/check-l10n.py
ok "覆盖、格式符、参数个数三项通过"

step "2/3 编译"
# swift test 不会把 MacPulseCollector 编进去(它不是任何测试目标的依赖),
# 单独 build 一次,保证两个可执行目标都真的编得过。
swift build
ok "MacPulse 与 MacPulseCollector 均编译通过"

step "3/3 测试"
swift test 2>&1 | tee "$LOG"
ok "测试通过"

# 跳过统计。
# 真机有 SMC / IOReport / 电池,传感器用例会真的执行,这里通常是 3–8 条:
# 3 条真网络 opt-in 必跳,其余随机器状态浮动(没插电时充电链路用例会跳)。
# 某天突然跳过一大片,不是「测试没写」,是那些传感器**现在读不到了**,
# 那本身就是这个 App 最该报警的一类问题——所以给了 MACPULSE_MAX_SKIP。
# (CI 虚拟机会跳过一片,属正常,但也正因如此,CI 绿灯只代表纯逻辑与
#  编译没问题,不代表传感器验过了。)
skipped=$(grep -c "' skipped" "$LOG" || true)
printf '\n跳过 %s 条' "${skipped:-0}"
if [ "${skipped:-0}" -gt 0 ]; then
    printf ':\n'
    grep "' skipped" "$LOG" | sed -E "s/.*'-\[([^]]*)\]'.*/  - \1/" | sort -u
else
    printf '\n'
fi
if [ -n "${MACPULSE_MAX_SKIP:-}" ] && [ "${skipped:-0}" -gt "$MACPULSE_MAX_SKIP" ]; then
    printf '\033[31m跳过 %s 条,超过阈值 %s——传感器用例在成片失效,先查这个。\033[0m\n' \
        "$skipped" "$MACPULSE_MAX_SKIP"
    exit 1
fi

printf '\n\033[32m出门检查全部通过。\033[0m\n'
