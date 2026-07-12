#!/bin/bash
# ============================================================
# 聊天室项目 —— 一键全量自动化测试脚本
# ============================================================
#
# 用法：
#   ./run_tests.sh              # 运行全部测试
#   ./run_tests.sh --quick      # 仅快速测试（跳过 E2E）
#   ./run_tests.sh --e2e        # 仅 E2E 测试
#   ./run_tests.sh --db         # 仅数据库测试
#   ./run_tests.sh --verbose    # 详细输出
#
# ============================================================

set -e

cd "$(dirname "$0")"
PYTEST=".venv/bin/python -m pytest"

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

case "$MODE" in
    --quick)
        echo -e "${YELLOW}[模式] 快速测试（跳过 E2E）${NC}"
        echo ""
        
        echo -e "${CYAN}--- 1/3 协议层单元测试 (protocol.py) ---${NC}"
        $PYTEST tests/test_protocol.py -v --tb=short 2>&1 | tail -20
        echo ""
        
        echo -e "${CYAN}--- 2/3 数据库层单元测试 (database.py) ---${NC}"
        $PYTEST tests/test_database.py -v --tb=short 2>&1 | tail -40
        echo ""
        
        echo -e "${CYAN}--- 3/3 服务端集成测试 + 客户端逻辑 ---${NC}"
        $PYTEST tests/test_server.py tests/test_client_logic.py -v --tb=short 2>&1 | tail -40
        echo ""
        ;;
    
    --e2e)
        echo -e "${YELLOW}[模式] 仅 E2E 端到端测试${NC}"
        echo ""
        $PYTEST tests/test_e2e.py -v -m e2e --tb=short
        ;;
    
    --db)
        echo -e "${YELLOW}[模式] 仅数据库测试${NC}"
        $PYTEST tests/test_database.py -v --tb=short
        ;;
    
    --verbose)
        echo -e "${YELLOW}[模式] 全部测试（详细输出）${NC}"
        $PYTEST tests/ -v --tb=long -s
        ;;
    
    --all|*)
        echo -e "${YELLOW}[模式] 全部 157 个测试${NC}"
        echo -e "${YELLOW}       分层: 协议(15) + 数据库(37) + 客户端逻辑(19) + 服务端(22) + E2E(4) + 历史(20) + 验证(33) + 集成(7)${NC}"
        echo ""
        
        $PYTEST tests/ -v --tb=short 2>&1
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
