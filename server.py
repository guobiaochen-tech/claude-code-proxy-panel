#!/usr/bin/env python3
"""本地网页面板 — 检测代理、Claude Code、CC Switch、Hermes 状态"""

import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.request
import urllib.error
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler

HOME = Path.home()
PORT = 8866
TEMPLATE_DIR = Path(__file__).parent / "templates"
SECRETS_FILE = Path(__file__).parent / "secrets.json"
ZSHRC = HOME / ".zshrc"
CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
CCSWITCH_DB = HOME / ".cc-switch" / "cc-switch.db"
HERMES_CONFIG = HOME / ".hermes" / "config.yaml"
VSCODE_SETTINGS = HOME / "Library/Application Support/Code/User/settings.json"
FLCLASH_CONFIG = HOME / "Library/Application Support/com.follow.clash/config.yaml"
CLASH_VERGE_CONFIG = HOME / "Library/Application Support/un.un.clashrev/clash-verge.yaml"
CLASH_VERGE_APP = HOME / "Library/Application Support/un.un.clashrev/verge.yaml"

PROXY_PORTS = [
    7890, 7891, 7892, 7893, 7894,  # Clash 系列
    7895, 7896, 7897, 7898, 7899,  # Clash Verge 系列
    1080, 1081, 1082,               # SOCKS
    8080, 8118, 9090,               # HTTP proxy
    10808, 10809,                    # V2Ray
    2080, 33210, 50001, 60001,      # 其他
]


def _load_secrets():
    try:
        with open(SECRETS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


SECRETS = _load_secrets()


# ── 代理检测 ──────────────────────────────────────────

def _port_alive(port):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except Exception:
        return False


def _get_configured_ports():
    ports = set()
    for key in ("http_proxy", "https_proxy", "ALL_PROXY"):
        val = os.environ.get(key, "")
        m = re.search(r":(\d+)", val)
        if m:
            ports.add(int(m.group(1)))
    if ZSHRC.exists():
        for m in re.finditer(r"export\s+(?:http_proxy|https_proxy|ALL_PROXY)=.*?:(\d+)", ZSHRC.read_text()):
            ports.add(int(m.group(1)))
    return ports


def scan_proxy_ports():
    found = []
    extra = _get_configured_ports()
    
    # 也从代理软件配置中读取端口
    for config_path in [FLCLASH_CONFIG, CLASH_VERGE_CONFIG]:
        if config_path.exists():
            try:
                m = re.search(r'mixed-port:\s*(\d+)', config_path.read_text())
                if m:
                    extra.add(int(m.group(1)))
            except Exception:
                pass
    
    all_ports = sorted(set(PROXY_PORTS) | extra)
    for p in all_ports:
        if _port_alive(p):
            found.append(p)
    return found


def _proc_running(*keywords):
    """检测含任一关键词的进程是否在跑"""
    try:
        out = subprocess.check_output(["ps", "-Ao", "comm="], timeout=3, text=True)
        return any(any(k in ln.lower() for k in keywords) for ln in out.splitlines())
    except Exception:
        return False


def _tun_active():
    """检测是否有 RUNNING 的 utun 网卡(TUN 模式)"""
    try:
        out = subprocess.check_output(["ifconfig"], timeout=3, text=True)
        return bool(re.search(r"^utun\d+.*RUNNING", out, re.MULTILINE))
    except Exception:
        return False


def _yaml_mixed_port(path):
    """从 yaml 配置读 mixed-port"""
    try:
        m = re.search(r"^mixed-port:\s*(\d+)", Path(path).read_text(), re.MULTILINE)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def _yaml_tun_enabled(path):
    """从 yaml 配置读 tun 块里的 enable: true"""
    try:
        text = Path(path).read_text()
        m = re.search(r"^tun:\s*\n((?:[ \t]+.+\n?)+)", text, re.MULTILINE)
        return bool(m and re.search(r"^\s+enable:\s*true", m.group(1), re.MULTILINE))
    except Exception:
        return False


def _scan_listening_ports():
    """全面扫描所有候选端口,返回实际在监听的"""
    found = []
    candidates = set(PROXY_PORTS)
    for p in (_yaml_mixed_port(FLCLASH_CONFIG), _yaml_mixed_port(CLASH_VERGE_CONFIG)):
        if p:
            candidates.add(p)
    for p in sorted(candidates):
        if _port_alive(p):
            found.append(p)
    return found


def detect_current_proxy():
    """核心:当前哪个代理在跑 + TUN/端口模式 + 端口"""
    sources = []
    for app, keys, cfg in (
        ("Clash Verge", ("clash verge", "verge"), CLASH_VERGE_CONFIG),
        ("FlClash", ("flclash",), FLCLASH_CONFIG),
    ):
        port = _yaml_mixed_port(cfg)
        sources.append({
            "app": app,
            "running": _proc_running(*keys),
            "config_port": port,
            "listening": _port_alive(port) if port else False,
            "tun_config": _yaml_tun_enabled(cfg),
        })
    tun_sys = _tun_active()
    # 当前活动软件:优先进程在跑的,其次端口在监听的
    active = next((s for s in sources if s["running"]), None) or \
             next((s for s in sources if s["listening"]), None)
    mode, port, app = "none", None, None
    if active:
        app = active["app"]
        if active["tun_config"] and tun_sys:
            mode = "tun"
        elif active["listening"]:
            mode, port = "port", active["config_port"]
        elif tun_sys:
            mode = "tun"  # 进程在跑且系统有 TUN,默认 TUN
    return {
        "app": app,
        "mode": mode,
        "port": port,
        "tun_active": tun_sys,
        "sources": sources,
        "listening_ports": _scan_listening_ports(),
    }


def detect_proxy():
    """兼容旧调用:基于 detect_current_proxy 返回"""
    cur = detect_current_proxy()
    return {
        "running": cur["mode"] != "none",
        "active_port": cur["port"],
        "listening_ports": cur["listening_ports"],
        "configured_ports": [],
        "app": cur["app"],
        "mode": cur["mode"],
        "tun_active": cur["tun_active"],
        "sources": cur["sources"],
    }


def detect_proxy_sources():
    """检测每个代理软件的端口来源和模式"""
    sources = []

    # ── FlClash ──
    fl_port = None
    if FLCLASH_CONFIG.exists():
        content = FLCLASH_CONFIG.read_text()
        m = re.search(r'mixed-port:\s*(\d+)', content)
        if m:
            fl_port = int(m.group(1))
    sources.append({
        "app": "FlClash",
        "config_port": fl_port,
        "listening": _port_alive(fl_port) if fl_port else False,
        "mode": "proxy",
        "tun_enabled": False,
    })

    # ── Clash Verge ──
    cv_port = None
    cv_tun = False
    if CLASH_VERGE_CONFIG.exists():
        content = CLASH_VERGE_CONFIG.read_text()
        m = re.search(r'mixed-port:\s*(\d+)', content)
        if m:
            cv_port = int(m.group(1))
        # TUN 块可能在后面，匹配 tun: 之后任意位置出现 enable: true
        tun_match = re.search(r'^tun:\s*$', content, re.MULTILINE)
        if tun_match:
            tun_block = content[tun_match.end():]
            # 找到下一个顶级 key（不退格的行）作为 tun 块结束
            end_match = re.search(r'^[a-z]', tun_block, re.MULTILINE)
            if end_match:
                tun_block = tun_block[:end_match.start()]
            if re.search(r'^\s+enable:\s*true', tun_block, re.MULTILINE):
                cv_tun = True
    sources.append({
        "app": "Clash Verge",
        "config_port": cv_port,
        "listening": _port_alive(cv_port) if cv_port else False,
        "mode": "tun" if cv_tun else "proxy",
        "tun_enabled": cv_tun,
    })

    # ── lsof 扫描 clash/mihomo 进程 ──
    try:
        out = subprocess.check_output(
            ["lsof", "-i", "-P", "-n"], timeout=3, stderr=subprocess.DEVNULL
        ).decode()
        for line in out.split("\n"):
            if "LISTEN" not in line:
                continue
            for keyword, label in [("FlClash", "FlClash"), ("mihomo", "Clash Verge"),
                                    ("Clash Verge", "Clash Verge"), ("Clash\\x20Verge", "Clash Verge"),
                                    ("Clash\\x20", "Clash Verge")]:
                if keyword in line:
                    m = re.search(r':(\d+)\s', line)
                    if m:
                        port = int(m.group(1))
                        # 更新对应 app 的听端口（补充 config 里可能没写对的）
                        for s in sources:
                            if s["app"] == label and not s["listening"]:
                                s["actual_port"] = port
                                s["listening"] = True
    except Exception:
        pass

    return sources


def get_zshrc_proxy_status():
    if not ZSHRC.exists():
        return {"enabled": False, "port": None}
    content = ZSHRC.read_text()
    enabled_lines = re.findall(r"^export\s+(http_proxy|https_proxy|ALL_PROXY)=.*?:(\d+)", content, re.MULTILINE)
    if enabled_lines:
        port = enabled_lines[0][1]
        return {"enabled": True, "port": int(port)}
    return {"enabled": False, "port": None}


def toggle_zshrc_proxy(enable, port=None):
    if not ZSHRC.exists():
        return {"ok": False, "error": ".zshrc 不存在"}

    if enable:
        if not port:
            proxy = detect_proxy()
            port = proxy.get("active_port")
            if not port:
                return {"ok": False, "error": "没有检测到代理端口，无法开启"}

        proxy_url = f"http://127.0.0.1:{port}"
        content = ZSHRC.read_text()
        lines = content.split("\n")
        new_lines = []
        added = False

        for line in lines:
            if re.match(r"^#?\s*export\s+(http_proxy|https_proxy|ALL_PROXY)=", line.strip()):
                if not added:
                    new_lines.append(f"export http_proxy={proxy_url}")
                    new_lines.append(f"export https_proxy={proxy_url}")
                    new_lines.append(f"export ALL_PROXY={proxy_url}")
                    added = True
                continue
            new_lines.append(line)

        if not added:
            new_lines.append("")
            new_lines.append("# 终端代理")
            new_lines.append(f"export http_proxy={proxy_url}")
            new_lines.append(f"export https_proxy={proxy_url}")
            new_lines.append(f"export ALL_PROXY={proxy_url}")

        ZSHRC.write_text("\n".join(new_lines))
        return {"ok": True, "enabled": True, "port": port}

    else:
        content = ZSHRC.read_text()
        lines = content.split("\n")
        new_lines = []
        for line in lines:
            if re.match(r"^export\s+(http_proxy|https_proxy|ALL_PROXY)=", line.strip()):
                new_lines.append(f"#{line.strip()}")
            else:
                new_lines.append(line)
        ZSHRC.write_text("\n".join(new_lines))
        return {"ok": True, "enabled": False}


# ── Claude Code ───────────────────────────────────────

def _test_api(base_url, auth_token, model):
    try:
        endpoint = base_url.rstrip("/") + "/v1/messages"
        data = json.dumps({
            "model": model,
            "max_tokens": 5,
            "messages": [{"role": "user", "content": "hi"}],
        }).encode()
        req = urllib.request.Request(
            endpoint, data=data,
            headers={
                "Content-Type": "application/json",
                "x-api-key": auth_token,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return True, None
    except Exception as e:
        return False, str(e)


def _identify_provider(base_url):
    mapping = [
        ("bigmodel.cn", "Zhipu GLM"),
        ("deepseek.com", "DeepSeek"),
        ("moonshot.cn", "Kimi"),
        ("ofox.ai", "ofox"),
        ("cherryin", "cherryIN"),
        ("openai.com", "OpenAI"),
        ("anthropic.com", "Anthropic Official"),
    ]
    for domain, name in mapping:
        if domain in base_url:
            return name
    return "unknown"


def get_cc_status():
    if not CLAUDE_SETTINGS.exists():
        return {"configured": False, "working": False, "error": "settings.json 不存在"}

    try:
        with open(CLAUDE_SETTINGS) as f:
            settings = json.load(f)
    except Exception as e:
        return {"configured": False, "working": False, "error": str(e)}

    env = settings.get("env", {})
    base_url = env.get("ANTHROPIC_BASE_URL", "")
    auth_token = env.get("ANTHROPIC_AUTH_TOKEN", "")
    model = env.get("ANTHROPIC_MODEL", "unknown")
    provider = _identify_provider(base_url)

    working = False
    test_error = None
    if base_url and auth_token:
        working, test_error = _test_api(base_url, auth_token, model)

    return {
        "configured": True,
        "working": working,
        "provider": provider,
        "model": model,
        "base_url": base_url,
        "test_error": test_error,
    }


# ── CC Switch ─────────────────────────────────────────

def get_ccswitch_status():
    if not CCSWITCH_DB.exists():
        return {"configured": False, "working": False, "error": "数据库不存在"}

    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        conn.row_factory = sqlite3.Row

        result = {"configured": True, "working": True}

        row = conn.execute(
            "SELECT name FROM providers WHERE app_type='claude' AND is_current=1"
        ).fetchone()
        result["current_provider"] = row["name"] if row else None

        row = conn.execute("SELECT value FROM settings WHERE key='global_proxy_url'").fetchone()
        result["global_proxy"] = row["value"] if row else None

        row = conn.execute(
            "SELECT ph.is_healthy, ph.last_error FROM provider_health ph "
            "JOIN providers p ON p.id = ph.provider_id "
            "WHERE p.app_type='claude' AND p.is_current=1"
        ).fetchone()
        if row:
            result["healthy"] = bool(row["is_healthy"])
            result["last_error"] = row["last_error"]
            if not result["healthy"]:
                result["working"] = False
        else:
            result["working"] = False
            result["error"] = "还未测试过，请在 CC Switch 中测试"

        row = conn.execute("SELECT COUNT(*) FROM providers WHERE app_type='claude'").fetchone()
        result["provider_count"] = row[0] if row else 0

        conn.close()

        if not result.get("current_provider"):
            result["working"] = False
            result["error"] = "没有设置当前 provider"

        return result
    except Exception as e:
        return {"configured": True, "working": False, "error": str(e)}


# ── Hermes ────────────────────────────────────────────

def _mg(pattern, text, default="unknown"):
    m = re.search(pattern, text)
    return m.group(1) if m else default


def get_hermes_status():
    if not HERMES_CONFIG.exists():
        return {"configured": False, "working": False}

    try:
        try:
            import yaml
            with open(HERMES_CONFIG) as f:
                config = yaml.safe_load(f)
            mc = config.get("model", {})
            provider = mc.get("provider", "unknown")
            model = mc.get("default", "unknown")
            base_url = mc.get("base_url", "")
        except ImportError:
            with open(HERMES_CONFIG) as f:
                content = f.read()
            model_block = re.search(r"model:\s*\n((?:\s{1,6}\S.*\n)*)", content)
            section = model_block.group(1) if model_block else content
            provider = _mg(r"provider:\s*(\S+)", section)
            model = _mg(r"default:\s*(\S+)", section)
            base_url = _mg(r"base_url:\s*(\S+)", section, "")

        return {
            "configured": True,
            "working": True,
            "provider": provider,
            "model": model,
            "base_url": base_url,
        }
    except Exception as e:
        return {"configured": False, "working": False, "error": str(e)}


# ── VS Code ────────────────────────────────────────────

def get_vscode_status():
    if not VSCODE_SETTINGS.exists():
        return {"configured": False, "error": "VS Code settings.json 不存在"}

    try:
        with open(VSCODE_SETTINGS) as f:
            settings = json.load(f)
    except Exception as e:
        return {"configured": False, "error": str(e)}

    proxy = settings.get("http.proxy", "")
    no_proxy = settings.get("http.proxySupport", "")

    proxy_port = None
    if proxy:
        m = re.search(r":(\d+)", proxy)
        if m:
            proxy_port = int(m.group(1))

    proxy_ok = False
    if proxy_port:
        proxy_ok = _port_alive(proxy_port)

    return {
        "configured": True,
        "proxy": proxy,
        "proxy_port": proxy_port,
        "proxy_ok": proxy_ok,
        "proxy_support": no_proxy or "未设置",
    }


def fix_vscode():
    proxy = detect_proxy()
    port = proxy.get("active_port")
    if not port:
        return {"ok": False, "error": "没有检测到代理端口"}

    proxy_url = f"http://127.0.0.1:{port}"

    if not VSCODE_SETTINGS.exists():
        # 创建最小配置
        VSCODE_SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        settings = {}
    else:
        try:
            with open(VSCODE_SETTINGS) as f:
                settings = json.load(f)
        except Exception:
            settings = {}

    settings["http.proxy"] = proxy_url
    settings["http.proxyStrictSSL"] = False
    settings["http.proxySupport"] = "on"

    with open(VSCODE_SETTINGS, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)

    return {"ok": True, "proxy": proxy_url}


# ── 修复 ──────────────────────────────────────────────

def _backup_settings():
    if CLAUDE_SETTINGS.exists():
        backup_name = f"settings.json.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(CLAUDE_SETTINGS, CLAUDE_SETTINGS.parent / backup_name)
        for old in sorted(CLAUDE_SETTINGS.parent.glob("settings.json.bak.*"))[:-5]:
            old.unlink(missing_ok=True)


def fix_cc():
    if not CCSWITCH_DB.exists():
        return {"ok": False, "error": "CC Switch 数据库不存在，无法修复"}
    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        row = conn.execute(
            "SELECT settings_config FROM providers WHERE app_type='claude' AND is_current=1"
        ).fetchone()
        conn.close()
        if not row:
            return {"ok": False, "error": "没有当前 provider"}

        settings = json.loads(row[0])
        env = settings.get("env", {})
        if "CLAUDE_CODE_DISABLE_AUTO_UPDATE" not in env:
            env["CLAUDE_CODE_DISABLE_AUTO_UPDATE"] = "1"
        if "CLAUDE_CODE_EFFORT_LEVEL" not in env:
            env["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
        settings["env"] = env
        if "skipDangerousModePermissionPrompt" not in settings:
            settings["skipDangerousModePermissionPrompt"] = True

        _backup_settings()
        with open(CLAUDE_SETTINGS, "w") as f:
            json.dump(settings, f, indent=2)
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def fix_ccswitch():
    proxy = detect_proxy()
    port = proxy.get("active_port")

    if not CCSWITCH_DB.exists():
        return {"ok": False, "error": "CC Switch 数据库不存在"}
    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        if port:
            proxy_url = f"http://127.0.0.1:{port}"
            existing = conn.execute("SELECT value FROM settings WHERE key='global_proxy_url'").fetchone()
            if existing:
                conn.execute("UPDATE settings SET value=? WHERE key='global_proxy_url'", (proxy_url,))
            else:
                conn.execute("INSERT INTO settings (key, value) VALUES ('global_proxy_url', ?)", (proxy_url,))
            conn.commit()
            conn.close()
            return {"ok": True, "proxy_url": proxy_url}
        conn.close()
        return {"ok": False, "error": "没有检测到代理端口"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def fix_hermes():
    if not HERMES_CONFIG.exists():
        return {"ok": False, "error": "Hermes 配置文件不存在"}
    return {"ok": True, "note": "配置文件正常，请检查 Hermes 本身"}


def toggle_ccswitch_direct(enable):
    """CC Switch 直连开关：开=清掉代理URL，关=写回代理URL"""
    if not CCSWITCH_DB.exists():
        return {"ok": False, "error": "CC Switch 数据库不存在"}
    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        if enable:
            conn.execute("DELETE FROM settings WHERE key='global_proxy_url'")
            conn.commit()
            conn.close()
            return {"ok": True, "direct": True, "msg": "CC Switch 已切换到直连模式"}
        else:
            # 关掉直连：恢复代理
            proxy = detect_proxy()
            port = proxy.get("active_port")
            if not port:
                conn.close()
                return {"ok": False, "error": "没有检测到代理端口，无法启用代理"}
            proxy_url = f"http://127.0.0.1:{port}"
            existing = conn.execute("SELECT value FROM settings WHERE key='global_proxy_url'").fetchone()
            if existing:
                conn.execute("UPDATE settings SET value=? WHERE key='global_proxy_url'", (proxy_url,))
            else:
                conn.execute("INSERT INTO settings (key, value) VALUES ('global_proxy_url', ?)", (proxy_url,))
            conn.commit()
            conn.close()
            return {"ok": True, "direct": False, "proxy_url": proxy_url, "msg": f"CC Switch 代理已恢复 → {proxy_url}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def toggle_vscode_direct(enable):
    """VS Code 直连开关：开=删掉代理配置，关=写回代理配置"""
    if enable:
        if not VSCODE_SETTINGS.exists():
            return {"ok": True, "direct": True, "msg": "VS Code 已经是直连模式"}
        try:
            with open(VSCODE_SETTINGS) as f:
                settings = json.load(f)
        except Exception:
            return {"ok": True, "direct": True, "msg": "VS Code 配置文件无法读取，跳过"}
        
        settings.pop("http.proxy", None)
        settings["http.proxySupport"] = "off"
        with open(VSCODE_SETTINGS, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
        return {"ok": True, "direct": True, "msg": "VS Code 已切换到直连模式"}
    else:
        proxy = detect_proxy()
        port = proxy.get("active_port")
        if not port:
            return {"ok": False, "error": "没有检测到代理端口，无法启用代理"}
        proxy_url = f"http://127.0.0.1:{port}"
        if not VSCODE_SETTINGS.exists():
            VSCODE_SETTINGS.parent.mkdir(parents=True, exist_ok=True)
            settings = {}
        else:
            try:
                with open(VSCODE_SETTINGS) as f:
                    settings = json.load(f)
            except Exception:
                settings = {}
        settings["http.proxy"] = proxy_url
        settings["http.proxyStrictSSL"] = False
        settings["http.proxySupport"] = "on"
        with open(VSCODE_SETTINGS, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
        return {"ok": True, "direct": False, "proxy_url": proxy_url, "msg": f"VS Code 代理已恢复 → {proxy_url}"}


def fix_all():
    return {
        "cc": fix_cc(),
        "ccswitch": fix_ccswitch(),
        "hermes": fix_hermes(),
        "vscode": fix_vscode(),
    }


# ── git 代理 + 统一"应用当前代理" ─────────────────────

def get_git_status(cur):
    """读 git 全局代理,并判断是否与当前代理一致"""
    try:
        out = subprocess.check_output(
            ["git", "config", "--global", "--get", "http.proxy"],
            timeout=3, text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        out = ""
    proxy = out or None
    desired = f"http://127.0.0.1:{cur['port']}" if cur["mode"] == "port" else None
    return {"configured": True, "proxy": proxy, "desired": desired, "consistent": proxy == desired}


def apply_git(direct, proxy_url):
    """direct=True 清掉 git 代理(TUN 接管);否则写端口"""
    for key in ("http.proxy", "https.proxy"):
        if direct:
            subprocess.run(["git", "config", "--global", "--unset", key],
                           capture_output=True, timeout=3)
        else:
            subprocess.run(["git", "config", "--global", key, proxy_url],
                           capture_output=True, timeout=3)
    return {"ok": True, "direct": direct, "proxy": None if direct else proxy_url}


def apply_target(target, cur):
    """统一:把当前代理应用到指定目标. TUN/none→直连, port→填端口"""
    port = cur["port"]
    if cur["mode"] == "port":
        proxy_url, direct = f"http://127.0.0.1:{port}", False
    else:
        proxy_url, direct = None, True
    if target == "terminal":
        return toggle_zshrc_proxy(enable=not direct, port=port if not direct else None)
    if target == "git":
        return apply_git(direct, proxy_url)
    if target == "vscode":
        return toggle_vscode_direct(True) if direct else fix_vscode()
    if target == "ccswitch":
        return toggle_ccswitch_direct(True) if direct else fix_ccswitch()
    return {"ok": False, "error": f"未知目标: {target}"}


# ── Provider 管理 ─────────────────────────────────────

def get_claude_providers():
    if not CCSWITCH_DB.exists():
        return []
    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        rows = conn.execute(
            "SELECT name, is_current FROM providers WHERE app_type='claude' ORDER BY sort_index"
        ).fetchall()
        conn.close()
        return [{"name": r[0], "current": bool(r[1])} for r in rows]
    except Exception:
        return []


def switch_claude_provider(provider_name):
    if not CCSWITCH_DB.exists():
        return {"ok": False, "error": "CC Switch 数据库不存在"}
    try:
        conn = sqlite3.connect(str(CCSWITCH_DB))
        row = conn.execute(
            "SELECT id, settings_config FROM providers WHERE app_type='claude' AND name=?",
            (provider_name,),
        ).fetchone()
        if not row:
            conn.close()
            return {"ok": False, "error": f"找不到 provider: {provider_name}"}

        provider_id, settings_json = row
        conn.execute("UPDATE providers SET is_current=0 WHERE app_type='claude'")
        conn.execute("UPDATE providers SET is_current=1 WHERE id=?", (provider_id,))
        conn.commit()
        conn.close()

        settings = json.loads(settings_json)
        env = settings.get("env", {})
        if "CLAUDE_CODE_DISABLE_AUTO_UPDATE" not in env:
            env["CLAUDE_CODE_DISABLE_AUTO_UPDATE"] = "1"
        if "CLAUDE_CODE_EFFORT_LEVEL" not in env:
            env["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
        settings["env"] = env
        if "skipDangerousModePermissionPrompt" not in settings:
            settings["skipDangerousModePermissionPrompt"] = True

        _backup_settings()
        with open(CLAUDE_SETTINGS, "w") as f:
            json.dump(settings, f, indent=2)

        return {"ok": True, "provider": provider_name}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── 汇总 ──────────────────────────────────────────────

def get_full_status():
    cur = detect_current_proxy()
    return {
        "current": cur,
        "proxy": detect_proxy(),
        "zshrc_proxy": get_zshrc_proxy_status(),
        "git": get_git_status(cur),
        "claude_code": get_cc_status(),
        "cc_switch": get_ccswitch_status(),
        "hermes": get_hermes_status(),
        "vscode": get_vscode_status(),
    }


# ── HTTP Server ───────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._serve_html()
        elif self.path == "/api/status":
            self._json(get_full_status())
        elif self.path == "/api/proxy/scan":
            ports = scan_proxy_ports()
            self._json({"ports": ports, "count": len(ports)})
        elif self.path == "/api/claude/providers":
            self._json(get_claude_providers())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")

    def do_POST(self):
        body = self._read_body()
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._json({"ok": False, "error": "Invalid JSON"}, 400)
            return

        if self.path == "/api/proxy/toggle":
            self._json(toggle_zshrc_proxy(data.get("enable", True), data.get("port")))
        elif self.path == "/api/direct/ccswitch":
            self._json(toggle_ccswitch_direct(data.get("enable", True)))
        elif self.path == "/api/direct/vscode":
            self._json(toggle_vscode_direct(data.get("enable", True)))
        elif self.path == "/api/fix/cc":
            self._json(fix_cc())
        elif self.path == "/api/fix/ccswitch":
            self._json(fix_ccswitch())
        elif self.path == "/api/fix/hermes":
            self._json(fix_hermes())
        elif self.path == "/api/fix/vscode":
            self._json(fix_vscode())
        elif self.path == "/api/fix/all":
            self._json(fix_all())
        elif self.path == "/api/claude/switch":
            self._json(switch_claude_provider(data.get("provider", "")))
        elif self.path.startswith("/api/apply/"):
            target = self.path.rsplit("/", 1)[-1]
            self._json(apply_target(target, detect_current_proxy()))
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")

    def _serve_html(self):
        html_path = TEMPLATE_DIR / "index.html"
        if html_path.exists():
            content = html_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", len(content))
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"index.html not found")

    def _json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""


def main():
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"网络工具面板 → http://127.0.0.1:{PORT}")
    print("按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
        server.server_close()


if __name__ == "__main__":
    main()
