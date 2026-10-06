#!/bin/bash
# ============================================================
# 聊天室项目 —— 一键全量自动化测试脚本
# ============================================================
#
# 用法：
#   ./run_tests.sh              # 运行全部测试（pytest-xdist 并行，约 50s）
#   ./run_tests.sh --quick      # 仅快速测试（跳过 E2E / 异步 / Hypothesis 状态机）
#   ./run_tests.sh --e2e        # 仅 E2E + 异步端到端测试
#   ./run_tests.sh --db         # 仅数据库测试（含扩展）
#   ./run_tests.sh --no-parallel# 串行执行（禁用 xdist，排查隔离问题时使用）
#   ./run_tests.sh --verbose    # 详细输出（串行）
#
# 测试分层（247 个）：
#   协议(15) + 数据库(37) + 客户端逻辑(19) + 服务端(22) + E2E(4)
#   + 历史(20) + 验证(33) + 集成(7)
#   + 数据库扩展(32) + 服务端扩展(31) + Hypothesis(9) + 异步E2E(3) + socket守护(8)
#
# 引入的 pytest 插件：
#   pytest-asyncio  : 异步测试（test_async_e2e.py）
#   pytest-socket   : socket_disabled 守护纯逻辑（test_socket_guard.py）
#   pytest-xdist    : -n auto 并行
#   hypothesis      : 属性 + 状态机（test_hypothesis.py）
# ============================================================

set -e

cd "$(dirname "$0")"

# Python 解释器发现：优先项目 .venv，其次系统 python3（需安装 requirements-dev.txt）
if [ -x ".venv/bin/python" ]; then
    PYTEST=".venv/bin/python -m pytest"
else
    PYTEST="python3 -m pytest"
    if ! python3 -c "import pytest" 2>/dev/null; then
        echo -e "\033[0;31m[错误] 未找到可用的 pytest 环境。\033[0m"
        echo -e "  方式一（推荐）：python3 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt"
        echo -e "  方式二：python3 -m pip install -r requirements.txt -r requirements-dev.txt"
        exit 1
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}     聊天室项目 —— 自动化测试套件${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

MODE="${1:---all}"

# 并行标志：默认并行，--no-parallel / --verbose 关闭
PARALLEL="-n auto"

case "$MODE" in
    --quick)
        echo -e "${YELLOW}[模式] 快速测试（跳过 E2E / 异步 / 状态机）${NC}"
        echo ""
        echo -e "${CYAN}--- 1/3 协议层单元测试 (protocol.py) ---${NC}"
        $PYTEST tests/test_protocol.py tests/test_socket_guard.py -v --tb=short 2>&1 | tail -20
        echo ""
        echo -e "${CYAN}--- 2/3 数据库层单元测试 (database.py + 扩展) ---${NC}"
        $PYTEST tests/test_database.py tests/test_database_ext.py -v --tb=short 2>&1 | tail -40
        echo ""
        echo -e "${CYAN}--- 3/3 服务端集成 + 客户端逻辑 + 验证 ---${NC}"
        $PYTEST tests/test_server.py tests/test_server_ext.py tests/test_client_logic.py tests/test_input_validation.py tests/test_message_history.py tests/test_backend_integration.py -v --tb=short 2>&1 | tail -40
        echo ""
        ;;

    --e2e)
        echo -e "${YELLOW}[模式] E2E + 异步端到端测试${NC}"
        echo ""
        $PYTEST tests/test_e2e.py tests/test_async_e2e.py -v -m e2e --tb=short
        ;;

    --db)
        echo -e "${YELLOW}[模式] 仅数据库测试（含扩展）${NC}"
        $PYTEST tests/test_database.py tests/test_database_ext.py tests/test_message_history.py -v --tb=short
        ;;

    --no-parallel)
        echo -e "${YELLOW}[模式] 全部测试（串行，禁用 xdist）${NC}"
        echo ""
        $PYTEST tests/ -v --tb=short -p no:xdist
        ;;

    --verbose)
        echo -e "${YELLOW}[模式] 全部测试（详细输出，串行）${NC}"
        $PYTEST tests/ -v --tb=long -s -p no:xdist
        ;;

    --all|*)
        echo -e "${YELLOW}[模式] 全部 247 个测试（pytest-xdist 并行）${NC}"
        echo -e "${YELLOW}       插件: pytest-asyncio / pytest-socket / hypothesis / pytest-xdist${NC}"
        echo ""
        $PYTEST tests/ $PARALLEL --tb=short -q 2>&1
        EXIT_CODE=$?
        echo ""
        echo -e "${CYAN}============================================================${NC}"
        if [ $EXIT_CODE -eq 0 ]; then
            echo -e "${GREEN}  ✓ 全部测试通过！${NC}"
        else
            echo -e "${RED}  ✗ 有测试失败，请检查输出${NC}"
        fi
        echo -e "${CYAN}============================================================${NC}"
        exit $EXIT_CODE
        ;;
esac