#!/usr/bin/env bash
# ==============================================================================
# aiproxy-box 深度自动化测试套件
# ==============================================================================

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=========================================="
echo "开始运行 aiproxy-box 自动化测试套件..."
echo "=========================================="

# Test 1: CLI help command
echo "[Test 1] 测试 aiproxy.sh help 指令..."
output=$(bash aiproxy.sh help)
if echo "$output" | grep -q "aiproxy-box CLI 命令行调用说明"; then
    echo "✓ Test 1 通过: help 输出符合预期"
else
    echo "✗ Test 1 失败: help 输出异常"
    exit 1
fi

# Setup isolated test directory
rm -rf test_env
mkdir -p test_env/templates test_env/data
cp templates/* test_env/templates/
cp aiproxy.sh test_env/

# Test 2: Source and test env and init
echo "[Test 2] 测试 init_service_configs 与模版复制..."
(
    cd test_env
    source aiproxy.sh
    init_service_configs
    if [ -f "data/grok2api/config.yaml" ] && [ -f "data/cliproxy/config.yaml" ] && [ -f "data/workbuddy/config.json" ]; then
        echo "✓ 配置文件复制成功"
    else
        echo "✗ 配置文件未正确复制"
        exit 1
    fi

    # Check secret replacement in grok2api.yaml
    if grep -q "CHANGE_ME_JWT_SECRET_32_HEX_CHARACTERS" data/grok2api/config.yaml; then
        echo "✗ Grok2API secret 未能正确替换"
        exit 1
    else
        echo "✓ Grok2API 随机密钥注入成功"
    fi
)
echo "✓ Test 2 通过"

# Test 3: Test Dynamic Compose Generation (Full 4 services)
echo "[Test 3] 测试全量 4 服务动态 Compose 生成..."
(
    cd test_env
    source aiproxy.sh
    export BIND_IP="127.0.0.1"
    export ENABLED_SERVICES="newapi,grok2api,cliproxy,workbuddy"
    generate_compose
    if [ -f "docker-compose.yml" ]; then
        echo "✓ docker-compose.yml 已生成"
    else
        echo "✗ docker-compose.yml 生成失败"
        exit 1
    fi

    # Verify services in compose
    for s in "new-api" "grok2api" "cli-proxy-api" "workbuddy2api" "aiproxy-net" 'max-size: "20m"'; do
        if grep -q "$s" docker-compose.yml; then
            echo "✓ 包含关键配置项: $s"
        else
            echo "✗ 缺失关键配置项: $s"
            exit 1
        fi
    done
)
echo "✓ Test 3 通过"

# Test 4: PyYAML validation on generated docker-compose.yml
echo "[Test 4] 校验生成的 Compose 文件 YAML 语法合法性..."
PYTHONIOENCODING=utf-8 python -c "
import yaml
with open('test_env/docker-compose.yml', 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert 'services' in data, 'Missing services in YAML'
assert 'networks' in data, 'Missing networks in YAML'
assert 'new-api' in data['services'], 'Missing new-api service'
assert 'grok2api' in data['services'], 'Missing grok2api service'
assert 'cli-proxy-api' in data['services'], 'Missing cli-proxy-api service'
assert 'workbuddy2api' in data['services'], 'Missing workbuddy2api service'
print('[OK] PyYAML validated')
"
echo "✓ Test 4 通过"

# Test 5: Test Low-Memory hardware detection & limit injection
echo "[Test 5] 测试低内存 VPS (1024MB) 自适应注入 mem_limit 资源限制..."
(
    cd test_env
    source aiproxy.sh
    # Mock low memory
    get_ram_info() {
        echo "1024 256"
    }
    export ENABLED_SERVICES="newapi,grok2api,cliproxy,workbuddy"
    generate_compose

    # Verify memory limits injected
    if grep -q "memory: 350M" docker-compose.yml && \
       grep -q "memory: 250M" docker-compose.yml && \
       grep -q "memory: 200M" docker-compose.yml; then
        echo "✓ 低内存环境下成功注入各组件资源上限 (350M/250M/200M)"
    else
        echo "✗ 未能成功注入资源限制"
        exit 1
    fi
)
# Validate low-spec YAML syntax with PyYAML
PYTHONIOENCODING=utf-8 python -c "
import yaml
with open('test_env/docker-compose.yml', 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f)
assert 'deploy' in data['services']['new-api'], 'Missing deploy block in new-api'
assert data['services']['new-api']['deploy']['resources']['limits']['memory'] == '350M'
assert data['services']['workbuddy2api']['deploy']['resources']['limits']['memory'] == '200M'
print('[OK] Low spec PyYAML validated')
"
echo "✓ Test 5 通过"

# Test 6: Test partial services custom compose
echo "[Test 6] 测试部分服务定制 Compose 生成 (只选 newapi 与 grok2api)..."
(
    cd test_env
    source aiproxy.sh
    export ENABLED_SERVICES="newapi,grok2api"
    generate_compose

    if grep -q "new-api" docker-compose.yml && grep -q "grok2api" docker-compose.yml; then
        echo "✓ 包含已启用服务"
    else
        echo "✗ 缺失已启用服务"
        exit 1
    fi

    if grep -q "cli-proxy-api" docker-compose.yml || grep -q "workbuddy2api" docker-compose.yml; then
        echo "✗ 包含未启用服务"
        exit 1
    else
        echo "✓ 正确排除了未启用服务"
    fi
)
echo "✓ Test 6 通过"

# Test 7: Test toggle_service logic
echo "[Test 7] 测试 toggle_service 逻辑..."
(
    cd test_env
    source aiproxy.sh
    ENABLED_SERVICES="newapi,grok2api"
    save_env

    # Toggle cliproxy ON
    toggle_service "cliproxy"
    if is_service_enabled "cliproxy"; then
        echo "✓ toggle cliproxy 启用成功"
    else
        echo "✗ toggle cliproxy 启用失败"
        exit 1
    fi

    # Toggle newapi OFF
    toggle_service "newapi"
    if is_service_enabled "newapi"; then
        echo "✗ toggle newapi 禁用失败"
        exit 1
    else
        echo "✓ toggle newapi 禁用成功"
    fi
)
echo "✓ Test 7 通过"

# Test 8: Test BIND_IP switching
echo "[Test 8] 测试 BIND_IP 切换 (0.0.0.0 公网模式)..."
(
    cd test_env
    source aiproxy.sh
    BIND_IP="0.0.0.0"
    save_env
    generate_compose
    if grep -q '\${BIND_IP:-127.0.0.1}' docker-compose.yml && grep -q 'BIND_IP=0.0.0.0' .env; then
        echo "✓ BIND_IP 变量与映射规则生效"
    else
        echo "✗ BIND_IP 未能生效"
        exit 1
    fi
)
echo "✓ Test 8 通过"

# Test 9: Test install.sh bash syntax and structure
echo "[Test 9] 测试 install.sh 结构完整性..."
if grep -q "INSTALL_DIR=\"/opt/aiproxy-box\"" install.sh && grep -q "ln -sf" install.sh; then
    echo "✓ install.sh 路径与软链接逻辑正确"
else
    echo "✗ install.sh 逻辑不完整"
    exit 1
fi
echo "✓ Test 9 通过"

# Test 10: Verify Grok2API 32-byte AES key and JWT hex lengths
echo "[Test 10] 深度校验 Grok2API 32 字节 AES 密钥与 JWT 密钥长度..."
(
    cd test_env
    source aiproxy.sh
    hex_key=$(generate_random_hex 32)
    b64_key=$(generate_random_base64 32)
    echo "  Hex Key: $hex_key (长度: ${#hex_key})"
    echo "  Base64 Key: $b64_key (长度: ${#b64_key})"

    if [ "${#hex_key}" -eq 64 ] && [ "${#b64_key}" -eq 44 ]; then
        echo "✓ 密钥字节数与字符长度完全符合 256 位安全标准 (Hex 64字符 / Base64 44字符)"
    else
        echo "✗ 密钥长度不符合 32 字节标准: hex=${#hex_key}, b64=${#b64_key}"
        exit 1
    fi

    # Verify python can decode base64 into exactly 32 raw bytes (AES-256 requirement)
    python -c "
import base64
raw = base64.b64decode('$b64_key')
assert len(raw) == 32, f'Decoded bytes length is {len(raw)}, expected 32'
print('[OK] AES-256 32-byte key decodable')
"
)
echo "✓ Test 10 通过"

# Test 11: Test Port validation logic
echo "[Test 11] 测试端口校验与防冲突逻辑..."
(
    cd test_env
    source aiproxy.sh
    is_valid_port 80 && is_valid_port 65535 || { echo "✗ 有效端口被误判"; exit 1; }
    ! is_valid_port 0 && ! is_valid_port 65536 && ! is_valid_port "abc" || { echo "✗ 无效端口未被拦截"; exit 1; }
    echo "✓ 端口格式校验规则符合预期"
)
echo "✓ Test 11 通过"

# Test 12: Test pure toggle_service_list staging memory logic
echo "[Test 12] 测试纯内存组件切换逻辑 (toggle_service_list)..."
(
    cd test_env
    source aiproxy.sh
    initial="newapi,grok2api"
    res1=$(toggle_service_list "cliproxy" "$initial")
    if [ "$res1" = "newapi,grok2api,cliproxy" ]; then
        echo "✓ 纯内存加装组件成功: $res1"
    else
        echo "✗ 加装组件失败: $res1"
        exit 1
    fi

    res2=$(toggle_service_list "newapi" "$res1")
    if [ "$res2" = "grok2api,cliproxy" ]; then
        echo "✓ 纯内存卸载组件成功: $res2"
    else
        echo "✗ 卸载组件失败: $res2"
        exit 1
    fi
)
echo "✓ Test 12 通过"

# Test 13: Test CLI init and ensure_initialized
echo "[Test 13] 测试 CLI init 与 ensure_initialized 自动就绪..."
(
    rm -rf test_env_init
    mkdir -p test_env_init/templates
    cp templates/* test_env_init/templates/
    cp aiproxy.sh test_env_init/
    cd test_env_init
    bash aiproxy.sh init
    if [ -f ".env" ] && [ -f "docker-compose.yml" ] && [ -f "data/grok2api/config.yaml" ]; then
        echo "✓ aiproxy init 成功初始化全部环境配置与 Compose 编排"
    else
        echo "✗ aiproxy init 初始化失败"
        exit 1
    fi
    cd ..
    rm -rf test_env_init
)
echo "✓ Test 13 通过"

# Test 14: Check LF line endings on all repository shell scripts
echo "[Test 14] 校验所有 Shell 脚本 LF 换行符合规性..."
for f in aiproxy.sh install.sh test_aiproxy.sh; do
    if grep -q $'\r' "$f"; then
        echo "✗ 文件 $f 包含 Windows CRLF 换行符！"
        exit 1
    else
        echo "✓ $f 换行符为纯 LF (UNIX)"
    fi
done
echo "✓ Test 14 通过"

# Clean test_env
rm -rf test_env

echo "=========================================="
echo "🎉 全部 14 项自动化深度测试（含 PyYAML 结构与密码学字节级校验）全部通过！"
echo "=========================================="
