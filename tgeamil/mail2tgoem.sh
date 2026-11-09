#!/usr/bin/env bash
# Mail2Telegram Serv00/Ct8 Vps一键部署脚本（带菜单、一步一步提示）
# By: djkyc
#
# 运行方法（不要用 bash <(curl...) 这种方式，提示输入会出问题）：
# 1. 把这个文件传到 Serv00 家目录，变成 ~/mail2tg.sh
# 2. chmod +x ~/mail2tg.sh
# 3. ./mail2tg.sh
# 4. 选 1 一键部署，按提示一步一步填
#
# 本脚本在主机上会产生的效果：
# - ~/mail2tg/：从 GitHub 克隆 Mail2Telegram（已存在则跳过克隆，不覆盖你的配置）
# - ~/mail2tg-venv/：Python 虚拟环境，并装 requirements.txt
# - ~/mail2tg/config.py：你填的机器人 Token、聊天 ID、邮箱和授权码，权限 600，只写在这里，不打印出来
# - ~/mail2tg/run.sh、start.sh、stop.sh：后台启动/停止脚本（代替 Docker / systemd）
# - ~/check_mail2tg.sh：看门狗
# - crontab：@reboot 和每 5 分钟各一条看门狗，服务掉了会自动拉起来
# - 后台进程：mail2tg/main.py，日志在 ~/mail2tg/mail2tg.log 和 ~/mail2tg/log/email_checker.log
#
# 只读说明：本脚本只配 IMAP，不配 SMTP，不改 Mail2Telegram 的发信逻辑。
# 各家 IMAP 按官网最新设置：Gmail imap.gmail.com:993、QQ imap.qq.com:993、
# 163 imap.163.com:993、新浪按后缀 imap.sina.com / imap.sina.cn / imap.vip.sina.com /
# imap.vip.sina.cn:993、cock.li mail.cock.li:993、2925 imap.2925.com:993（备选 imap.2925mail.com）、v.cd smtp.mail.v.cd:993。
# Outlook / Hotmail 只走 OAuth：个人账号自 2024-09-16 起密码 IMAP 已停用，
# 只认 OAuth2（outlook.office365.com:993 SSL/TLS，XOAUTH2）。
# 本脚本自带 OAuth 桥接：生成 oauth_helper.py（令牌刷新 + XOAUTH2 登录）
# 和 oauth_outlook.py（设备码授权），并给 main.py 打补丁，只把两处
# server.login(...) 换成 oauth_helper.imap_login(...)，其他邮箱仍走密码登录。
# 兼容补丁：上游用 IDLE + SEARCH 监听，2925 不认 SEARCH、新浪会断 IDLE、
# cock.li 的 LIST 分隔符是 "." 不是 "/"，所以补丁把监听改成每 60 秒轮询
# （SELECT 取邮件数 + FETCH 取新信，不调 SEARCH/IDLE），并按 LIST 行里
# 最后一个带引号的名字解析文件夹。
# Telegram 命令：机器人除了推送，还能回命令。只认 TELEGRAM_CHAT_ID 一个人：
# /ls 看邮箱和文件夹，/show 邮箱号 文件夹号 条数 看最近的信，
# /del 邮箱号 文件夹号 序号 删信（要再发 /delok 确认，5 分钟内有效）。
# 令牌存 ~/mail2tg/oauth_tokens.json（600），access token 约 1 小时过期时
# 自动用 refresh_token 刷新；refresh token 被吊销/过期就用菜单 10 重新授权。
# 授权前要先在 Microsoft Entra 自己注册一个应用（公开客户端，
# 权限 Office 365 Exchange Online > IMAP.AccessAsUser.All + offline_access），
# 拿到 Application (client) ID；不要用别人的 client ID，也不要把令牌发到聊天里。

REPO="https://github.com/Heavrnl/Mail2Telegram.git"
DIR="$HOME/mail2tg"
VENV="$HOME/mail2tg-venv"
WATCHDOG="$HOME/check_mail2tg.sh"
CONFIG="$DIR/config.py"

pause() {
read -r -p "按回车返回主菜单..." _dummy || true
echo ""
}

is_running() {
pgrep -f "mail2tg/main.py" >/dev/null 2>&1
}

# 把单引号转成 Python 字符串里安全的写法，避免密码里有 ' 把 config.py 写坏
py_escape() {
printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

ask_yes_no() {
# $1=提示，默认 No；返回 0 表示 yes
local ans=""
read -r -p "$1 [y/N] " ans || true
case "$ans" in
y|Y|yes|YES) return 0;;
*) return 1;;
esac
}

WATCHDOG_PREF="$HOME/.mail2tg-watchdog-default"

ask_watchdog_remove() {
# 看门狗“要不要去掉”只问这一次选择：记住上次的选择，下次直接回车就用它，
# 没选过默认 n（留着）。返回 0 表示去掉看门狗。
local def="n"
if [ -f "$WATCHDOG_PREF" ]; then
def=$(tr -d ' \n\r' < "$WATCHDOG_PREF" 2>/dev/null | head -c 1)
case "$def" in y|n) ;; *) def="n";; esac
fi
local prompt="要不要同时把 crontab 看门狗也去掉？（去掉后它就不会在 5 分钟后又被拉起来）"
if [ "$def" = "y" ]; then
prompt="$prompt [Y/n，直接回车=去掉]"
else
prompt="$prompt [y/N，直接回车=留着]"
fi
local ans=""
read -r -p "$prompt " ans || true
case "$ans" in
"") ans="$def";;
y|Y|yes|YES) ans="y";;
n|N|no|NO) ans="n";;
*) ans="$def";;
esac
printf '%s' "$ans" > "$WATCHDOG_PREF" || true
if [ "$ans" = "y" ]; then
return 0
else
return 1
fi
}

step_binexec() {
echo "第 1 步：开启 Serv00 运行自有程序的权限"
if command -v devil >/dev/null 2>&1; then
if devil binexec on; then
echo "devil binexec 已开启。如果是刚开的，退出重登一次 SSH 再继续，后面步骤才生效。"
else
echo "devil binexec on 失败了，先去 Serv00 面板确认这台账号有没有开这个权限，再重跑这一步。"
return 1
fi
else
echo "找不到 devil 命令，跳过这一步，直接继续；如果后面启动失败，再回来看这一步。"
fi
return 0
}

step_python() {
echo "第 2 步：检查 Python"
if ! command -v python3 >/dev/null 2>&1; then
echo "找不到 python3，停在这里了。"
return 1
fi
python3 --version
echo "Mail2Telegram 用默认的 Python 3.11 就够，不用特意换 3.13/3.14/3.15。"
return 0
}

step_install() {
echo "第 3 步：拉代码、建虚拟环境、装依赖"
if [ -d "$DIR" ] && [ -f "$DIR/main.py" ]; then
echo "已经有 $DIR，而且 main.py 在，跳过克隆，不覆盖你现有的配置。"
else
echo "正在克隆 $REPO 到 $DIR..."
if ! git clone "$REPO" "$DIR"; then
echo "克隆失败了，停在这里了。请检查网络和 git，再重跑。"
return 1
fi
fi
if [ ! -x "$VENV/bin/python" ]; then
echo "正在建虚拟环境 $VENV..."
if ! python3 -m venv "$VENV"; then
echo "建虚拟环境失败了，停在这里了。"
return 1
fi
else
echo "已经有虚拟环境 $VENV，跳过新建。"
fi
echo "正在装依赖（requirements.txt），要下载一会儿，别关终端..."
if ! "$VENV/bin/pip" install -r "$DIR/requirements.txt"; then
echo "装依赖失败了，停在这里了。不要往下走，先把上面最后几行报错贴出来看。"
return 1
fi
echo "依赖装好了。"
return 0
}

write_helpers() {
echo "第 4 步：写后台脚本 run.sh / start.sh / stop.sh / 看门狗"
cat > "$DIR/run.sh" <<'EOF'
#!/bin/sh
# Serv00 用：代替 docker-compose / systemd
cd "$(dirname "$0")" || exit 1
export LANGUAGE=Chinese
export TIMEZONE=Asia/Shanghai
export ENABLE_LOGGING=true
# 关键：这个项目里 ENABLE_EVC 默认是 true，不关会去调验证码提取服务，Serv00 上直接关掉
export ENABLE_EVC=false
if [ -x "$HOME/mail2tg-venv/bin/python" ]; then
PY="$HOME/mail2tg-venv/bin/python"
else
PY="python3"
fi
# 必须用绝对路径启动：start.sh、stop.sh、看门狗、is_running 都是按
# mail2tg/main.py 匹配进程的，相对路径 main.py 匹配不到，会导致
# 重复启动、停不掉、看门狗每 5 分钟又拉一个。
exec "$PY" "$PWD/main.py"
EOF
cat > "$DIR/start.sh" <<'EOF'
#!/bin/sh
if pgrep -f "mail2tg/main.py" >/dev/null 2>&1; then
echo "mail2tg already running"
exit 0
fi
cd "$HOME/mail2tg" || exit 1
nohup ./run.sh >> "$HOME/mail2tg/mail2tg.log" 2>&1 &
echo "mail2tg started, log: $HOME/mail2tg/mail2tg.log"
EOF
cat > "$DIR/stop.sh" <<'EOF'
#!/bin/sh
# 注意：先把 crontab 里的 check_mail2tg.sh 那两行去掉，不然 5 分钟后看门狗又会把它拉起来
pkill -f "mail2tg/main.py"
echo "mail2tg stopped"
EOF
cat > "$WATCHDOG" <<'EOF'
#!/bin/sh
# Serv00 看门狗：代替 systemd，crontab 每 5 分钟和 @reboot 各跑一次
if ! pgrep -f "mail2tg/main.py" >/dev/null 2>&1; then
cd "$HOME/mail2tg" || exit 1
nohup ./run.sh >> "$HOME/mail2tg/mail2tg.log" 2>&1 &
fi
EOF
chmod +x "$DIR/run.sh" "$DIR/start.sh" "$DIR/stop.sh" "$WATCHDOG"
echo "后台脚本写好了。"
return 0
}

write_oauth_files() {
echo "写 OAuth 桥接文件 oauth_helper.py / oauth_outlook.py"
cat > "$DIR/oauth_helper.py" <<'OAUTH_HELPER_EOF'
#!/usr/bin/env python3
"""Outlook/Hotmail OAuth helper for Mail2Telegram (Serv00).

Only stdlib is used, so no extra pip package is needed.

What it does:
- Reads refresh/access tokens from oauth_tokens.json next to this file
  (chmod 600, one entry per mailbox, keyed by full email address).
- Refreshes the access token when it is expired or about to expire
  (access tokens live about 1 hour; the refresh token is what keeps
  the background service running unattended).
- Logs in to IMAP with SASL XOAUTH2 instead of a password:
  base64("user=<email>\\x01auth=Bearer <access_token>\\x01\\x01")
  against outlook.office365.com:993.

What it does NOT do:
- It never asks for, stores, or sends the mailbox password.
- It never invents a token. If there is no token entry for the mailbox,
  or the refresh token is rejected by Microsoft (invalid_grant),
  it raises an error and the caller must re-authorise with
  oauth_outlook.py (device-code flow). It must not fall back to a
  password login for an OAuth account: that login is disabled by
  Microsoft and would only hide the real error.

Scope used everywhere (Microsoft Learn, IMAP):
  https://outlook.office.com/IMAP.AccessAsUser.All
plus offline_access (to get a refresh token), openid, profile, email.
Tenant default is "consumers" (personal Outlook/Hotmail/Live only).
Use "common" only if the mailbox is a work/school Microsoft 365 account.
"""

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

SCOPE = "https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
DEFAULT_TENANT = "consumers"
TOKEN_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "oauth_tokens.json"
)
# Refresh a little early so a token does not die mid-IMAP-session.
REFRESH_MARGIN_SECONDS = 300


def _token_url(tenant):
    return "https://login.microsoftonline.com/%s/oauth2/v2.0/token" % (
        tenant or DEFAULT_TENANT
    )


def load_tokens():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_tokens(tokens):
    tmp = TOKEN_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2, sort_keys=True)
        f.write("\n")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, TOKEN_FILE)
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass


def xoauth2_string(email, access_token):
    """Return the raw XOAUTH2 initial-response bytes for one mailbox.

    Raw bytes, NOT base64: imaplib and imaplib2 base64-encode whatever
    authenticate()'s authobject returns, so returning base64 here would
    double-encode it and the server rejects AUTHENTICATE with
    'Command Argument Error'.
    """
    raw = "user=%s\x01auth=Bearer %s\x01\x01" % (email, access_token)
    return raw.encode("utf-8")


def _post_token(tenant, data):
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(
        _token_url(tenant),
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8"))
        except Exception:
            err = {}
        # Never log token values; only the error code/description.
        raise RuntimeError(
            "Microsoft token endpoint returned %s: %s"
            % (
                err.get("error", "http_%s" % e.code),
                err.get("error_description", "")[:300],
            )
        )


def refresh_access_token(email, entry):
    """Refresh one entry in place and return the new access token."""
    client_id = entry.get("client_id")
    refresh_token = entry.get("refresh_token")
    tenant = entry.get("tenant") or DEFAULT_TENANT
    if not client_id or not refresh_token:
        raise RuntimeError(
            "Outlook OAuth entry for %s has no client_id/refresh_token; "
            "re-authorise with: python3 oauth_outlook.py %s" % (email, email)
        )
    result = _post_token(
        tenant,
        {
            "client_id": client_id,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": SCOPE,
        },
    )
    if "access_token" not in result:
        raise RuntimeError(
            "Microsoft refresh failed for %s: %s"
            % (email, result.get("error", "no access_token in response"))
        )
    entry["access_token"] = result["access_token"]
    # Microsoft may rotate the refresh token; keep the new one if given.
    if result.get("refresh_token"):
        entry["refresh_token"] = result["refresh_token"]
    entry["expires_at"] = time.time() + int(result.get("expires_in", 3600))
    entry["tenant"] = tenant
    entry["client_id"] = client_id
    tokens = load_tokens()
    tokens[email] = entry
    save_tokens(tokens)
    return entry["access_token"]


def get_access_token(email, tenant=None, client_id=None):
    """Return a usable access token for email, refreshing if needed."""
    tokens = load_tokens()
    entry = tokens.get(email)
    if not entry:
        raise RuntimeError(
            "No Outlook OAuth token for %s. Run first: "
            "python3 oauth_outlook.py %s" % (email, email)
        )
    if client_id:
        entry["client_id"] = client_id
    if tenant:
        entry["tenant"] = tenant
    access_token = entry.get("access_token")
    expires_at = float(entry.get("expires_at") or 0)
    if access_token and expires_at - time.time() > REFRESH_MARGIN_SECONDS:
        return access_token
    return refresh_access_token(email, entry)


def is_oauth_account(email_config):
    return bool(email_config.get("USE_OAUTH"))


def imap_login(server, email_config):
    """Log one IMAP server in, OAuth or password, and say which was used.

    Returns "xoauth2" or "password". Raises on failure; for an OAuth
    account it never falls back to password login.
    """
    email = email_config["EMAIL"]
    if is_oauth_account(email_config):
        token = get_access_token(
            email,
            tenant=email_config.get("OAUTH_TENANT") or DEFAULT_TENANT,
            client_id=email_config.get("OAUTH_CLIENT_ID"),
        )
        # imaplib/imaplib2 base64-encode what authenticate()'s authobject
        # returns, so pass the RAW XOAUTH2 bytes (xoauth2_string does NOT
        # base64-encode). Returning base64 here double-encodes it.
        server.authenticate("XOAUTH2", lambda _resp: xoauth2_string(email, token))
        return "xoauth2"
    server.login(email, email_config["PASSWORD"])
    return "password"
OAUTH_HELPER_EOF
cat > "$DIR/oauth_outlook.py" <<'OAUTH_OUTLOOK_EOF'
#!/usr/bin/env python3
"""Authorise one Outlook/Hotmail mailbox for Mail2Telegram via OAuth.

Device-code flow (Microsoft identity platform, RFC 8628):
  1. This script asks Microsoft for a device code + short user code.
  2. YOU open https://www.microsoft.com/link in your own browser,
     enter that user code, sign in as the Outlook mailbox, and consent
     to the IMAP permission. The code is valid for 15 minutes.
  3. This script polls Microsoft until you finish, then saves the
     access + refresh tokens to oauth_tokens.json (chmod 600, next
     to this file). It never prints the tokens.

Before running this, register your own app once in Microsoft Entra:
  - https://entra.microsoft.com -> App registrations -> New registration
  - Name: anything, e.g. Mail2Telegram
  - Supported account types: Personal Microsoft accounts only
  - Redirect URI: Public client/native (mobile & desktop) -> http://localhost
  - Authentication -> Allow public client flows: Yes
  - API permissions -> Add a permission -> APIs my organization uses
    -> Office 365 Exchange Online -> Delegated permissions
    -> IMAP.AccessAsUser.All -> Add permissions
  - Copy the Application (client) ID. That is the only ID this script
    needs. There is no client secret for a public client; never create
    one for this, and never paste any token/secret into a chat.

Safety: only enter the user code on microsoft.com/link, in a
browser you opened yourself, and only for the app name you just
registered. A device code is as powerful as a login while it is live.

Usage:
  python3 oauth_outlook.py you@outlook.com
  python3 oauth_outlook.py you@hotmail.com <client-id> [consumers|common]
  python3 oauth_outlook.py you@outlook.com <client-id> --no-test

After success, the mailbox is added to Mail2Telegram by the menu
script (pick_provider option 7), or by hand in config.py:
  {'EMAIL': 'you@outlook.com', 'PASSWORD': '',
   'IMAP_SERVER': 'outlook.office365.com', 'IMAP_SERVER_PORT': 993,
   'USE_OAUTH': True, 'OAUTH_TENANT': 'consumers',
   'OAUTH_CLIENT_ID': '<the same client id>'}
"""

import base64
import imaplib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from oauth_helper import (
    DEFAULT_TENANT,
    SCOPE,
    TOKEN_FILE,
    load_tokens,
    save_tokens,
    xoauth2_string,
)

DEVICE_CODE_URL_TMPL = (
    "https://login.microsoftonline.com/%s/oauth2/v2.0/devicecode"
)
TOKEN_URL_TMPL = "https://login.microsoftonline.com/%s/oauth2/v2.0/token"
IMAP_HOST = "outlook.office365.com"
IMAP_PORT = 993


def _post(url, data):
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8"))
        except Exception:
            err = {}
        raise RuntimeError(
            "Microsoft returned %s: %s"
            % (
                err.get("error", "http_%s" % e.code),
                err.get("error_description", "")[:300],
            )
        )


def test_imap(email, access_token):
    """Real IMAP XOAUTH2 login, to prove the token/scope work.
    Retries up to 3 times: Microsoft personal-account IMAP often answers
    'User is authenticated but not connected' once and then works."""
    last_exc = None
    for attempt in (1, 2, 3):
        if attempt == 1:
            print("正在用新令牌试一次 IMAP 登录（outlook.office365.com:993）……")
        else:
            print("正在用新令牌试第 %d 次 IMAP 登录……" % attempt)
        server = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT)
        try:
            server.authenticate("XOAUTH2", lambda _resp: xoauth2_string(email, access_token))
            status, _ = server.select("INBOX")
            print("IMAP 测试：登录成功，INBOX 选择结果：%s" % status)
            if status != "OK":
                print("警告：登录通了，但选 INBOX 不是 OK，先看日志再决定要不要转后台。")
            return
        except Exception as e:
            last_exc = e
            print("IMAP 测试第 %d 次失败：%s" % (attempt, e))
            if attempt < 3:
                print("等 10 秒再试一次（微软那边偶尔一次连不上，重试就通）。")
                time.sleep(10)
        finally:
            try:
                server.logout()
            except Exception:
                pass
    raise last_exc


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    email = argv[1].strip()
    client_id = argv[2].strip() if len(argv) > 2 else ""
    tenant = DEFAULT_TENANT
    no_test = False
    for arg in argv[2:]:
        if arg == "--no-test":
            no_test = True
        elif arg in ("consumers", "common", "organizations"):
            tenant = arg
    if "@" not in email:
        print("邮箱格式不对：%s" % email)
        return 1
    if not client_id:
        print("先去 Microsoft Entra 注册应用，拿到 Application (client) ID 再来。")
        print("步骤见本文件开头的说明；不要用别人的 client ID，也不要在这里贴令牌。")
        client_id = input("Application (client) ID: ").strip()
    if not client_id:
        print("client ID 没填，停在这里了。")
        return 1
    if tenant not in ("consumers", "common", "organizations"):
        tenant = DEFAULT_TENANT

    print("第 1 步：向 Microsoft 要设备码……")
    dc = _post(
        DEVICE_CODE_URL_TMPL % tenant,
        {"client_id": client_id, "scope": SCOPE},
    )
    if "device_code" not in dc or "user_code" not in dc:
        print("要设备码失败：%s" % dc.get("error", dc))
        return 1
    print("")
    # 设备码页用微软返回的 verification_uri（Thunderbird 公开 ID 下就是 https://www.microsoft.com/link，用户实测这个地址输码能正常验证）。
    _uri = dc.get("verification_uri", "https://www.microsoft.com/link")
    _code = dc["user_code"]
    # OSC 8 超链接（点一下在浏览器打开）+ OSC 52（请终端把用户码写进剪贴板）；不支持的终端会忽略转义。
    # 网址用亮绿粗体、用户码用亮黄粗体，显眼好找。
    print("第 2 步：在你自己的浏览器里打开：\x1b]8;;%s\x1b\\\x1b[1;92m%s\x1b[0m\x1b]8;;\x1b\\" % (_uri, _uri))
    print("网址（点不开就手动复制）：\x1b[1;92m%s\x1b[0m" % _uri)
    try:
        sys.stdout.write("\x1b]52;c;%s\x1b\\" % base64.b64encode(_code.encode("utf-8")).decode("ascii")); sys.stdout.flush()
    except Exception:
        pass
    print("输入这串用户码（15 分钟内有效，已尝试自动复制到剪贴板）：\x1b[1;93m%s\x1b[0m" % _code)
    print("用 %s 这个账号登录并同意 IMAP 权限。" % email)
    print(f"只在 {_uri} 输码，别在别的页面输。")
    print("")
    print("第 3 步：等你授权完，本脚本自动去换令牌（按 Ctrl+C 可取消）……")
    device_code = dc["device_code"]
    interval = int(dc.get("interval", 5))
    expires_in = int(dc.get("expires_in", 900))
    deadline = time.time() + expires_in
    while time.time() < deadline:
        time.sleep(interval)
        try:
            result = _post(
                TOKEN_URL_TMPL % tenant,
                {
                    "client_id": client_id,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": device_code,
                },
            )
        except RuntimeError as e:
            # authorization_pending / slow_down come back as errors.
            msg = str(e)
            if "authorization_pending" in msg:
                continue
            if "slow_down" in msg:
                interval += 5
                continue
            print("换令牌失败：%s" % msg)
            print("如果是 authorization_declined / expired_token，重新跑一次本脚本。")
            return 1
        if "access_token" not in result:
            print("换令牌返回里没有 access_token：%s" % result.get("error", result))
            return 1
        tokens = load_tokens()
        tokens[email] = {
            "client_id": client_id,
            "tenant": tenant,
            "access_token": result["access_token"],
            "refresh_token": result.get("refresh_token", ""),
            "expires_at": time.time() + int(result.get("expires_in", 3600)),
            "scope": SCOPE,
        }
        save_tokens(tokens)
        print("授权成功，令牌已存到 %s（权限 600，令牌本身没有打印出来）。" % TOKEN_FILE)
        if not tokens[email]["refresh_token"]:
            print("警告：这次没拿到 refresh_token（可能缺 offline_access），令牌过期后要重新授权。")
        if no_test:
            print("已跳过 IMAP 测试。跑前台测试时再验证。")
        else:
            try:
                test_imap(email, result["access_token"])
            except Exception as e:
                print("IMAP 测试失败：%s" % e)
                print("令牌已保存，但先别转后台：检查 Entra 应用有没有加 IMAP.AccessAsUser.All，")
                print("以及 Outlook 网页版设置 > 邮件 > 转发和 IMAP 里 IMAP 是不是开着。")
                return 1
        print("完成。回菜单里选 7 把这个邮箱加进 config.py（USE_OAUTH），再选 3 前台测试。")
        return 0
    print("设备码过期了（15 分钟），重新跑一次本脚本。")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
OAUTH_OUTLOOK_EOF
chmod +x "$DIR/oauth_outlook.py"
if ! "$VENV/bin/python" -m py_compile "$DIR/oauth_helper.py" "$DIR/oauth_outlook.py" 2>/dev/null && ! python3 -m py_compile "$DIR/oauth_helper.py" "$DIR/oauth_outlook.py"; then
echo "OAuth 文件语法检查没过，别继续，先看上面报错。"
return 1
fi
echo "OAuth 桥接文件写好了。"
return 0
}

patch_main_py() {
echo "给 main.py 打补丁：OAuth 登录 + 兼容轮询（不用 SEARCH/IDLE）+ Telegram 命令"
if [ ! -f "$DIR/main.py" ]; then echo "没有 $DIR/main.py，先拉代码。"; return 1; fi
if grep -q "oauth_helper.imap_login" "$DIR/main.py" 2>/dev/null && grep -q "_selected_count" "$DIR/main.py" 2>/dev/null && grep -q "run_command_bot" "$DIR/main.py" 2>/dev/null && grep -q "轮询查新邮件 v3" "$DIR/main.py" 2>/dev/null && grep -q "def cmd_rmmail" "$DIR/main.py" 2>/dev/null && grep -q "菜单 v1" "$DIR/main.py" 2>/dev/null && grep -q "stop_signals=None" "$DIR/main.py" 2>/dev/null && grep -q "loop.run_until_complete(app.bot.set_my_commands" "$DIR/main.py" 2>/dev/null && grep -q "菜单 v2" "$DIR/main.py" 2>/dev/null && grep -q "菜单 v3" "$DIR/main.py" && grep -q "重试提醒只发一次" "$DIR/main.py" && grep -q "Outlook 提示用 microsoft.com/link" "$DIR/main.py" && grep -q "转发识别 Received 头" "$DIR/main.py" && grep -q "排版美化 验证码代码块" "$DIR/main.py" && grep -q "发件人二次解码" "$DIR/main.py" && grep -q "垃圾邮件默认发主聊天" "$DIR/main.py"; then echo "补丁已经打过了，跳过。"; return 0; fi
local bak="$DIR/main.py.bak.$(date +%Y%m%d%H%M%S)"
cp "$DIR/main.py" "$bak" || { echo "备份 main.py 失败，补丁没打。"; return 1; }
if ! python3 - "$DIR" <<'PYEOF'
import os, sys
# DIR 是 shell 变量，没有 export，子进程 python 看不到 os.environ["DIR"]，
# 所以改成命令行参数传进来（s13 上就是在这里报 KeyError: 'DIR'）。
path = os.path.join(sys.argv[1], "main.py")
src = open(path, encoding="utf-8").read()

# 1) OAuth：两处密码登录改成 oauth_helper.imap_login（已打过就跳过这步）
old = "server.login(email_config['EMAIL'], email_config['PASSWORD'])"
count = src.count(old)
if count == 2:
    src = src.replace(old, "oauth_helper.imap_login(server, email_config)")
elif count != 0:
    print("补丁停：main.py 里找到 %d 处密码登录，预期 2 处或 0 处，一处都没改。" % count)
    sys.exit(1)
anchor = "from tools.extract_verification_code import extract_verification_code"
if "import oauth_helper" not in src:
    if anchor not in src:
        print("补丁停：找不到 import 锚点，一处都没改。")
        sys.exit(1)
    src = src.replace(anchor, anchor + "\nimport oauth_helper  # Serv00 补丁：Outlook 走 XOAUTH2，其他邮箱仍走密码登录", 1)

# 2) 兼容：LIST 文件夹名解析只认 "/"，cock.li 的分隔符是 "."，
#    会把整行当文件夹名去 select。改成取 LIST 行里最后一个带引号的名字。
old_parse = "folder_name = folder.decode().split(' \"/\" ')[-1].strip('\"')"
if old_parse in src:
    src = src.replace(old_parse, "folder_name = _parse_list_folder_name(folder)")
elif "_parse_list_folder_name(folder)" not in src:
    print("补丁停：找不到 LIST 解析行，一处都没改。")
    sys.exit(1)

# 3) 插入两个小工具函数，放在 def monitor_email 前面
if "def _parse_list_folder_name" not in src:
    helpers = '''def _parse_list_folder_name(folder):
    # LIST 行分隔符可能是 / . :，上游只认 "/" 会把整行当文件夹名。
    # 不管分隔符是什么，取行里最后一个带引号的名字。
    text = folder.decode(errors="replace") if isinstance(folder, bytes) else str(folder)
    quoted = re.findall(r'"([^"]*)"', text)
    if quoted:
        return quoted[-1]
    return text.rsplit(" ", 1)[-1].strip('"')


def _selected_count(server, folder):
    # 只用 SELECT 取邮件数，不用 SEARCH（2925 不认 SEARCH）。
    # select 返回如 [b'6 EXISTS']；拿不到数时再试 STATUS。
    status, data = server.select(folder)
    if status != "OK":
        raise Exception(f"无法选择文件夹 {folder}: {data}")
    for item in data or []:
        raw = item if isinstance(item, bytes) else str(item).encode()
        m = re.search(rb"(\\d+)\\s+EXISTS", raw)
        if m:
            return int(m.group(1))
    status, data = server.status(folder, "(MESSAGES)")
    if status == "OK" and data:
        raw = data[0] if isinstance(data[0], bytes) else str(data[0]).encode()
        m = re.search(rb"MESSAGES\\s+(\\d+)", raw)
        if m:
            return int(m.group(1))
    raise Exception(f"无法从 select/STATUS 取邮件数: {data}")


'''
    if "def monitor_email" not in src:
        print("补丁停：找不到 def monitor_email，一处都没改。")
        sys.exit(1)
    src = src.replace("def monitor_email", helpers + "def monitor_email", 1)

# 4) 兼容：把 IDLE+SEARCH 的监听改成轮询。
#    2925 不支持 SEARCH，新浪会断 IDLE，轮询只用 SELECT 取数 + FETCH 取信，
#    每 60 秒查一次，连接断了就重连。
if "轮询查新邮件 v3" not in src:
    start = src.find("def idle_mail_listener")
    end = src.find("\ndef main():", start)
    if start < 0 or end < 0:
        print("补丁停：找不到 idle_mail_listener/main 边界，一处都没改。")
        sys.exit(1)
    listener = '''def idle_mail_listener(email_config, folder):
    # 兼容版：轮询查新邮件，不用 IDLE、不用 SEARCH。
    # 轮询查新邮件 v3：每轮新建连接 + 绑定删了自动退出。
    # 2925 的 IMAP 不认 SEARCH；新浪会在 60 秒空闲后把连接断开，
    # v1 是“一个连接复用、睡 60 秒再 SELECT”，每轮都会断、连错 5 次
    # 就报重试上限（s13 上 15:29 新浪那条就是这么来的）。
    # v2 每轮新建连接：登录、LIST、SELECT 取数、有新信就 FETCH，
    # 用完马上退出登录；断一次只算一次重试，不会再累积到上限。
    config = load_config()
    RETRY_LIMIT = config.RETRY_LIMIT
    RETRY_DELAY = config.RETRY_DELAY
    RETRY_PAUSE = config.RETRY_PAUSE
    POLL_INTERVAL = getattr(config, "POLL_INTERVAL", 60)
    retry_count = 0
    limit_notified = False  # 重试提醒只发一次：同一轮故障只通知一次，恢复后才重新通知
    last_count = None
    email_provider = 'gmail' if 'gmail.com' in email_config['EMAIL'] else 'other'

    while True:
        if email_config['EMAIL'] in _REMOVED_MAILBOXES:
            logger.info(f"{email_config['EMAIL']} 的绑定已删，监听退出。")
            return
        server = None
        try:
            server = imaplib2.IMAP4_SSL(email_config['IMAP_SERVER'], email_config['IMAP_SERVER_PORT'])
            oauth_helper.imap_login(server, email_config)
            logger.info(f"成功登录邮箱 {email_config['EMAIL']}")

            _, folders = server.list()
            actual_folder = get_folder_name(folders, folder, email_provider) or folder
            count = _selected_count(server, actual_folder)
            if last_count is None:
                last_count = count
                logger.info(f"成功选择文件夹: {actual_folder}，当前 {last_count} 封")

            if email_config['EMAIL'] not in LOGIN_SUCCESS:
                language = os.environ.get('LANGUAGE', 'Chinese')
                if language == 'English':
                    message = 'Successfully logged into mailbox ' + email_config['EMAIL']
                else:
                    message = '成功登录邮箱 ' + email_config['EMAIL']
                LOGIN_SUCCESS.append(email_config['EMAIL'])
                asyncio.run(send_telegram_message(message))

            if count > last_count:
                for num in range(last_count + 1, count + 1):
                    try:
                        fetch_email(server, str(num), email_config, actual_folder)
                    except Exception as e:
                        logger.error(f"取第 {num} 封信失败（跳过这封）: {e}")
                last_count = count
            elif count < last_count:
                last_count = count
            retry_count = 0
            limit_notified = False
        except Exception as e:
            logger.error(f"{email_config['EMAIL']} 的 {folder} 文件夹轮询出错: {e}")
            retry_count += 1
        finally:
            if server:
                try:
                    server.logout()
                except Exception:
                    pass

        if retry_count >= RETRY_LIMIT:
            final_message = f"{email_config['EMAIL']} 的 {folder} 文件夹重试次数达到上限。等待 {RETRY_PAUSE // 60} 分钟后重试。"
            logger.error(final_message)
            if not limit_notified:
                asyncio.run(send_telegram_message(final_message))
                limit_notified = True
            time.sleep(RETRY_PAUSE)
            retry_count = 0
        elif retry_count:
            time.sleep(RETRY_DELAY)
        else:
            time.sleep(POLL_INTERVAL)

'''
    src = src[:start] + listener + src[end:]

# 5) Telegram 命令：查看其它文件夹 / 删除邮件。
#    上游机器人只会推送，没有任何命令。这里加一个命令机器人，和监听线程一起跑。
#    只认 TELEGRAM_CHAT_ID 一个人；删信要先 /del 再 /delok 两步确认，5 分钟内有效。
if "CommandHandler" not in src:
    old_imp = "from telegram.ext import ApplicationBuilder"
    if old_imp not in src:
        print("补丁停：找不到 telegram 导入行，一处都没改。")
        sys.exit(1)
    src = src.replace(old_imp, "from telegram.ext import ApplicationBuilder, CommandHandler", 1)

if "def run_command_bot" not in src:
    commands = r'''# ---- Telegram 命令：查看其它文件夹 / 删除邮件，只认主人 TELEGRAM_CHAT_ID ----
_PENDING_DELS = {}


def _cmd_mailbox(arg):
    config = load_config()
    try:
        idx = int(arg) - 1
    except Exception:
        return None, "邮箱号要是数字，用 /ls 看编号。"
    if idx < 0 or idx >= len(config.EMAILS):
        return None, "没有这个编号的邮箱，用 /ls 看编号。"
    return config.EMAILS[idx], None


def _cmd_open(email_config):
    # 每次命令新开一个 IMAP 连接，用完就关，不动监听线程的连接
    server = imaplib2.IMAP4_SSL(email_config['IMAP_SERVER'], email_config['IMAP_SERVER_PORT'])
    oauth_helper.imap_login(server, email_config)
    return server


def _cmd_folders(server):
    status, folders = server.list()
    if status != "OK":
        raise Exception("取文件夹列表失败")
    names = []
    for f in folders or []:
        name = _parse_list_folder_name(f)
        if name and name not in names:
            names.append(name)
    return names


def _cmd_resolve_folder(server, arg):
    # 文件夹可以传编号（/ls 里看到的序号）或名字
    names = _cmd_folders(server)
    try:
        idx = int(arg) - 1
        if 0 <= idx < len(names):
            return names[idx], None
    except Exception:
        pass
    if arg in names:
        return arg, None
    return None, "没有这个文件夹，用 /ls 邮箱号 看编号。"


async def _cmd_check_owner(update):
    if not update.message:
        return False
    config = load_config()
    try:
        if str(update.effective_chat.id) == str(config.TELEGRAM_CHAT_ID):
            return True
    except Exception:
        pass
    try:
        await update.message.reply_text("不是主人，不理你。")
    except Exception:
        pass
    return False


def _cmd_fetch_header(server, seq):
    # 只取信头，不取正文
    typ, data = server.fetch(str(seq), "(BODY[HEADER.FIELDS (SUBJECT DATE FROM)])")
    if typ != "OK" or not data or not isinstance(data[0], tuple):
        return None, None, None
    msg = email.message_from_bytes(data[0][1])
    subject = decode_header_string(msg.get("Subject") or "(无主题)")
    sender = decode_header_string(msg.get("From") or "")
    date = msg.get("Date") or ""
    return subject, sender, date


def _cmd_close(server):
    if server:
        try:
            server.logout()
        except Exception:
            pass


async def cmd_start(update, context):
    if not await _cmd_check_owner(update):
        return
    await update.message.reply_text(
        "能用的命令：\n"
        "/ls 看邮箱列表；/ls 1 看 1 号邮箱的文件夹\n"
        "/show 1 1 8 看 1 号邮箱 1 号文件夹最新 8 封\n"
        "/del 1 1 7 删 1 号邮箱 1 号文件夹第 7 封（要再发 /delok 确认）\n"
        "/delok 1 1 7 确认删除")


async def cmd_ls(update, context):
    if not await _cmd_check_owner(update):
        return
    config = load_config()
    args = context.args
    if not args:
        lines = ["邮箱列表（/ls 1 看文件夹）："]
        for i, e in enumerate(config.EMAILS, 1):
            lines.append(f"{i}. {e['EMAIL']}")
        await update.message.reply_text("\n".join(lines))
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    server = None
    try:
        server = _cmd_open(email_config)
        names = _cmd_folders(server)
        lines = [f"{email_config['EMAIL']} 的文件夹："]
        for i, name in enumerate(names, 1):
            lines.append(f"{i}. {name}")
        lines.append("看信：/show 邮箱号 文件夹号 条数，例如 /show 1 1 8")
        await update.message.reply_text("\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"列文件夹失败：{e}")
    finally:
        _cmd_close(server)


async def cmd_show(update, context):
    if not await _cmd_check_owner(update):
        return
    args = context.args
    if len(args) < 2:
        await update.message.reply_text("用法：/show 邮箱号 文件夹号 [条数]，例如 /show 1 1 8")
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    try:
        count_n = int(args[2]) if len(args) > 2 else 8
    except Exception:
        count_n = 8
    count_n = max(1, min(count_n, 10))
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, args[1])
        if err:
            await update.message.reply_text(err)
            return
        total = _selected_count(server, folder)
        if total == 0:
            await update.message.reply_text(f"{folder} 里没有信。")
            return
        start = max(1, total - count_n + 1)
        lines = [f"{email_config['EMAIL']} / {folder}（共 {total} 封，最新 {total - start + 1} 封）："]
        for num in range(total, start - 1, -1):
            subject, sender, date = _cmd_fetch_header(server, num)
            if subject is None:
                lines.append(f"{num}. 取不出来")
            else:
                lines.append(f"{num}. {subject}\n   {sender} | {date}")
        lines.append("删信：/del 邮箱号 文件夹号 序号，例如 /del 1 1 7")
        await update.message.reply_text("\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"看信失败：{e}")
    finally:
        _cmd_close(server)


async def cmd_del(update, context):
    if not await _cmd_check_owner(update):
        return
    args = context.args
    if len(args) < 3:
        await update.message.reply_text("用法：/del 邮箱号 文件夹号 序号，例如 /del 1 1 7")
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    try:
        seq = int(args[2])
    except Exception:
        await update.message.reply_text("序号要是数字。")
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, args[1])
        if err:
            await update.message.reply_text(err)
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await update.message.reply_text(f"序号不对，这个文件夹现在共 {total} 封。")
            return
        subject, sender, date = _cmd_fetch_header(server, seq)
        if subject is None:
            subject, sender = "(取不到标题)", ""
        key = (str(update.effective_chat.id), args[0], args[1], str(seq))
        _PENDING_DELS[key] = (time.time(), folder, subject)
        await update.message.reply_text(
            f"要删这封吗？\n{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}\n发件人：{sender}\n"
            f"确认请在 5 分钟内发：/delok {args[0]} {args[1]} {seq}\n不删就不用管，5 分钟后作废。")
    except Exception as e:
        await update.message.reply_text(f"删信失败：{e}")
    finally:
        _cmd_close(server)


async def cmd_delok(update, context):
    if not await _cmd_check_owner(update):
        return
    args = context.args
    if len(args) < 3:
        await update.message.reply_text("用法：/delok 邮箱号 文件夹号 序号，例如 /delok 1 1 7")
        return
    key = (str(update.effective_chat.id), args[0], args[1], args[2])
    pending = _PENDING_DELS.pop(key, None)
    if not pending:
        await update.message.reply_text("没有等确认的删除，先发 /del 选一封。")
        return
    created, folder_saved, subject = pending
    if time.time() - created > 300:
        await update.message.reply_text("确认超时了（超过 5 分钟），没删，重新发 /del。")
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    try:
        seq = int(args[2])
    except Exception:
        await update.message.reply_text("序号要是数字。")
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, args[1])
        if err:
            await update.message.reply_text(err)
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await update.message.reply_text(f"序号变了，现在共 {total} 封，没删。重新发 /del。")
            return
        server.store(str(seq), "+FLAGS", r"(\Deleted)")
        server.expunge()
        logger.info(f"主人删信：{email_config['EMAIL']} / {folder} 第 {seq} 封：{subject}")
        await update.message.reply_text(f"删了：{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}")
    except Exception as e:
        await update.message.reply_text(f"删信失败：{e}")
    finally:
        _cmd_close(server)


def run_command_bot():
    # Telegram 命令机器人，和 IMAP 监听线程一起跑；断了 30 秒后自己重连。
    while True:
        try:
            config = load_config()
            app = ApplicationBuilder().token(config.TELEGRAM_BOT_TOKEN).build()
            app.add_handler(CommandHandler("start", cmd_start))
            app.add_handler(CommandHandler("help", cmd_start))
            app.add_handler(CommandHandler("ls", cmd_ls))
            app.add_handler(CommandHandler("show", cmd_show))
            app.add_handler(CommandHandler("del", cmd_del))
            app.add_handler(CommandHandler("delok", cmd_delok))
            logger.info("Telegram 命令机器人启动了（/help 看命令）。")
            app.run_polling()
        except Exception as e:
            logger.error(f"命令机器人出错，30 秒后重试：{e}")
            time.sleep(30)


'''
    if "def main():" not in src:
        print("补丁停：找不到 def main()，一处都没改。")
        sys.exit(1)
    src = src.replace("def main():", commands + "\ndef main():", 1)
    anchor = "    while any(thread.is_alive() for thread in email_threads):"
    if "bot_thread = threading.Thread(target=run_command_bot" not in src:
        if anchor not in src:
            print("补丁停：找不到 main() 里等监听线程的那行，一处都没改。")
            sys.exit(1)
        src = src.replace(anchor, "    bot_thread = threading.Thread(target=run_command_bot, daemon=True)\n    bot_thread.start()\n" + anchor, 1)

# 6) 机器人里删邮箱绑定：/rmmail /rmmailok（两步确认，只认主人）。
#    只删机器人这边的绑定（把邮箱从 config.py 的 EMAILS 里去掉），不删服务器上的信；
#    加邮箱还是得在服务器菜单 2 里配（密码/授权码只能在终端里输，不能发到聊天里）。
#    删完监听线程下次轮询看到邮箱在 _REMOVED_MAILBOXES 里就自己退出，不用重启进程；
#    load_config 改成每次 reload，命令不用重启就能看到新配置。
if "importlib.reload(config)" not in src:
    old_lc = "def load_config():\n    import config\n    return config"
    if old_lc not in src:
        print("补丁停：找不到 load_config，一处都没改。")
        sys.exit(1)
    src = src.replace(old_lc, "def load_config():\n    import config\n    import importlib\n    importlib.reload(config)\n    return config", 1)

if "def cmd_rmmail" not in src:
    rmmail = r'''_PENDING_RMMAIL = {}
_REMOVED_MAILBOXES = set()


def _rewrite_config_py(emails):
    # 把新的邮箱列表写回 config.py（原子替换，权限 600），其他配置项原样保留。
    import config as _cfg
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.py")
    lines = ["EMAILS = ["]
    for e in emails:
        lines.append("    {")
        for k, v in e.items():
            lines.append(f"        {k!r}: {v!r},")
        lines.append("    },")
    lines.append("]")
    for name in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_JUNK_CHAT_ID",
                 "RETRY_LIMIT", "RETRY_DELAY", "RETRY_PAUSE", "RECONNECT_INTERVAL",
                 "POLL_INTERVAL"):
        if hasattr(_cfg, name):
            lines.append(f"{name} = {getattr(_cfg, name)!r}")
    text = "\n".join(lines) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    import py_compile
    py_compile.compile(tmp, doraise=True)
    os.replace(tmp, path)


async def cmd_rmmail(update, context):
    if not await _cmd_check_owner(update):
        return
    config = load_config()
    args = context.args
    if not args:
        lines = ["邮箱列表（删绑定用 /rmmail 邮箱号）："]
        for i, e in enumerate(config.EMAILS, 1):
            lines.append(f"{i}. {e['EMAIL']}")
        lines.append("删绑定只删机器人这边的配置，不删服务器上的信；加回来用服务器菜单 2。")
        await update.message.reply_text("\n".join(lines))
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    if len(config.EMAILS) <= 1:
        await update.message.reply_text("就剩这一个邮箱了，不能删光。想换邮箱用服务器菜单 2 重新配。")
        return
    key = (str(update.effective_chat.id), args[0])
    _PENDING_RMMAIL[key] = (time.time(), email_config['EMAIL'])
    await update.message.reply_text(
        f"要删掉这个邮箱的绑定吗？\n{email_config['EMAIL']}\n"
        f"删完它就不再推送了，监听 60 秒内停掉；服务器上的信不动。\n"
        f"确认请在 5 分钟内发：/rmmailok {args[0]}\n不删就不用管，5 分钟后作废。")


async def cmd_rmmailok(update, context):
    if not await _cmd_check_owner(update):
        return
    args = context.args
    if not args:
        await update.message.reply_text("用法：/rmmailok 邮箱号，例如 /rmmailok 3")
        return
    key = (str(update.effective_chat.id), args[0])
    pending = _PENDING_RMMAIL.pop(key, None)
    if not pending:
        await update.message.reply_text("没有等确认的删绑定，先发 /rmmail 邮箱号。")
        return
    created, email = pending
    if time.time() - created > 300:
        await update.message.reply_text("确认超时了（超过 5 分钟），没删，重新发 /rmmail。")
        return
    config = load_config()
    try:
        idx = int(args[0]) - 1
    except Exception:
        await update.message.reply_text("邮箱号要是数字，用 /ls 看编号。")
        return
    if idx < 0 or idx >= len(config.EMAILS):
        await update.message.reply_text("没有这个编号的邮箱，用 /ls 看编号。")
        return
    if config.EMAILS[idx]['EMAIL'] != email:
        await update.message.reply_text("邮箱列表变了，编号对不上，重新发 /rmmail。")
        return
    if len(config.EMAILS) <= 1:
        await update.message.reply_text("就剩这一个邮箱了，不能删光。")
        return
    remaining = [e for i, e in enumerate(config.EMAILS) if i != idx]
    try:
        _rewrite_config_py(remaining)
    except Exception as e:
        await update.message.reply_text(f"写配置失败，没删：{e}")
        return
    _REMOVED_MAILBOXES.add(email)
    logger.info(f"主人删邮箱绑定：{email}")
    await update.message.reply_text(f"删了绑定：{email}\n它的监听 60 秒内停掉；服务器上的信还在。加回来用服务器菜单 2。")


'''
    anchor = "def run_command_bot():"
    if anchor not in src:
        print("补丁停：找不到 run_command_bot，一处都没改。")
        sys.exit(1)
    src = src.replace(anchor, rmmail + anchor, 1)

if 'CommandHandler("rmmail"' not in src:
    old_reg = '            app.add_handler(CommandHandler("delok", cmd_delok))'
    if old_reg not in src:
        print("补丁停：找不到 delok 注册行，一处都没改。")
        sys.exit(1)
    src = src.replace(old_reg, old_reg + '\n            app.add_handler(CommandHandler("rmmail", cmd_rmmail))\n            app.add_handler(CommandHandler("rmmailok", cmd_rmmailok))', 1)

if "/rmmail 3" not in src:
    old_help = '"/delok 1 1 7 确认删除")'
    if old_help in src:
        bs = chr(92)
        new_help = '"/delok 1 1 7 确认删除' + bs + 'n"' + "\n" + '        "/rmmail 3 删 3 号邮箱的绑定（要再发 /rmmailok 确认）' + bs + 'n"' + "\n" + '        "/rmmailok 3 确认删绑定")'
        src = src.replace(old_help, new_help, 1)
    # 旧帮助文本找不到也没关系：cmd_start 可能已被菜单版替换，那里已有 /rmmail 说明


# 7) 机器人里启停监听：菜单里的 ▶️/⏸️ 按钮用。
#    原来 main() 里监听线程死光程序就退出，机器人一停就整个没了；
#    改成 main() 只负责起监听线程 + 起命令机器人，然后一直等着，
#    启停只开关监听线程，命令机器人一直活着。
if "def start_monitor_threads" not in src:
    helpers = '''_MONITOR_BY_EMAIL = {}
_MONITOR_LOCK = threading.Lock()
_STOP_LISTENERS = threading.Event()


def start_monitor_threads():
    # 给还没有监听线程的邮箱起线程；已在跑的不重复起。返回新起的邮箱。
    _STOP_LISTENERS.clear()
    config = load_config()
    started = []
    with _MONITOR_LOCK:
        for email_config in config.EMAILS:
            email = email_config['EMAIL']
            if email in _REMOVED_MAILBOXES:
                continue
            t = _MONITOR_BY_EMAIL.get(email)
            if t is not None and t.is_alive():
                continue
            t = threading.Thread(target=monitor_email, args=(email_config,))
            _MONITOR_BY_EMAIL[email] = t
            t.start()
            started.append(email)
    return started


def stop_monitor_threads():
    # 停掉所有监听线程（命令机器人本身不停），最多等 70 秒。返回还活着的邮箱。
    _STOP_LISTENERS.set()
    deadline = time.time() + 70
    for t in list(_MONITOR_BY_EMAIL.values()):
        left = deadline - time.time()
        if left <= 0:
            break
        t.join(timeout=left)
    with _MONITOR_LOCK:
        return [e for e, t in _MONITOR_BY_EMAIL.items() if t.is_alive()]


'''
    anchor = "def main():"
    if anchor not in src:
        print("补丁停：找不到 def main()，一处都没改。")
        sys.exit(1)
    src = src.replace(anchor, helpers + anchor, 1)
    start = src.find("def main():")
    end = src.find('if __name__ == "__main__":', start)
    if start < 0 or end < 0:
        print("补丁停：找不到 main() 边界，一处都没改。")
        sys.exit(1)
    new_main = '''def main():
    logger.info("开始监听多个邮箱账户")
    start_monitor_threads()
    bot_thread = threading.Thread(target=run_command_bot, daemon=True)
    bot_thread.start()
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        pass
    logger.info("程序退出。")


'''
    src = src[:start] + new_main + src[end:]

# 监听轮询里用 _STOP_LISTENERS.wait 代替睡死，点了停止能马上醒、马上退；
# 循环开头看到停了就退出线程。
if "_STOP_LISTENERS.is_set()" not in src:
    old = "        if email_config['EMAIL'] in _REMOVED_MAILBOXES:"
    if old not in src:
        print("补丁停：找不到监听里的 _REMOVED 检查，一处都没改。")
        sys.exit(1)
    src = src.replace(old, "        if _STOP_LISTENERS.is_set():\n            logger.info(f\"{email_config['EMAIL']} 的监听已停。\")\n            return\n" + old, 1)
if "_STOP_LISTENERS.wait(POLL_INTERVAL)" not in src:
    for a, b in (("time.sleep(RETRY_DELAY)", "_STOP_LISTENERS.wait(RETRY_DELAY)"),
                 ("time.sleep(POLL_INTERVAL)", "_STOP_LISTENERS.wait(POLL_INTERVAL)"),
                 ("time.sleep(RETRY_PAUSE)", "_STOP_LISTENERS.wait(RETRY_PAUSE)")):
        if a not in src:
            print("补丁停：找不到监听里的 sleep，一处都没改。")
            sys.exit(1)
        src = src.replace(a, b, 1)

# 8) 机器人内菜单：/menu、/start 打开点按钮的菜单，不用记命令。
#    绑定邮箱只能在服务器上做（密码/授权码不能发到聊天里），菜单里只给指路；
#    邮箱列表、看信、删信、解绑、启停、看日志都在机器人里点按钮完成。
if "CallbackQueryHandler" not in src:
    old_imp = "from telegram.ext import ApplicationBuilder, CommandHandler"
    if old_imp not in src:
        print("补丁停：找不到 telegram 导入行，一处都没改。")
        sys.exit(1)
    src = src.replace(old_imp, "from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler\nfrom telegram import InlineKeyboardButton, InlineKeyboardMarkup", 1)

if "def _menu_keyboard" not in src:
    menu = r'''# 菜单 v1：机器人内菜单（/menu、/start），点按钮操作
def _menu_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📮 邮箱列表", callback_data="menu:ls")],
        [InlineKeyboardButton("➕ 绑定邮箱", callback_data="menu:bind")],
        [InlineKeyboardButton("🔗 解绑邮箱", callback_data="menu:rm")],
        [InlineKeyboardButton("▶️ 启动运行", callback_data="menu:start"),
         InlineKeyboardButton("⏸️ 停止运行", callback_data="menu:stop")],
        [InlineKeyboardButton("📋 查看日志", callback_data="menu:logs")],
    ])


def _menu_text():
    return ("📮 Mail2Telegram 菜单\n"
            "点下面的按钮操作，也可以用命令：\n"
            "/ls /show /del /rmmail /read")


def _redact_log_text(text):
    # 日志里有 Telegram 发消息的 URL，带着机器人 Token，必须先擦掉再发出来
    text = re.sub(r"bot\d+:[A-Za-z0-9_\-]{20,}", "bot[已隐藏]", text)
    text = re.sub(r"(TELEGRAM_BOT_TOKEN\s*=\s*['\"]?)[^'\"\s]+", r"\1[已隐藏]", text)
    return text


def _cmd_fetch_body(server, seq):
    # 取一封信的全文（标题 + 发件人 + 日期 + 正文，最多 2500 字）
    typ, data = server.fetch(str(seq), "(RFC822)")
    if typ != "OK" or not data or not isinstance(data[0], tuple):
        return None
    msg = email.message_from_bytes(data[0][1])
    subject = decode_header_string(msg.get("Subject") or "(无主题)")
    sender = decode_header_string(msg.get("From") or "")
    date = msg.get("Date") or ""
    body = get_email_content(msg) or ""
    return subject, sender, date, body


async def _cb_answer(query, text=None):
    try:
        if text:
            await query.answer(text)
        else:
            await query.answer()
    except Exception:
        pass


async def _cb_edit(query, text, markup=None):
    try:
        await query.edit_message_text(text, reply_markup=markup)
    except Exception:
        pass


async def _cb_check_owner(update):
    q = update.callback_query
    if not q:
        return None
    try:
        if str(update.effective_chat.id) == str(load_config().TELEGRAM_CHAT_ID):
            return q
    except Exception:
        pass
    try:
        await q.answer("不是主人，不理你。", show_alert=True)
    except Exception:
        pass
    return None


async def _cb_show_menu(query):
    await _cb_edit(query, _menu_text(), _menu_keyboard())


async def _cb_show_mailboxes(query, page=1):
    config = load_config()
    per_page = 8
    total = len(config.EMAILS)
    pages = max(1, (total + per_page - 1) // per_page)
    page = max(1, min(page, pages))
    start = (page - 1) * per_page
    rows = []
    for i, e in enumerate(config.EMAILS[start:start + per_page], start + 1):
        rows.append([InlineKeyboardButton(f"{i:>2}. {e['EMAIL']}", callback_data=f"mb:{i}")])
    nav = []
    if page > 1:
        nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"menu:ls:{page - 1}"))
    if page < pages:
        nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"menu:ls:{page + 1}"))
    if nav:
        rows.append(nav)
    rows.append([InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")])
    title = "📮 邮箱列表（点一个进文件夹）："
    if pages > 1:
        title = f"📮 邮箱列表（第 {page}/{pages} 页，点一个进文件夹）："
    await _cb_edit(query, title, InlineKeyboardMarkup(rows))


async def _cb_show_folders(query, midx):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        names = _cmd_folders(server)
        rows = []
        for i, name in enumerate(names, 1):
            rows.append([InlineKeyboardButton(f"{name}", callback_data=f"fld:{midx}:{i}")])
        rows.append([InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")])
        await _cb_edit(query, f"{email_config['EMAIL']} 的文件夹（点一个看最新 8 封）：", InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"列文件夹失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


async def _cb_show_folder(query, midx, fidx):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if total == 0:
            await _cb_edit(query, f"{folder} 里没有信。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回文件夹", callback_data=f"mb:{midx}")]]))
            return
        start = max(1, total - 7)
        text = f"{email_config['EMAIL']} / {folder}（共 {total} 封，最新 {total - start + 1} 封，点一封查看/删除）："
        rows = []
        w = len(str(total))
        for num in range(total, start - 1, -1):
            subject, sender, date = _cmd_fetch_header(server, num)
            if subject is None:
                subject = "(取不出来)"
            rows.append([InlineKeyboardButton(f"{num:>{w}}. {subject[:25]}", callback_data=f"view:{midx}:{fidx}:{num}")])
        rows.append([InlineKeyboardButton("↩️ 返回文件夹", callback_data=f"mb:{midx}")])
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"看信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


async def _cb_show_mail(query, midx, fidx, seq):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号不对，这个文件夹现在共 {total} 封。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]))
            return
        got = _cmd_fetch_body(server, int(seq))
        if got is None:
            await _cb_edit(query, "这封信取不出来。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]))
            return
        subject, sender, date, body = got
        text = f"主题：{subject}\n发件人：{sender}\n日期：{date}\n\n{body[:2500]}"
        rows = [[InlineKeyboardButton("🗑️ 删除这封", callback_data=f"del:{midx}:{fidx}:{seq}")],
                [InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"看信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


async def _cb_del_confirm(query, midx, fidx, seq):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号不对，这个文件夹现在共 {total} 封。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]))
            return
        subject, sender, date = _cmd_fetch_header(server, seq)
        if subject is None:
            subject, sender = "(取不到标题)", ""
        text = (f"要删这封吗？\n{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}\n发件人：{sender}\n")
        rows = [[InlineKeyboardButton("✅ 确认删除", callback_data=f"delok:{midx}:{fidx}:{seq}")],
                [InlineKeyboardButton("❌ 取消", callback_data=f"fld:{midx}:{fidx}")]]
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"删信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


async def _cb_del_execute(query, midx, fidx, seq):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号变了，现在共 {total} 封，没删。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]))
            return
        subject, sender, date = _cmd_fetch_header(server, seq)
        if subject is None:
            subject = "(取不到标题)"
        server.store(str(seq), "+FLAGS", r"(\Deleted)")
        server.expunge()
        logger.info(f"主人删信：{email_config['EMAIL']} / {folder} 第 {seq} 封：{subject}")
        await _cb_edit(query, f"删了：{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}",
                       InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}")]]))
    except Exception as e:
        await _cb_edit(query, f"删信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


async def _cb_show_unbind(query):
    config = load_config()
    rows = []
    for i, e in enumerate(config.EMAILS, 1):
        rows.append([InlineKeyboardButton(f"{i}. {e['EMAIL']}", callback_data=f"rm:{i}")])
    rows.append([InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")])
    await _cb_edit(query, "🔗 解绑邮箱（点一个解绑，只删机器人这边的配置）：", InlineKeyboardMarkup(rows))


async def _cb_unbind_confirm(query, midx):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, _menu_keyboard())
        return
    config = load_config()
    if len(config.EMAILS) <= 1:
        await _cb_edit(query, "就剩这一个邮箱了，不能删光。想换邮箱用服务器菜单 2 重新配。", _menu_keyboard())
        return
    text = (f"要解绑这个邮箱吗？\n{email_config['EMAIL']}\n"
            f"解绑后它就不再推送了，监听 60 秒内停掉；服务器上的信不动。")
    rows = [[InlineKeyboardButton("✅ 确认解绑", callback_data=f"rmok:{midx}")],
            [InlineKeyboardButton("❌ 取消", callback_data="menu:rm")]]
    await _cb_edit(query, text, InlineKeyboardMarkup(rows))


async def _cb_unbind_execute(query, midx):
    config = load_config()
    try:
        idx = int(midx) - 1
    except Exception:
        await _cb_edit(query, "邮箱号不对。", _menu_keyboard())
        return
    if idx < 0 or idx >= len(config.EMAILS):
        await _cb_edit(query, "没有这个编号的邮箱。", _menu_keyboard())
        return
    if len(config.EMAILS) <= 1:
        await _cb_edit(query, "就剩这一个邮箱了，不能删光。", _menu_keyboard())
        return
    email = config.EMAILS[idx]['EMAIL']
    remaining = [e for i, e in enumerate(config.EMAILS) if i != idx]
    try:
        _rewrite_config_py(remaining)
    except Exception as e:
        await _cb_edit(query, f"写配置失败，没解绑：{e}", _menu_keyboard())
        return
    _REMOVED_MAILBOXES.add(email)
    logger.info(f"主人删邮箱绑定：{email}")
    await _cb_edit(query, f"解绑了：{email}\n它的监听 60 秒内停掉；服务器上的信还在。加回来用服务器菜单 2。", _menu_keyboard())


async def _cb_toggle(query, action):
    if action == "start":
        started = start_monitor_threads()
        if started:
            text = "已启动运行：\n" + "\n".join(started)
        else:
            text = "已经在跑了，不用重复启动。"
    else:
        alive = stop_monitor_threads()
        if not alive:
            text = "已停止运行（监听都停了）。\n命令机器人还在，要再启动按 ▶️ 启动运行。"
        else:
            text = "有的线程还在等（最长 70 秒），稍后再按一次 ⏸️。\n还在跑：\n" + "\n".join(alive)
    await _cb_edit(query, text, _menu_keyboard())


async def _cb_show_logs(query):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mail2tg.log")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        await _cb_edit(query, f"读不到日志文件：{e}", _menu_keyboard())
        return
    tail = "".join(lines[-25:])
    tail = _redact_log_text(tail)
    if len(tail) > 3500:
        tail = tail[-3500:]
    text = "📋 运行日志（最后 25 行）：\n" + (tail or "（日志还是空的）")
    await _cb_edit(query, text, _menu_keyboard())


async def _cb_show_bind(query):
    text = ("➕ 绑定邮箱\n"
            "绑定要在服务器上完成：要输邮箱密码/授权码，密码不能发到聊天里。\n"
            "去 s13 上跑 tge，选 2，按提示走就行（选邮箱类型 → 填地址 → 填密码/授权码）。\n"
            "配好后在菜单里按 ▶️ 启动运行，新邮箱就开始推送了。")
    await _cb_edit(query, text, _menu_keyboard())


async def on_callback(update, context):
    q = await _cb_check_owner(update)
    if q is None:
        return
    await _cb_answer(q)
    data = q.data or ""
    parts = data.split(":")
    kind = parts[0]
    try:
        if data == "menu":
            await _cb_show_menu(q)
        elif data == "menu:ls" or data.startswith("menu:ls:"):
            _pg = 1
            if data.startswith("menu:ls:"):
                try:
                    _pg = int(data.split(":")[2])
                except Exception:
                    _pg = 1
            await _cb_show_mailboxes(q, _pg)
        elif data == "menu:rm":
            await _cb_show_unbind(q)
        elif data == "menu:bind":
            await _cb_show_bind(q)
        elif data == "menu:start":
            await _cb_toggle(q, "start")
        elif data == "menu:stop":
            await _cb_toggle(q, "stop")
        elif data == "menu:logs":
            await _cb_show_logs(q)
        elif kind == "mb" and len(parts) == 2:
            await _cb_show_folders(q, int(parts[1]))
        elif kind == "fld" and len(parts) == 3:
            await _cb_show_folder(q, int(parts[1]), int(parts[2]))
        elif kind == "view" and len(parts) == 4:
            await _cb_show_mail(q, int(parts[1]), int(parts[2]), int(parts[3]))
        elif kind == "del" and len(parts) == 4:
            await _cb_del_confirm(q, int(parts[1]), int(parts[2]), int(parts[3]))
        elif kind == "delok" and len(parts) == 4:
            await _cb_del_execute(q, int(parts[1]), int(parts[2]), int(parts[3]))
        elif kind == "rm" and len(parts) == 2:
            await _cb_unbind_confirm(q, int(parts[1]))
        elif kind == "rmok" and len(parts) == 2:
            await _cb_unbind_execute(q, int(parts[1]))
        else:
            await _cb_show_menu(q)
    except Exception as e:
        logger.error(f"菜单回调出错 {data}: {e}")
        await _cb_edit(q, f"出错了：{e}", _menu_keyboard())


async def cmd_read(update, context):
    if not await _cmd_check_owner(update):
        return
    args = context.args
    if len(args) < 3:
        await update.message.reply_text("用法：/read 邮箱号 文件夹号 序号，例如 /read 3 1 7")
        return
    email_config, err = _cmd_mailbox(args[0])
    if err:
        await update.message.reply_text(err)
        return
    try:
        seq = int(args[2])
    except Exception:
        await update.message.reply_text("序号要是数字。")
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, args[1])
        if err:
            await update.message.reply_text(err)
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await update.message.reply_text(f"序号不对，这个文件夹现在共 {total} 封。")
            return
        got = _cmd_fetch_body(server, seq)
        if got is None:
            await update.message.reply_text("这封信取不出来。")
            return
        subject, sender, date, body = got
        await update.message.reply_text(f"主题：{subject}\n发件人：{sender}\n日期：{date}\n\n{body[:2500]}")
    except Exception as e:
        await update.message.reply_text(f"看信失败：{e}")
    finally:
        _cmd_close(server)


'''
    anchor = "def run_command_bot():"
    if anchor not in src:
        print("补丁停：找不到 run_command_bot，一处都没改。")
        sys.exit(1)
    src = src.replace(anchor, menu + anchor, 1)

# /start 改成打开菜单；新命令 /menu、/read；按钮回调接进来；顺手把命令列表写进 Telegram 的 ☰ 菜单。
if "def _menu_keyboard" in src and "async def cmd_start" in src:
    start = src.find("async def cmd_start")
    end = src.find("async def cmd_ls", start)
    if start < 0 or end < 0:
        print("补丁停：找不到 cmd_start/cmd_ls 边界，一处都没改。")
        sys.exit(1)
    new_start = '''async def cmd_start(update, context):
    if not await _cmd_check_owner(update):
        return
    await update.message.reply_text(
        "📮 Mail2Telegram 菜单\\n"
        "点下面的按钮操作，也可以用命令：\\n"
        "/ls 看邮箱列表；/show 1 1 8 看信；/del 删信；/rmmail 解绑邮箱；/read 3 1 7 看全文",
        reply_markup=_menu_keyboard())


'''
    src = src[:start] + new_start + src[end:]

if 'CallbackQueryHandler(on_callback)' not in src:
    old_reg = '            app.add_handler(CommandHandler("rmmailok", cmd_rmmailok))'
    if old_reg not in src:
        print("补丁停：找不到 rmmailok 注册行，一处都没改。")
        sys.exit(1)
    src = src.replace(old_reg, old_reg + '\n            app.add_handler(CallbackQueryHandler(on_callback))\n            app.add_handler(CommandHandler("menu", cmd_start))\n            app.add_handler(CommandHandler("read", cmd_read))', 1)

if "set_my_commands" not in src:
    old_log = '            logger.info("Telegram 命令机器人启动了（/help 看命令）。")'
    if old_log not in src:
        print("补丁停：找不到命令机器人启动日志行，一处都没改。")
        sys.exit(1)
    new_log = '''            try:
                from telegram import BotCommand
                asyncio.run(app.bot.set_my_commands([
                    BotCommand("menu", "打开菜单"),
                    BotCommand("ls", "邮箱列表"),
                    BotCommand("show", "看最新邮件"),
                    BotCommand("read", "看一封信的全文"),
                    BotCommand("del", "删一封信"),
                    BotCommand("rmmail", "解绑邮箱"),
                    BotCommand("start", "打开菜单"),
                    BotCommand("help", "打开菜单"),
                ]))
            except Exception as e:
                logger.info(f"设置命令菜单失败，不影响使用：{e}")
''' + old_log
    src = src.replace(old_log, new_log, 1)


# 9) 修命令机器人线程里跑不起来：run_polling 要在有 event loop 的线程里跑，
#    命令机器人跑在线程里，没有主线程的 loop，不先建一个会报
#    There is no current event loop；信号处理也要关掉，不然 add_signal_handler
#    在非主线程里也会报 set_wakeup_fd only works in main thread。
#    这就是为什么之前 /ls /menu 发了没回、推送却正常：推送是普通请求，
#    轮询线程每次启动都直接报错，30 秒重试一次，永远没开始收消息。
if "stop_signals=None" not in src:
    old_run = "            app.run_polling()"
    if old_run not in src:
        print("补丁停：找不到 app.run_polling()，一处都没改。")
        sys.exit(1)
    src = src.replace(old_run, "            # run_polling 要在有 event loop 的线程里跑：命令机器人跑在线程里，\n"
        "            # 没有主线程的 loop，不先建一个会报 There is no current event loop；\n"
        "            # 信号处理也要关掉，不然 add_signal_handler 在非主线程里也会报错。\n"
        "            try:\n"
        "                asyncio.set_event_loop(asyncio.new_event_loop())\n"
        "            except Exception:\n"
        "                pass\n"
        "            app.run_polling(stop_signals=None)", 1)


# 10) 命令机器人单 loop：set_my_commands 和 run_polling 必须走同一个 event loop。
#    之前 set_my_commands 用 asyncio.run（单独一个 loop，用完就关），
#    run_polling 又新建一个 loop，httpx 客户端还绑在已关掉的 loop 上，
#    一收消息就报 Event loop is closed，30 秒重试一次，永远收不到。
#    改成每次尝试开头就建一个 loop，set_my_commands 和 run_polling 都走它。
if "loop.run_until_complete(app.bot.set_my_commands" not in src:
    old_top = "            config = load_config()\n            app = ApplicationBuilder().token(config.TELEGRAM_BOT_TOKEN).build()"
    if old_top not in src:
        print("补丁停：找不到 run_command_bot 开头，一处都没改。")
        sys.exit(1)
    src = src.replace(old_top, "            # 整个命令机器人跑在一个线程里，只用一个 event loop：\n"
        "            # run_polling 要在有 loop 的线程里跑，信号处理要关掉，\n"
        "            # 而且 set_my_commands 和 run_polling 必须走同一个 loop，\n"
        "            # 不然 httpx 客户端会绑到已经关掉的 loop 上，报 Event loop is closed。\n"
        "            loop = asyncio.new_event_loop()\n"
        "            asyncio.set_event_loop(loop)\n" + old_top, 1)
    old_smc = "                asyncio.run(app.bot.set_my_commands(["
    if old_smc not in src:
        print("补丁停：找不到 set_my_commands 调用，一处都没改。")
        sys.exit(1)
    src = src.replace(old_smc, "                loop.run_until_complete(app.bot.set_my_commands([", 1)
    step9_block = ("            # run_polling 要在有 event loop 的线程里跑：命令机器人跑在线程里，\n"
        "            # 没有主线程的 loop，不先建一个会报 There is no current event loop；\n"
        "            # 信号处理也要关掉，不然 add_signal_handler 在非主线程里也会报错。\n"
        "            try:\n"
        "                asyncio.set_event_loop(asyncio.new_event_loop())\n"
        "            except Exception:\n"
        "                pass\n"
        "            app.run_polling(stop_signals=None)")
    if step9_block in src:
        src = src.replace(step9_block, "            app.run_polling(stop_signals=None)", 1)
    elif "            app.run_polling()" in src:
        src = src.replace("            app.run_polling()", "            app.run_polling(stop_signals=None)", 1)
    else:
        print("补丁停：找不到 app.run_polling()，一处都没改。")
        sys.exit(1)
    old_err = '        except Exception as e:\n            logger.error(f"命令机器人出错，30 秒后重试：{e}")\n            time.sleep(30)'
    if old_err not in src:
        print("补丁停：找不到命令机器人重试块，一处都没改。")
        sys.exit(1)
    src = src.replace(old_err, '        except Exception as e:\n            logger.error(f"命令机器人出错，30 秒后重试：{e}")\n            try:\n                asyncio.set_event_loop(None)\n            except Exception:\n                pass\n            time.sleep(30)', 1)



# 11) 菜单 v2：文件夹中文名、翻页、日志返回按钮、绑定向导、/help 说明、命令列表只留 /menu /help。
# 11a) 文件夹名解析 + 中文显示
if "_decode_imap_utf7" not in src:
    old_parse = '''def _parse_list_folder_name(folder):
    # LIST 行分隔符可能是 / . :，上游只认 "/" 会把整行当文件夹名。
    # 不管分隔符是什么，取行里最后一个带引号的名字。
    text = folder.decode(errors="replace") if isinstance(folder, bytes) else str(folder)
    quoted = re.findall(r'"([^"]*)"', text)
    if quoted:
        return quoted[-1]
    return text.rsplit(" ", 1)[-1].strip('"')'''
    if old_parse not in src:
        print("补丁停：找不到 _parse_list_folder_name，一处都没改。")
        sys.exit(1)
    new_parse = '''# 菜单 v2：文件夹中文名、翻页、绑定向导、/help 说明
def _parse_list_folder_name(folder):
    # LIST 行分隔符可能是 / . :，名字可能带引号也可能不带。
    # 先取最后一个引号串之后的内容（没引号的名字，如 cock.li 的 "." Junk）；
    # 后面没东西，再取最后一个带引号的名字（名字本身带引号的情况）。
    text = folder.decode(errors="replace") if isinstance(folder, bytes) else str(folder)
    idx = text.rfind('"')
    if idx >= 0:
        after = text[idx + 1:].strip()
        if after:
            return after.strip('"').strip()
    quoted = re.findall(r'"([^"]*)"', text)
    if quoted:
        return quoted[-1]
    return text.rsplit(" ", 1)[-1].strip('"')


def _decode_imap_utf7(s):
    # IMAP 文件夹名用的 modified UTF-7：&...- 里是 base64（, 代替 /），&- 就是 &。
    import base64
    out = []
    i = 0
    while i < len(s):
        if s[i] == '&':
            j = s.find('-', i)
            if j == -1:
                out.append(s[i:])
                break
            if j == i + 1:
                out.append('&')
                i = j + 1
                continue
            b64 = s[i + 1:j].replace(',', '/')
            b64 += '=' * (-len(b64) % 4)
            try:
                out.append(base64.b64decode(b64).decode('utf-16-be'))
            except Exception:
                out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


_FOLDER_CN = {
    'INBOX': '收件箱', 'Inbox': '收件箱',
    'Trash': '垃圾箱', 'Junk': '垃圾邮件', 'Spam': '垃圾邮件',
    'Sent': '已发送', 'Drafts': '草稿箱', 'Archive': '归档',
    'All Mail': '全部邮件', 'Starred': '已加星标', 'Important': '重要',
}


def _folder_display_name(name):
    # 只改显示：先解 modified UTF-7，常用英文名翻成中文；选文件夹还用原名。
    decoded = _decode_imap_utf7(name)
    return _FOLDER_CN.get(decoded, decoded)'''
    src = src.replace(old_parse, new_parse, 1)
    # LIST 拿不到名字时（有的服务器格式怪），INBOX 一定有，先给它，别让文件夹页空着。
    a = src.find("def _cmd_folders(server):")
    b = src.find("def _cmd_resolve_folder(server, arg):", a)
    if a < 0 or b < 0:
        print("补丁停：找不到 _cmd_folders，一处都没改。")
        sys.exit(1)
    new_folders = '''def _cmd_folders(server):
    status, folders = server.list()
    if status != "OK":
        raise Exception("取文件夹列表失败")
    names = []
    for f in folders or []:
        name = _parse_list_folder_name(f)
        if name and name not in names:
            names.append(name)
    if not names:
        # 有的服务器 LIST 拿不到名字（比如 cock.li 的格式），INBOX 一定有，先给它
        names = ["INBOX"]
    return names


'''
    src = src[:a] + new_folders + src[b:]
# 11a-2) 文件夹列表按钮显示中文名，回调带上页码（第 1 页）
old_btn = '            rows.append([InlineKeyboardButton(f"{name}", callback_data=f"fld:{midx}:{i}")])'
if old_btn in src:
    src = src.replace(old_btn, '            rows.append([InlineKeyboardButton(_folder_display_name(name), callback_data=f"fld:{midx}:{i}:1")])', 1)

# 11b) 翻页：_cb_show_folder 加 page，view/del/delok 把 page 带回去
def _replace_fn(src, start_marker, end_marker, new_text):
    a = src.find(start_marker)
    b = src.find(end_marker, a)
    if a < 0 or b < 0:
        print(f"补丁停：找不到 {start_marker}，一处都没改。")
        sys.exit(1)
    return src[:a] + new_text + src[b:]

if "def _cb_show_folder(query, midx, fidx, page=1):" not in src:
    src = _replace_fn(src, "async def _cb_show_folder(", "async def _cb_show_mail(", r'''async def _cb_show_folder(query, midx, fidx, page=1):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if total == 0:
            await _cb_edit(query, f"{_folder_display_name(folder)} 里没有信。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回文件夹", callback_data=f"mb:{midx}")]]))
            return
        page = max(1, int(page))
        pages = (total - 1) // 8 + 1
        if page > pages:
            page = pages
        end = total - (page - 1) * 8
        start = max(1, end - 7)
        disp = _folder_display_name(folder)
        text = f"{email_config['EMAIL']} / {disp}（共 {total} 封，第 {page}/{pages} 页，点一封查看/删除）："
        rows = []
        w = len(str(total))
        for num in range(end, start - 1, -1):
            subject, sender, date = _cmd_fetch_header(server, num)
            if subject is None:
                subject = "(取不出来)"
            rows.append([InlineKeyboardButton(f"{num:>{w}}. {subject[:25]}", callback_data=f"view:{midx}:{fidx}:{num}:{page}")])
        nav = []
        if page > 1:
            nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"fld:{midx}:{fidx}:{page - 1}"))
        if page < pages:
            nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"fld:{midx}:{fidx}:{page + 1}"))
        if nav:
            rows.append(nav)
        rows.append([InlineKeyboardButton("↩️ 返回文件夹", callback_data=f"mb:{midx}")])
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"看信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


''')
if "def _cb_show_mail(query, midx, fidx, seq, page=1):" not in src:
    src = _replace_fn(src, "async def _cb_show_mail(", "async def _cb_del_confirm(", r'''async def _cb_show_mail(query, midx, fidx, seq, page=1):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号不对，这个文件夹现在共 {total} 封。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]))
            return
        got = _cmd_fetch_body(server, int(seq))
        if got is None:
            await _cb_edit(query, "这封信取不出来。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]))
            return
        subject, sender, date, body = got
        text = f"主题：{subject}\n发件人：{sender}\n日期：{date}\n\n{body[:2500]}"
        rows = [[InlineKeyboardButton("🗑️ 删除这封", callback_data=f"del:{midx}:{fidx}:{seq}:{page}")],
                [InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"看信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


''')
if "def _cb_del_confirm(query, midx, fidx, seq, page=1):" not in src:
    src = _replace_fn(src, "async def _cb_del_confirm(", "async def _cb_del_execute(", r'''async def _cb_del_confirm(query, midx, fidx, seq, page=1):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号不对，这个文件夹现在共 {total} 封。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]))
            return
        subject, sender, date = _cmd_fetch_header(server, seq)
        if subject is None:
            subject, sender = "(取不到标题)", ""
        text = (f"要删这封吗？\n{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}\n发件人：{sender}\n")
        rows = [[InlineKeyboardButton("✅ 确认删除", callback_data=f"delok:{midx}:{fidx}:{seq}:{page}")],
                [InlineKeyboardButton("❌ 取消", callback_data=f"fld:{midx}:{fidx}:{page}")]]
        await _cb_edit(query, text, InlineKeyboardMarkup(rows))
    except Exception as e:
        await _cb_edit(query, f"删信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


''')
if "def _cb_del_execute(query, midx, fidx, seq, page=1):" not in src:
    src = _replace_fn(src, "async def _cb_del_execute(", "async def _cb_show_unbind(", r'''async def _cb_del_execute(query, midx, fidx, seq, page=1):
    email_config, err = _cmd_mailbox(str(midx))
    if err:
        await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
        return
    server = None
    try:
        server = _cmd_open(email_config)
        folder, err = _cmd_resolve_folder(server, str(fidx))
        if err:
            await _cb_edit(query, err, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
            return
        total = _selected_count(server, folder)
        if seq < 1 or seq > total:
            await _cb_edit(query, f"序号变了，现在共 {total} 封，没删。",
                           InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]))
            return
        subject, sender, date = _cmd_fetch_header(server, seq)
        if subject is None:
            subject = "(取不到标题)"
        server.store(str(seq), "+FLAGS", r"(\Deleted)")
        server.expunge()
        logger.info(f"主人删信：{email_config['EMAIL']} / {folder} 第 {seq} 封：{subject}")
        await _cb_edit(query, f"删了：{email_config['EMAIL']} / {folder} 第 {seq} 封\n标题：{subject}",
                       InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回", callback_data=f"fld:{midx}:{fidx}:{page}")]]))
    except Exception as e:
        await _cb_edit(query, f"删信失败：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回邮箱列表", callback_data="menu:ls")]]))
    finally:
        _cmd_close(server)


''')

# 11c) 日志页：去掉 imap 的调试噪音，按钮改成明确的“返回菜单”
if "reader last 20 log messages" not in src:
    src = _replace_fn(src, "async def _cb_show_logs(", "async def _cb_show_bind(", r'''async def _cb_show_logs(query):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mail2tg.log")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        await _cb_edit(query, f"读不到日志文件：{e}", InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")]]))
        return
    lines = [ln for ln in lines if "reader last 20 log messages" not in ln]
    tail = "".join(lines[-25:])
    tail = _redact_log_text(tail)
    if len(tail) > 3500:
        tail = tail[-3500:]
    text = "📋 运行日志（最后 25 行）：\n" + (tail or "（日志还是空的）")
    await _cb_edit(query, text, InlineKeyboardMarkup([[InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")]]))


''')

# 11d) 绑定向导：机器人里选类型、发地址，记到 pending_bind.json；密码那步去服务器菜单 11 只输密码。
#      密码/授权码绝不能发到聊天里，所以向导到地址为止，不收密码。
if "_BIND_PROVIDERS" not in src:
    src = _replace_fn(src, "async def _cb_show_bind(", "async def on_callback(", r'''_BIND_PROVIDERS = [
    ("gmail", "Gmail"),
    ("qq", "QQ"),
    ("163", "163"),
    ("sina", "新浪"),
    ("cockli", "cock.li"),
    ("2925", "2925"),
    ("vcd", "v.cd"),
    ("outlook", "Outlook/Hotmail"),
    ("custom", "自建/小众邮箱"),
]
_BIND_STATE = {}


def _bind_imap_for(provider, email):
    if provider == "gmail":
        return "imap.gmail.com", 993, False
    if provider == "qq":
        return "imap.qq.com", 993, False
    if provider == "163":
        return "imap.163.com", 993, False
    if provider == "sina":
        dom = email.rsplit("@", 1)[-1].lower()
        return {"sina.com": "imap.sina.com", "sina.cn": "imap.sina.cn",
                "vip.sina.com": "imap.vip.sina.com", "vip.sina.cn": "imap.vip.sina.cn"}.get(dom, "imap.sina.com"), 993, False
    if provider == "cockli":
        return "mail.cock.li", 993, False
    if provider == "2925":
        return "imap.2925.com", 993, False
    if provider == "vcd":
        return "smtp.mail.v.cd", 993, False
    if provider == "outlook":
        return "outlook.office365.com", 993, True
    return "", 993, False


def _bind_provider_name(code):
    for c, n in _BIND_PROVIDERS:
        if c == code:
            return n
    return code


async def _cb_show_bind(query):
    rows = []
    for code, name in _BIND_PROVIDERS:
        rows.append([InlineKeyboardButton(name, callback_data=f"bind:{code}")])
    rows.append([InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")])
    await _cb_edit(query, "➕ 绑定邮箱\n选邮箱类型，然后按提示发邮箱地址；密码/授权码那步在服务器上完成（密码不能发到聊天里）。", InlineKeyboardMarkup(rows))


async def _cb_bind_pick(query, code, chat_id):
    if code == "cancel":
        _BIND_STATE.pop(chat_id, None)
        await _cb_show_menu(query)
        return
    _BIND_STATE[chat_id] = {"step": "email", "provider": code}
    await _cb_edit(query, f"绑定邮箱：{_bind_provider_name(code)}\n请直接发邮箱地址（例如 name@example.com）。",
                   InlineKeyboardMarkup([[InlineKeyboardButton("❌ 取消", callback_data="bind:cancel")]]))


async def _bind_finish(update, st):
    import json
    provider = st["provider"]
    email = st["email"]
    if provider == "custom":
        server, port, oauth = st.get("server", ""), st.get("port", 993), False
    else:
        server, port, oauth = _bind_imap_for(provider, email)
    entry = {"provider": provider, "email": email, "imap_server": server,
             "imap_port": port, "use_oauth": oauth,
             "client_id": st.get("client_id", ""), "tenant": "consumers"}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pending_bind.json")
    try:
        with open(path, encoding="utf-8") as f:
            pending = json.load(f)
        if not isinstance(pending, list):
            pending = []
    except Exception:
        pending = []
    pending = [p for p in pending if p.get("email") != email]
    pending.append(entry)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(pending, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    _BIND_STATE.pop(str(update.effective_chat.id), None)
    if oauth:
        tip = (f"已记下：{email}（Outlook）。\n去 s13 上跑 tge，选 11，走设备码授权。\n授权时浏览器打开 https://www.microsoft.com/link 输码，用这个 Outlook 账号登录同意。\n授权完在菜单里按 ▶️ 启动运行。")
    else:
        tip = (f"已记下：{email}（{_bind_provider_name(provider)}）。\n去 s13 上跑 tge，选 11，只输密码/授权码就完成了，不用再填地址。\n配好后在菜单里按 ▶️ 启动运行。")
    await update.message.reply_text(tip, reply_markup=_menu_keyboard())


async def on_text(update, context):
    # 绑定向导的文字步骤（地址、服务器、端口、client ID）；不是向导进行中就不理。
    if not update.message or not update.message.text:
        return
    try:
        cid = str(update.effective_chat.id)
    except Exception:
        return
    if cid != str(load_config().TELEGRAM_CHAT_ID):
        return
    st = _BIND_STATE.get(cid)
    if not st:
        return
    text = update.message.text.strip()
    step = st.get("step")
    if step == "email":
        if "@" not in text or "." not in text.rsplit("@", 1)[-1]:
            await update.message.reply_text("地址看起来不对，重新发一下（例如 name@example.com）。")
            return
        st["email"] = text
        if st["provider"] == "custom":
            st["step"] = "server"
            await update.message.reply_text("自建邮箱：请发 IMAP 服务器地址（例如 imap.example.com）。")
        elif st["provider"] == "outlook":
            st["step"] = "client_id"
            await update.message.reply_text(
                "Outlook：请发应用的 client ID（不是密码）。\n"
                "可以直接用 Thunderbird 的公开 client ID，点下面这串复制：\n"
                "<code>9e5f94bc-e8a4-4e73-b8be-63364c29d753</code>\n"
                "授权页会显示 Thunderbird，正常。\n"
                "也可以去 https://entra.microsoft.com 注册自己的应用，把你自己的 client ID 发过来。",
                parse_mode="HTML")
        else:
            await _bind_finish(update, st)
        return
    if step == "server":
        st["server"] = text
        st["step"] = "port"
        await update.message.reply_text("请发 IMAP 端口，一般填 993。")
        return
    if step == "port":
        try:
            st["port"] = int(text)
        except Exception:
            await update.message.reply_text("端口要是数字，例如 993。")
            return
        await _bind_finish(update, st)
        return
    if step == "client_id":
        st["client_id"] = text
        await _bind_finish(update, st)
        return


''')
# 路由：fld/view/del/delok 带页码（老按钮没页码时当第 1 页），加 bind 分支
old_route = '''        elif kind == "fld" and len(parts) == 3:
            await _cb_show_folder(q, int(parts[1]), int(parts[2]))
        elif kind == "view" and len(parts) == 4:
            await _cb_show_mail(q, int(parts[1]), int(parts[2]), int(parts[3]))
        elif kind == "del" and len(parts) == 4:
            await _cb_del_confirm(q, int(parts[1]), int(parts[2]), int(parts[3]))
        elif kind == "delok" and len(parts) == 4:
            await _cb_del_execute(q, int(parts[1]), int(parts[2]), int(parts[3]))'''
if old_route in src:
    src = src.replace(old_route, '''        elif kind == "fld" and len(parts) in (3, 4):
            await _cb_show_folder(q, int(parts[1]), int(parts[2]), int(parts[3]) if len(parts) == 4 else 1)
        elif kind == "view" and len(parts) in (4, 5):
            await _cb_show_mail(q, int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]) if len(parts) == 5 else 1)
        elif kind == "del" and len(parts) in (4, 5):
            await _cb_del_confirm(q, int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]) if len(parts) == 5 else 1)
        elif kind == "delok" and len(parts) in (4, 5):
            await _cb_del_execute(q, int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]) if len(parts) == 5 else 1)
        elif kind == "bind" and len(parts) == 2:
            await _cb_bind_pick(q, parts[1], str(update.effective_chat.id))''', 1)
# 收向导文字：import 里加 MessageHandler、filters，注册里加 on_text
if "MessageHandler" not in src:
    old_imp = "from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler"
    if old_imp not in src:
        print("补丁停：找不到 telegram.ext import，一处都没改。")
        sys.exit(1)
    src = src.replace(old_imp, "from telegram.ext import ApplicationBuilder, CommandHandler, CallbackQueryHandler, MessageHandler, filters", 1)
    old_reg = "            app.add_handler(CallbackQueryHandler(on_callback))"
    if old_reg not in src:
        print("补丁停：找不到 CallbackQueryHandler 注册，一处都没改。")
        sys.exit(1)
    src = src.replace(old_reg, old_reg + "\n            app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))", 1)

# 11e) /help 改成使用说明（带示例，末尾署名），命令列表只留 /menu /help
if "async def cmd_help" not in src:
    help_fn = r'''async def cmd_help(update, context):
    if not await _cmd_check_owner(update):
        return
    await update.message.reply_text(
        "📮 Mail2Telegram 使用方法\n"
        "机器人会自动把新邮件推到这里，只读，不会改邮箱里的信。\n"
        "\n"
        "点 /menu 打开菜单（推荐），也可以直接发命令：\n"
        "/menu 打开菜单\n"
        "/ls 看邮箱列表\n"
        "/show 3 1 8 看 3 号邮箱 1 号文件夹最新 8 封\n"
        "/read 3 1 7 看 3 号邮箱 1 号文件夹第 7 封全文\n"
        "/del 3 1 7 删一封信（要再发 /delok 确认）\n"
        "/rmmail 3 解绑 3 号邮箱（要再发 /rmmailok 确认）\n"
        "\n"
        "绑定新邮箱：在菜单里点 ➕ 绑定邮箱，按提示填地址；密码那步去服务器上完成。\n"
        "加邮箱、改配置在服务器上跑 tge 选 2；看运行状态按菜单里的 ▶️/⏸️。\n"
        "\n"
        "By djkyc编写")


'''
    a = src.find("async def cmd_start")
    if a < 0:
        print("补丁停：找不到 cmd_start，一处都没改。")
        sys.exit(1)
    src = src[:a] + help_fn + src[a:]
    old_help_reg = 'app.add_handler(CommandHandler("help", cmd_start))'
    if old_help_reg not in src:
        print("补丁停：找不到 help 注册，一处都没改。")
        sys.exit(1)
    src = src.replace(old_help_reg, 'app.add_handler(CommandHandler("help", cmd_help))', 1)
# 命令列表只留 /menu /help（其余命令照样能打，只是菜单里不占位置）
if 'BotCommand("ls", "邮箱列表")' in src:
    a = src.find("app.bot.set_my_commands([")
    b = src.find("]))", a)
    if a < 0 or b < 0:
        print("补丁停：找不到 set_my_commands，一处都没改。")
        sys.exit(1)
    new_cmds = '''app.bot.set_my_commands([
                    BotCommand("menu", "打开菜单"),
                    BotCommand("help", "使用方法"),
                ]))'''
    src = src[:a] + new_cmds + src[b + 3:]
# 12) 菜单 v3：邮箱列表/邮件列表改成 8 封一页、序号对齐；v.cd 进机器人向导；Outlook 提示可点复制。
#     s13 的 main.py 早已打过菜单 v2，patch_main_py 开头的“已打过跳过”会直接返回，
#     上面 11/11b/11d 那些带 if-not-in-src 保护的步骤对它都不再生效，所以这里直接改
#     已经打过补丁的 main.py。下面全是“有旧串才换、没有就跳过”，新装的 main.py 不会误伤。
if "菜单 v3" not in src:
    # 12a) 邮箱列表：换成 8 封一页 + 序号右对齐 + 上一页/下一页（旧版没有 page 参数）
    if "menu:ls:{page - 1}" not in src and "async def _cb_show_mailboxes(" in src and "async def _cb_show_folders(" in src:
        src = _replace_fn(src, "async def _cb_show_mailboxes(", "async def _cb_show_folders(", r'''async def _cb_show_mailboxes(query, page=1):
    config = load_config()
    per_page = 8
    total = len(config.EMAILS)
    pages = max(1, (total + per_page - 1) // per_page)
    page = max(1, min(page, pages))
    start = (page - 1) * per_page
    rows = []
    for i, e in enumerate(config.EMAILS[start:start + per_page], start + 1):
        rows.append([InlineKeyboardButton(f"{i:>2}. {e['EMAIL']}", callback_data=f"mb:{i}")])
    nav = []
    if page > 1:
        nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"menu:ls:{page - 1}"))
    if page < pages:
        nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"menu:ls:{page + 1}"))
    if nav:
        rows.append(nav)
    rows.append([InlineKeyboardButton("↩️ 返回菜单", callback_data="menu")])
    title = "📮 邮箱列表（点一个进文件夹）："
    if pages > 1:
        title = f"📮 邮箱列表（第 {page}/{pages} 页，点一个进文件夹）："
    await _cb_edit(query, title, InlineKeyboardMarkup(rows))


''')
        old_ls_route = '''        elif data == "menu:ls":
            await _cb_show_mailboxes(q)'''
        if old_ls_route in src:
            src = src.replace(old_ls_route, '''        elif data == "menu:ls" or data.startswith("menu:ls:"):
            _pg = 1
            if data.startswith("menu:ls:"):
                try:
                    _pg = int(data.split(":")[2])
                except Exception:
                    _pg = 1
            await _cb_show_mailboxes(q, _pg)''', 1)
    # 12b) 邮件列表：已打过 11b 的 main.py 里还是 5 封一页，改成 8 封一页，序号按总封数对齐
    if "pages = (total - 1) // 5 + 1" in src:
        src = src.replace("pages = (total - 1) // 5 + 1", "pages = (total - 1) // 8 + 1", 1)
        src = src.replace("end = total - (page - 1) * 5", "end = total - (page - 1) * 8", 1)
        src = src.replace("start = max(1, end - 4)", "start = max(1, end - 7)", 1)
    if 'rows.append([InlineKeyboardButton(f"{num}. {subject[:25]}", callback_data=f"view:{midx}:{fidx}:{num}:{page}")])' in src:
        src = src.replace("        start = max(1, end - 7)\n", "        start = max(1, end - 7)\n        w = len(str(total))\n", 1)
        src = src.replace('f"{num}. {subject[:25]}"', 'f"{num:>{w}}. {subject[:25]}"', 1)
    # 12c) 其余“5 封”文案统一改成 8 封（文件夹页、/show 默认条数、帮助示例）
    src = src.replace("点一个看最新 5 封", "点一个看最新 8 封")
    src = src.replace("/show 1 1 5", "/show 1 1 8")
    src = src.replace("/show 3 1 5", "/show 3 1 8")
    src = src.replace("最新 5 封", "最新 8 封")
    src = src.replace("count_n = int(args[2]) if len(args) > 2 else 5", "count_n = int(args[2]) if len(args) > 2 else 8")
    src = src.replace("        count_n = 5", "        count_n = 8")
    # 12d) v.cd 进机器人绑定向导（11d 当年没它，s13 的向导里选不到 v.cd）
    if '("vcd", "v.cd")' not in src:
        if '    ("2925", "2925"),\n    ("outlook", "Outlook/Hotmail"),' in src:
            src = src.replace('    ("2925", "2925"),\n    ("outlook", "Outlook/Hotmail"),', '    ("2925", "2925"),\n    ("vcd", "v.cd"),\n    ("outlook", "Outlook/Hotmail"),', 1)
        if '    if provider == "2925":\n        return "imap.2925.com", 993, False\n' in src:
            src = src.replace('    if provider == "2925":\n        return "imap.2925.com", 993, False\n', '    if provider == "2925":\n        return "imap.2925.com", 993, False\n    if provider == "vcd":\n        return "smtp.mail.v.cd", 993, False\n', 1)
    # 12e) Outlook 提示改成可点复制的 Thunderbird client ID + 可点开的设备码网址（s13 的还是 2950 版旧提示）
    _old_outlook_prompt = r'''            await update.message.reply_text("Outlook：请发 Entra 应用的 client ID（在 entra.microsoft.com 注册后能看到的那串 ID，不是密码）。\n还没有注册的话，先去 entra.microsoft.com 注册一个应用再来。")'''
    if _old_outlook_prompt in src:
        src = src.replace(_old_outlook_prompt, r'''            await update.message.reply_text(
                "Outlook：请发应用的 client ID（不是密码）。\n"
                "可以直接用 Thunderbird 的公开 client ID，点下面这串复制：\n"
                "<code>9e5f94bc-e8a4-4e73-b8be-63364c29d753</code>\n"
                "授权页会显示 Thunderbird，正常。\n"
                "也可以去 https://entra.microsoft.com 注册自己的应用，把你自己的 client ID 发过来。",
                parse_mode="HTML")''', 1)
    _old_outlook_tip = r'''        tip = (f"已记下：{email}（Outlook）。\n去 s13 上跑 tge，选 11，按提示完成设备码授权（在浏览器里开 microsoft.com/devicelogin 输码）。\n授权完在菜单里按 ▶️ 启动运行。")'''
    if _old_outlook_tip in src:
        src = src.replace(_old_outlook_tip, r'''        tip = (f"已记下：{email}（Outlook）。\n去 s13 上跑 tge，选 11，走设备码授权。\n授权时浏览器打开 https://www.microsoft.com/link 输码，用这个 Outlook 账号登录同意。\n授权完在菜单里按 ▶️ 启动运行。")''', 1)
    # 打上 v3 标记，下次 patch_main_py 开头就能跳过
    if "# 菜单 v1：机器人内菜单" in src:
        src = src.replace("# 菜单 v1：机器人内菜单", "# 菜单 v3：邮箱列表/邮件列表 8 封一页，v.cd 进机器人向导，Outlook 提示可点复制\n# 菜单 v1：机器人内菜单", 1)
    else:
        src += "\n# 菜单 v3：邮箱列表/邮件列表 8 封一页，v.cd 进机器人向导，Outlook 提示可点复制\n"
# 13) 重试提醒只发一次：同一轮故障只通知一次，恢复后才重新通知。
#     小众/自建邮箱爱断线，旧逻辑每 10 分钟就往 Telegram 发一次“重试次数达到上限”，刷屏。
#     改成：第一次达到上限才发，之后只记日志；等邮箱恢复成功，下次再失败才重新发。
if "重试提醒只发一次" not in src:
    _old = """    retry_count = 0
    last_count = None
"""
    if _old in src:
        src = src.replace(_old, """    retry_count = 0
    limit_notified = False  # 重试提醒只发一次：同一轮故障只通知一次，恢复后才重新通知
    last_count = None
""", 1)
    _old = """                last_count = count
            retry_count = 0
        except Exception as e:"""
    if _old in src:
        src = src.replace(_old, """                last_count = count
            retry_count = 0
            limit_notified = False
        except Exception as e:""", 1)
    _old = """            logger.error(final_message)
            asyncio.run(send_telegram_message(final_message))
            time.sleep(RETRY_PAUSE)"""
    if _old in src:
        src = src.replace(_old, """            logger.error(final_message)
            if not limit_notified:
                asyncio.run(send_telegram_message(final_message))
                limit_notified = True
            time.sleep(RETRY_PAUSE)""", 1)
# 14) Outlook 绑定提示里的设备码网址改成 https://www.microsoft.com/link（微软返回的 verification_uri 就是这个；devicelogin 那边输码会报“该代码无法工作”）。
if "Outlook 提示用 microsoft.com/link" not in src:
    _old = r'''        tip = (f"已记下：{email}（Outlook）。\n去 s13 上跑 tge，选 11，走设备码授权。\n授权时浏览器打开 https://microsoft.com/devicelogin 输码，用这个 Outlook 账号登录同意。\n授权完在菜单里按 ▶️ 启动运行。")'''
    if _old in src:
        src = src.replace(_old, r'''        tip = (f"已记下：{email}（Outlook）。\n去 s13 上跑 tge，选 11，走设备码授权。\n授权时浏览器打开 https://www.microsoft.com/link 输码，用这个 Outlook 账号登录同意。\n授权完在菜单里按 ▶️ 启动运行。")''', 1)
    src += "\n# Outlook 提示用 microsoft.com/link\n"
# 15) 转发识别 Received 头：Outlook 转发时 To/Delivered-To 写目标邮箱，原收件人只在 Received 头里，
#     上游 get_forwarded_email_info 查不到。补一个从全部邮件头里找本机器人别的邮箱的识别，
#     找到就把通知里的“新邮件来自”写成原邮箱，转发来源一眼能认出来。
if "转发识别 Received 头" not in src:
    _anchor = "def fetch_email(server, msg_num, email_config, folder_name, retry_count=0):"
    if _anchor in src:
        src = src.replace(_anchor, 'def _detect_forwarded_from(email_message, current_email):\n    """转发识别：如果邮件是被本机器人里别的邮箱转过来的，从邮件头里找出原邮箱。\n    Outlook 转发时 To/Delivered-To 写的是目标邮箱，原收件人只留在 Received 头里，\n    上游 get_forwarded_email_info 查不到，所以再扫一遍全部邮件头。"""\n    try:\n        cfg = load_config()\n    except Exception:\n        return None\n    others = []\n    for e in getattr(cfg, "EMAILS", []) or []:\n        addr = (e.get("EMAIL") or "").strip().lower()\n        if addr and addr != (current_email or "").strip().lower():\n            others.append(addr)\n    if not others:\n        return None\n    try:\n        headers = "\\n".join(f"{k}: {v}" for k, v in email_message.items())\n    except Exception:\n        return None\n    low = headers.lower()\n    for addr in others:\n        if addr in low:\n            return addr\n    return None\n\n\n' + _anchor, 1)
    _old = "        original_recipient, original_sender = get_forwarded_email_info(email_message, email_config['EMAIL'])\n\n        if original_recipient and original_sender:\n            account_email = original_recipient\n            from_ = original_sender\n        else:\n            account_email = email_config['EMAIL']"
    if _old in src:
        src = src.replace(_old, "        original_recipient, original_sender = get_forwarded_email_info(email_message, email_config['EMAIL'])\n\n        if original_recipient and original_sender:\n            account_email = original_recipient\n            from_ = original_sender\n        else:\n            # 转发识别：To/Delivered-To 没写原收件人时，再从邮件头里找是不是由本机器人里别的邮箱转过来的。\n            account_email = _detect_forwarded_from(email_message, email_config['EMAIL']) or email_config['EMAIL']", 1)
    src += "\n# 转发识别 Received 头\n"
# 16) 排版美化 验证码代码块：正文多余空行压掉，验证码用 <code> 包起来，Telegram 里点一下就复制。
#     上游 get_email_content 出来的 content 已经是 escape 过的纯文本，数字不受影响，直接在上面套 <code>。
if "排版美化 验证码代码块" not in src:
    _anchor = "def fetch_email(server, msg_num, email_config, folder_name, retry_count=0):"
    if _anchor in src:
        src = src.replace(_anchor, 'def _beautify_content(content):\n    """排版美化：正文里多余的空行压成最多一个，验证码用 <code> 包起来方便点按复制。"""\n    import re as _re\n    content = _re.sub(r"\\n{3,}", "\\n\\n", content)\n    content = _re.sub(r"(验证码[：:\\s]*)(\\d{4,8})", lambda m: m.group(1) + "<code>" + m.group(2) + "</code>", content)\n    content = _re.sub(r"(?m)^(\\d{4,8})$", lambda m: "<code>" + m.group(1) + "</code>", content)\n    return content\n\n\n' + _anchor, 1)
    _old = "        content = get_email_content(email_message)"
    if _old in src:
        src = src.replace(_old, _old + "\n        content = _beautify_content(content)", 1)
    src += "\n# 排版美化 验证码代码块\n"
# 17) 发件人二次解码：上游 get_forwarded_email_info 检测到转发时，会把 from_ 盖回原始的、没解码过的
#     From 头（比如 "Microsoft =?utf-8?b?...?="），通知里就直接露出编码原文。取正文前再解一次，
#     已经解过的再解一次没变化，不影响正常邮件。
if "发件人二次解码" not in src:
    _old = "        content = get_email_content(email_message)"
    if _old in src:
        src = src.replace(_old, "        from_ = decode_header_string(from_)\n" + _old, 1)
    src += "\n# 发件人二次解码\n"
# 18) 垃圾邮件默认发主聊天：上游 send_telegram_message 里，垃圾文件夹的信只有配了 TELEGRAM_JUNK_CHAT_ID 才发，
#     没配就直接跳过（日志里那句“跳过垃圾邮件转发”）。验证码经常进垃圾箱，跳过就收不到。改成没配垃圾聊天 ID
#     时默认发到主聊天 TELEGRAM_CHAT_ID，垃圾邮件也照样推过来。
if "垃圾邮件默认发主聊天" not in src:
    _old = "    if is_junk and (not hasattr(config, 'TELEGRAM_JUNK_CHAT_ID') or not config.TELEGRAM_JUNK_CHAT_ID):\n        logger.info(\"未设置 TELEGRAM_JUNK_CHAT_ID 或为空，跳过垃圾邮件转发\")\n        return"
    if _old in src:
        src = src.replace(_old, "    if is_junk and (not hasattr(config, 'TELEGRAM_JUNK_CHAT_ID') or not config.TELEGRAM_JUNK_CHAT_ID):\n        logger.info(\"未设置 TELEGRAM_JUNK_CHAT_ID，垃圾邮件默认发到主聊天\")", 1)
    _old_broken = "        logger.info(\"未设置 TELEGRAM_JUNK_CHAT_ID，垃圾邮件默认发到主聊天\")\n        return"
    if _old_broken in src:
        src = src.replace(_old_broken, "        logger.info(\"未设置 TELEGRAM_JUNK_CHAT_ID，垃圾邮件默认发到主聊天\")", 1)
    _old2 = "    TELEGRAM_CHAT_ID = config.TELEGRAM_JUNK_CHAT_ID if is_junk else config.TELEGRAM_CHAT_ID"
    if _old2 in src:
        src = src.replace(_old2, "    TELEGRAM_CHAT_ID = (config.TELEGRAM_JUNK_CHAT_ID if is_junk and getattr(config, 'TELEGRAM_JUNK_CHAT_ID', '') else config.TELEGRAM_CHAT_ID)", 1)
    src += "\n# 垃圾邮件默认发主聊天\n"
open(path, "w", encoding="utf-8").write(src)
print("补丁已打：OAuth 登录 + 兼容轮询 v3（每轮新建连接，SELECT 数信 + FETCH 取信，不用 SEARCH/IDLE）+ Telegram 命令（/ls /show /del /rmmail）+ 机器人内菜单（/menu）+ 命令机器人单 loop + 菜单 v2（文件夹中文名/翻页/绑定向导//help）+ 菜单 v3（邮箱列表/邮件列表 8 封一页、v.cd 进机器人向导、Outlook 提示可点复制）+ 重试提醒只发一次（同一轮故障只通知一次）+ Outlook 提示用 microsoft.com/link + 转发识别 Received 头 + 排版美化 验证码代码块 + 发件人二次解码 + 垃圾邮件默认发主聊天")
PYEOF
then
echo "补丁失败，已恢复备份 $bak，main.py 没动。"
cp "$bak" "$DIR/main.py" 2>/dev/null || true
return 1
fi
if ! "$VENV/bin/python" -m py_compile "$DIR/main.py" 2>/dev/null && ! python3 -m py_compile "$DIR/main.py"; then
echo "补丁后 main.py 语法检查没过，已恢复备份，补丁没打。"
cp "$bak" "$DIR/main.py" 2>/dev/null || true
return 1
fi
if [ "$(grep -c "oauth_helper.imap_login" "$DIR/main.py")" -ne 3 ] || grep -q "server.login(email_config\['EMAIL'\], email_config\['PASSWORD'\])" "$DIR/main.py"; then
echo "补丁后核对没过（应有 3 处新登录：监听、轮询、命令各 1 处，0 处旧登录），已恢复备份。"
cp "$bak" "$DIR/main.py" 2>/dev/null || true
return 1
fi
if ! grep -q "_selected_count" "$DIR/main.py" || ! grep -q "run_command_bot" "$DIR/main.py" || grep -q "server\.idle(" "$DIR/main.py" || grep -q "server\.search(" "$DIR/main.py"; then
echo "补丁后核对没过（轮询函数缺失，或还剩 IDLE/SEARCH），已恢复备份。"
cp "$bak" "$DIR/main.py" 2>/dev/null || true
return 1
fi
echo "补丁打好了，备份在 $bak。"
return 0
}

setup_crontab() {
echo ""
local tmp=""
tmp="$(mktemp)" || { echo "建临时文件失败，crontab 没改。"; return 1;}
crontab -l 2>/dev/null | grep -v "check_mail2tg.sh" > "$tmp" || true
printf '%s\n' "@reboot sleep 30; /bin/sh \$HOME/check_mail2tg.sh" >> "$tmp"
printf '%s\n' "*/5 * * * * /bin/sh \$HOME/check_mail2tg.sh" >> "$tmp"
if ! crontab "$tmp"; then
echo "写 crontab 失败了，看门狗没装上，先手动检查 crontab -l。"
rm -f "$tmp"
return 1
fi
rm -f "$tmp"
if crontab -l 2>/dev/null | grep -q "check_mail2tg.sh"; then
echo "crontab 看门狗装好了：@reboot 一条，每 5 分钟一条。"
return 0
else
echo "crontab 写完后查不到看门狗那两行，算失败，别当成装好了。"
return 1
fi
}

remove_crontab() {
local tmp=""
tmp="$(mktemp)" || return 1
crontab -l 2>/dev/null | grep -v "check_mail2tg.sh" > "$tmp" || true
crontab "$tmp" 2>/dev/null || true
rm -f "$tmp"
}

# 给一个 Outlook/Hotmail 邮箱做设备码 OAuth 授权。
# $1=邮箱地址；成功后设置全局 O_CLIENT_ID / O_TENANT，失败返回 1。
# 授权前必须先在 Entra 注册好自己的应用，client ID 在主机终端里填，不要发到聊天里。
setup_outlook_oauth() {
local email="$1" client_id="" tenant=""
if [ ! -f "$DIR/oauth_outlook.py" ] || [ ! -f "$DIR/oauth_helper.py" ]; then
write_oauth_files || return 1
fi
patch_main_py || return 1
echo "先在 Microsoft Entra 注册应用（只做一次）："
echo " entra.microsoft.com > App registrations > New registration，个人账号，"
echo " Redirect URI 选 Public client/native (mobile & desktop) > http://localhost，"
echo " Authentication 里 Allow public client flows 选 Yes，"
echo " API permissions > Office 365 Exchange Online > Delegated > IMAP.AccessAsUser.All，"
echo " 再复制 Application (client) ID。"
read -r -p "Application (client) ID（输入时会显示）: " client_id || true
if [ -z "$client_id" ]; then echo "client ID 没填，授权没做。"; return 1; fi
read -r -p "账号类型：个人 Outlook/Hotmail 直接回车（consumers），公司/学校填 common： " tenant || true
[ -z "$tenant" ] && tenant="consumers"
O_CLIENT_ID="$client_id"; O_TENANT="$tenant"
local py="python3"
[ -x "$VENV/bin/python" ] && py="$VENV/bin/python"
(cd "$DIR" && "$py" oauth_outlook.py "$email" "$client_id" "$tenant")
}

reauthorize_outlook() {
if [ ! -d "$DIR" ]; then echo "还没有 $DIR，先选 1 一键部署。"; return 1; fi
write_oauth_files || return 1
patch_main_py || return 1
local email=""
read -r -p "要重新授权的 Outlook/Hotmail 完整地址: " email || true
case "$email" in
*@*.*);;
*) echo "邮箱格式不对。"; return 1;;
esac
setup_outlook_oauth "$email"
}


# 完成机器人里待绑定的邮箱：机器人向导只填了类型和地址，这里只输密码/授权码（Outlook 走设备码）。
complete_pending_bind() {
  if [ ! -d "$DIR" ]; then echo "还没有 $DIR，先选 1 一键部署。"; return 1; fi
  if [ ! -f "$DIR/pending_bind.json" ]; then echo "没有待绑定的邮箱。先在机器人里点 ➕ 绑定邮箱，按提示填好地址再来。"; return 1; fi
  local py
  rm -f "$DIR/.complete_bind.XXXXXX.py"  # 清掉旧模板留下的字面量文件（FreeBSD mktemp 只认结尾的 XXXXXX）
  py="$(mktemp "$DIR/.complete_bind.XXXXXX")" || return 1
  cat > "$py" <<'PYEOF'
import json, os, sys, subprocess, shutil, time, py_compile
D = sys.argv[1]
pend_path = os.path.join(D, "pending_bind.json")
cfg_path = os.path.join(D, "config.py")
try:
    with open(pend_path, encoding="utf-8") as f:
        pending = json.load(f)
except Exception as e:
    print(f"待绑定文件读不出来：{e}")
    sys.exit(1)
if not isinstance(pending, list) or not pending:
    print("没有待绑定的邮箱。先在机器人里点 ➕ 绑定邮箱，按提示填好地址再来。")
    sys.exit(0)
print("待绑定的邮箱：")
for i, p in enumerate(pending, 1):
    print(f"  {i}) {p.get('email', '?')}（{p.get('provider', '')}，{p.get('imap_server', '')}）")
sel = input("选一个编号完成绑定（直接回车取消），或输 d+编号删除（比如 d2，d0 删全部）：").strip()
if not sel:
    print("取消了。")
    sys.exit(0)
if sel.lower().startswith("d"):
    _num = sel[1:].strip()
    if _num == "0" or _num == "":
        _emails = ", ".join(p.get("email", "?") for p in pending)
        pending.clear()
        with open(pend_path, "w", encoding="utf-8") as f:
            json.dump(pending, f, ensure_ascii=False, indent=2)
        print(f"已删除全部待绑定：{_emails}")
        sys.exit(0)
    try:
        idx = int(_num) - 1
        entry = pending[idx]
    except Exception:
        print("编号不对。")
        sys.exit(1)
    _email = entry.get("email", "?")
    pending.pop(idx)
    with open(pend_path, "w", encoding="utf-8") as f:
        json.dump(pending, f, ensure_ascii=False, indent=2)
    print(f"已删除待绑定：{_email}")
    sys.exit(0)
try:
    idx = int(sel) - 1
    entry = pending[idx]
except Exception:
    print("编号不对。")
    sys.exit(1)
sys.path.insert(0, D)
import config as _cfg
if any(e.get("EMAIL") == entry.get("email") for e in _cfg.EMAILS):
    print(f"{entry.get('email')} 已经绑过了，这条待绑定删掉。")
    pending.pop(idx)
    with open(pend_path, "w", encoding="utf-8") as f:
        json.dump(pending, f, ensure_ascii=False, indent=2)
    sys.exit(0)
if entry.get("use_oauth"):
    cid = (entry.get("client_id") or "").strip()
    if not cid:
        print("这条 Outlook 待绑定没有 client ID，先在机器人里重新走一遍绑定向导填上。")
        sys.exit(1)
    print("Outlook 走设备码授权：按提示在浏览器里开 microsoft.com/link 输码。")
    r = subprocess.run([sys.executable, "oauth_outlook.py", entry["email"], cid], cwd=D)
    if r.returncode != 0:
        print("授权没成功，这条待绑定还留着，修好再来。")
        sys.exit(1)
    new_entry = {"EMAIL": entry["email"], "PASSWORD": "", "IMAP_SERVER": entry["imap_server"], "IMAP_SERVER_PORT": entry.get("imap_port", 993), "USE_OAUTH": True, "OAUTH_TENANT": entry.get("tenant", "consumers"), "OAUTH_CLIENT_ID": cid}
else:
    _label = "客户端凭据" if entry.get("imap_server") == "smtp.mail.v.cd" else "密码/授权码"
    pw = input(f"{_label}（输入时会显示）：").strip()
    if not pw:
        print("没填密码，取消了。")
        sys.exit(0)
    new_entry = {"EMAIL": entry["email"], "PASSWORD": pw, "IMAP_SERVER": entry["imap_server"], "IMAP_SERVER_PORT": entry.get("imap_port", 993)}
bak = cfg_path + ".bak." + time.strftime("%Y%m%d%H%M%S")
shutil.copy2(cfg_path, bak)
emails = list(_cfg.EMAILS) + [new_entry]
lines = ["EMAILS = ["]
for e in emails:
    lines.append("    {")
    for k, v in e.items():
        lines.append(f"        {k!r}: {v!r},")
    lines.append("    },")
lines.append("]")
for name in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_JUNK_CHAT_ID", "RETRY_LIMIT", "RETRY_DELAY", "RETRY_PAUSE", "RECONNECT_INTERVAL", "POLL_INTERVAL"):
    if hasattr(_cfg, name):
        lines.append(f"{name} = {getattr(_cfg, name)!r}")
tmp = cfg_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o600)
py_compile.compile(tmp, doraise=True)
os.replace(tmp, cfg_path)
pending.pop(idx)
with open(pend_path, "w", encoding="utf-8") as f:
    json.dump(pending, f, ensure_ascii=False, indent=2)
os.chmod(pend_path, 0o600)
print(f"绑好了：{entry['email']}。去机器人里按 ▶️ 启动运行，新邮箱就开始推送了。")
PYEOF
  python3 "$py" "$DIR"
  local rc=$?
  rm -f "$py"
  return $rc
}

# 选邮箱服务商，输出 host、port、密码提示到全局变量 P_HOST P_PORT P_HINT P_USE_OAUTH，失败返回 1
pick_provider() {
P_USE_OAUTH=0; O_CLIENT_ID=""; O_TENANT="consumers"
echo "选邮箱服务商："
echo " 1) Gmail"
echo " 2) QQ 邮箱"
echo " 3) 163 邮箱"
echo " 4) 新浪 sina"
echo " 5) cock.li"
echo " 6) 2925.com"
echo " 7) Outlook / Hotmail（OAuth，不走密码 IMAP）"
echo " 8) 自建 / 自定义 IMAP（按标准示例填）"
echo " 9) v.cd"
echo " 0) 不加了，结束添加"
local choice=""
read -r -p "输入序号: " choice || true
case "$choice" in
0) return 2;;
1) P_HOST="imap.gmail.com"; P_PORT="993"; P_HINT="Gmail 16 位应用专用密码（不是登录密码；先开两步验证再生成，填时去掉空格。个人账号 IMAP 默认已开）";;
2) P_HOST="imap.qq.com"; P_PORT="993"; P_HINT="QQ 16 位授权码（网页设置里开 IMAP/SMTP 后生成，不是 QQ 密码）";;
3) P_HOST="imap.163.com"; P_PORT="993"; P_HINT="163 16 位客户端授权密码（网页设置里开 IMAP/SMTP 后生成，不是登录密码）";;
4)
echo " 新浪后缀选一个：1) sina.com 2) sina.cn 3) vip.sina.com 4) vip.sina.cn"
local s=""
read -r -p "输入序号: " s || true
case "$s" in
1) P_HOST="imap.sina.com";;
2) P_HOST="imap.sina.cn";;
3) P_HOST="imap.vip.sina.com";;
4) P_HOST="imap.vip.sina.cn";;
*) echo "没选对，跳过这一个。"; return 1;;
esac
P_PORT="993"; P_HINT="新浪 16 位授权码（网页设置里开客户端 POP/IMAP/SMTP 后生成，不是登录密码）"
;;
5) P_HOST="mail.cock.li"; P_PORT="993"; P_HINT="cock.li 账号密码。官网写的服务器就是 mail.cock.li（IMAP/POP），不是 imap.cock.li；993 SSL";;
6) P_HOST="imap.2925.com"; P_PORT="993"; P_HINT="2925 主邮箱密码（登录名填主邮箱完整地址，子邮箱不能直接登录客户端）。如果这台连不上，再试 imap.2925mail.com:993";;
7)
echo "Outlook / Hotmail 走 OAuth，不走密码 IMAP："
echo " 官网设置：outlook.office365.com:993，SSL/TLS，个人账号（@outlook.com / @hotmail.com / @live.com）"
echo " 自 2024-09-16 起只认 OAuth2，密码 IMAP 已停用，填密码必定登录失败。"
echo " 本脚本已带 OAuth 桥接：设备码授权拿令牌，令牌存 oauth_tokens.json（600），"
echo " 过期自动用 refresh_token 刷新，IMAP 用 XOAUTH2 登录。"
echo " 不想现在授权就选 0 跳过，或先用 Outlook 网页版转发到 Gmail/QQ/163。"
if ! ask_yes_no "现在就给一个 Outlook/Hotmail 邮箱做 OAuth 授权吗？"; then
echo "跳过 Outlook，回到选服务商。"
return 1
fi
P_HOST="outlook.office365.com"; P_PORT="993"; P_USE_OAUTH=1
P_HINT="OAuth 令牌（不填密码，填完邮箱地址后走设备码授权，令牌自动存 oauth_tokens.json）"
;;
8)
echo "自建 / 小众邮箱标准示例：IMAP 服务器 imap.example.com，端口 993，加密 SSL/TLS，用户名填完整邮箱地址。"
echo "按你服务商官网给的客户端设置填，别按猜的填。"
read -r -p "IMAP 服务器（例如 imap.example.com 或 mail.example.com）: " P_HOST || true
read -r -p "IMAP 端口（回车默认 993）: " P_PORT || true
[ -z "$P_PORT" ] && P_PORT="993"
P_HINT="这个服务商官网给的密码或授权码（按它官网的客户端设置填）"
if [ -z "$P_HOST" ]; then echo "服务器没填，跳过。"; return 1; fi
case "$P_PORT" in
''|*[!0-9]*) echo "端口不是数字，跳过。"; return 1;;
esac
;;
9) P_HOST="smtp.mail.v.cd"; P_PORT="993"; P_HINT="v.cd 客户端凭据（在 mail.v.cd 邮箱管理 → 该邮箱的客户端配置里生成，只显示一次；不是 API Token，也不是登录密码）。IMAP 服务器 smtp.mail.v.cd:993 SSL（POP3 同主机 995，SMTP 同主机 465，机器人只用 IMAP）";;
*) echo "没选对，跳过这一个。"; return 1;;
esac
return 0
}
# ---- SSH 邮箱管理（菜单 12）：添加 / 删除 / 修改邮箱，不用重填机器人信息 ----
# 写出一次性 Python 助手（放 $DIR 下的隐藏临时文件，退出子菜单时删掉）。
# 用法：python3 助手路径 DIR 操作 [参数...]
#   list                      列出邮箱（编号 + 地址 + 服务器）
#   get N                     取第 N 个邮箱地址
#   is_oauth EMAIL            是 OAuth 返回 1，否则 0
#   oauth_info EMAIL          打印 OAuth 的 client_id 和 tenant（各一行）
#   add EMAIL HOST PORT USE_OAUTH CLIENT_ID TENANT
#                             追加邮箱；密码邮箱在助手里用 input() 现输（可见），OAuth 不输密码
#   delete EMAIL              删除邮箱（剩最后一个不让删）
#   modify EMAIL 字段 [新值]   字段 PASSWORD/IMAP_SERVER/IMAP_SERVER_PORT；PASSWORD 在助手里现输
_write_cfg_helper() {
  local helper
  helper=$(mktemp "$DIR/.cfg_edit.XXXXXX") || return 1
  cat > "$helper" <<'PYEOF'
import sys, os, time, shutil, py_compile, json
D = sys.argv[1]
op = sys.argv[2]
cfg_path = os.path.join(D, "config.py")
sys.path.insert(0, D)
import config as _cfg

def rewrite(emails):
    bak = cfg_path + ".bak." + time.strftime("%Y%m%d%H%M%S")
    shutil.copy2(cfg_path, bak)
    lines = ["EMAILS = ["]
    for e in emails:
        lines.append("    {")
        for k, v in e.items():
            lines.append(f"        {k!r}: {v!r},")
        lines.append("    },")
    lines.append("]")
    for name in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_JUNK_CHAT_ID", "RETRY_LIMIT", "RETRY_DELAY", "RETRY_PAUSE", "RECONNECT_INTERVAL", "POLL_INTERVAL"):
        if hasattr(_cfg, name):
            lines.append(f"{name} = {getattr(_cfg, name)!r}")
    tmp = cfg_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    py_compile.compile(tmp, doraise=True)
    os.replace(tmp, cfg_path)

if op == "list":
    for i, e in enumerate(_cfg.EMAILS, 1):
        print(f"{i}) {e.get('EMAIL')} ({e.get('IMAP_SERVER')}:{e.get('IMAP_SERVER_PORT')})" + (" [OAuth]" if e.get("USE_OAUTH") else ""))
elif op == "get":
    n = int(sys.argv[3])
    if 1 <= n <= len(_cfg.EMAILS):
        print(_cfg.EMAILS[n-1].get("EMAIL"))
    else:
        sys.exit(1)
elif op == "is_oauth":
    email = sys.argv[3]
    for e in _cfg.EMAILS:
        if e.get("EMAIL") == email:
            print("1" if e.get("USE_OAUTH") else "0")
            sys.exit(0)
    sys.exit(1)
elif op == "oauth_info":
    email = sys.argv[3]
    for e in _cfg.EMAILS:
        if e.get("EMAIL") == email and e.get("USE_OAUTH"):
            print(e.get("OAUTH_CLIENT_ID", ""))
            print(e.get("OAUTH_TENANT", "consumers"))
            sys.exit(0)
    sys.exit(1)
elif op == "add":
    email = sys.argv[3]; host = sys.argv[4]; port = int(sys.argv[5])
    use_oauth = sys.argv[6] == "1"
    client_id = sys.argv[7] if len(sys.argv) > 7 else ""
    tenant = sys.argv[8] if len(sys.argv) > 8 else "consumers"
    if any(e.get("EMAIL") == email for e in _cfg.EMAILS):
        print(f"{email} 已经绑过了。")
        sys.exit(1)
    if use_oauth:
        new_entry = {"EMAIL": email, "PASSWORD": "", "IMAP_SERVER": host, "IMAP_SERVER_PORT": port, "USE_OAUTH": True, "OAUTH_TENANT": tenant, "OAUTH_CLIENT_ID": client_id}
    else:
        _label = "客户端凭据" if host == "smtp.mail.v.cd" else "密码/授权码"
        pw = input(f"{_label}（输入时会显示）：").strip()
        if not pw:
            print("没填密码，取消了。")
            sys.exit(0)
        new_entry = {"EMAIL": email, "PASSWORD": pw, "IMAP_SERVER": host, "IMAP_SERVER_PORT": port}
    rewrite(list(_cfg.EMAILS) + [new_entry])
    print(f"加好了：{email}")
elif op == "delete":
    email = sys.argv[3]
    if len(_cfg.EMAILS) <= 1:
        print("就剩这一个邮箱了，不能删光。")
        sys.exit(1)
    remaining = [e for e in _cfg.EMAILS if e.get("EMAIL") != email]
    if len(remaining) == len(_cfg.EMAILS):
        print(f"没找到 {email}。")
        sys.exit(1)
    rewrite(remaining)
    tok_path = os.path.join(D, "oauth_tokens.json")
    if os.path.exists(tok_path):
        try:
            with open(tok_path, encoding="utf-8") as f:
                toks = json.load(f)
            if isinstance(toks, dict) and email in toks:
                del toks[email]
                with open(tok_path, "w", encoding="utf-8") as f:
                    json.dump(toks, f, ensure_ascii=False, indent=2)
                print("这个邮箱的 OAuth 令牌也一起删了。")
        except Exception as e:
            print(f"OAuth 令牌文件没动成：{e}（不影响删除邮箱）")
    print(f"删了绑定：{email}")
elif op == "modify":
    email = sys.argv[3]; field = sys.argv[4]
    idx = None
    for i, e in enumerate(_cfg.EMAILS):
        if e.get("EMAIL") == email:
            idx = i; break
    if idx is None:
        print(f"没找到 {email}。")
        sys.exit(1)
    emails = [dict(e) for e in _cfg.EMAILS]
    if field == "PASSWORD":
        _label = "客户端凭据" if emails[idx].get("IMAP_SERVER") == "smtp.mail.v.cd" else "新密码/授权码"
        pw = input(f"{_label}（输入时会显示）：").strip()
        if not pw:
            print("没填，取消了。")
            sys.exit(0)
        emails[idx]["PASSWORD"] = pw
    elif field == "IMAP_SERVER":
        emails[idx]["IMAP_SERVER"] = sys.argv[5]
    elif field == "IMAP_SERVER_PORT":
        emails[idx]["IMAP_SERVER_PORT"] = int(sys.argv[5])
    else:
        print("不支持的字段。")
        sys.exit(1)
    rewrite(emails)
    print(f"改好了：{email} 的 {field}")
else:
    print("不支持的操作。")
    sys.exit(1)
PYEOF
  echo "$helper"
}

# 后台服务在跑就重启一次，让删除/修改生效（监听线程拿的是旧配置快照，自己不会退出）。
restart_if_running() {
  if is_running; then
    echo "正在重启后台服务，让改动生效…"
    stop_service; start_service
  else
    echo "后台服务没在跑，改动已写进配置，下次启动生效。"
  fi
}

# 用配置里存的 client ID 给指定 Outlook 邮箱重新做设备码授权（不用再填 client ID）。
mailbox_reauth() {
  local helper="$1" py="$2" email="$3"
  local info cid tenant
  info=$("$py" "$helper" "$DIR" oauth_info "$email") || { echo "这个邮箱不是 OAuth，无法重新授权。"; return 1; }
  cid=$(printf '%s\n' "$info" | sed -n '1p')
  tenant=$(printf '%s\n' "$info" | sed -n '2p')
  [ -z "$tenant" ] && tenant="consumers"
  if [ -z "$cid" ]; then echo "配置里没有 client ID，先在机器人里重新走一遍绑定向导。"; return 1; fi
  write_oauth_files || return 1
  patch_main_py || return 1
  (cd "$DIR" && "$py" oauth_outlook.py "$email" "$cid" "$tenant")
}

mailbox_add() {
  local helper="$1" py="$2"
  pick_provider
  local rc=$?
  if [ "$rc" -eq 2 ]; then echo "取消添加。"; return 0; fi
  if [ "$rc" -ne 0 ]; then echo "没选对，回到管理菜单。"; return 0; fi
  local email=""
  read -r -p "邮箱完整地址: " email || true
  case "$email" in
    *@*.*) ;;
    *) echo "邮箱格式不对。"; return 1;;
  esac
  if [ "$P_USE_OAUTH" -eq 1 ]; then
    if ! setup_outlook_oauth "$email"; then echo "OAuth 授权没做成，这个邮箱没加。"; return 1; fi
  else
    echo "提示：$P_HINT"
  fi
  "$py" "$helper" "$DIR" add "$email" "$P_HOST" "$P_PORT" "$P_USE_OAUTH" "$O_CLIENT_ID" "$O_TENANT"
  rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  if is_running; then
    echo "去机器人里按 ▶️ 启动运行，新邮箱就开始推送了。"
  else
    echo "后台服务没在跑，先选 4 启动后台，跑起来后去机器人里按 ▶️。"
  fi
  return 0
}

mailbox_delete() {
  local helper="$1" py="$2"
  echo "现在的邮箱："
  "$py" "$helper" "$DIR" list || return 1
  local sel=""
  read -r -p "要删第几个（输入序号，0 取消）: " sel || true
  [ "$sel" = "0" ] && { echo "取消了。"; return 0; }
  case "$sel" in
    ''|*[!0-9]*) echo "编号不对。"; return 1;;
  esac
  local email
  email=$("$py" "$helper" "$DIR" get "$sel") || { echo "编号不对。"; return 1; }
  if ! ask_yes_no "确定删掉 $email 吗？删了就不再收它的信（服务器上的信还在）"; then echo "取消了。"; return 0; fi
  "$py" "$helper" "$DIR" delete "$email" || return 1
  restart_if_running
  return 0
}

mailbox_modify() {
  local helper="$1" py="$2"
  echo "现在的邮箱："
  "$py" "$helper" "$DIR" list || return 1
  local sel=""
  read -r -p "要改第几个（输入序号，0 取消）: " sel || true
  [ "$sel" = "0" ] && { echo "取消了。"; return 0; }
  case "$sel" in
    ''|*[!0-9]*) echo "编号不对。"; return 1;;
  esac
  local email
  email=$("$py" "$helper" "$DIR" get "$sel") || { echo "编号不对。"; return 1; }
  local is_oauth
  is_oauth=$("$py" "$helper" "$DIR" is_oauth "$email") || { echo "找不到这个邮箱。"; return 1; }
  echo "改 $email："
  echo " 1) 改密码/授权码"
  echo " 2) 改 IMAP 服务器"
  echo " 3) 改 IMAP 端口"
  if [ "$is_oauth" = "1" ]; then echo " 4) Outlook 重新授权（设备码）"; fi
  echo " 0) 取消"
  local m=""
  read -r -p "输入序号: " m || true
  case "$m" in
    1)
      if [ "$is_oauth" = "1" ]; then echo "Outlook 邮箱不用密码，改授权请选 4。"; return 1; fi
      "$py" "$helper" "$DIR" modify "$email" PASSWORD || return 1
      restart_if_running
      ;;
    2)
      local ns=""
      read -r -p "新 IMAP 服务器: " ns || true
      [ -z "$ns" ] && { echo "没填，取消了。"; return 0; }
      "$py" "$helper" "$DIR" modify "$email" IMAP_SERVER "$ns" || return 1
      restart_if_running
      ;;
    3)
      local np=""
      read -r -p "新 IMAP 端口: " np || true
      case "$np" in
        ''|*[!0-9]*) echo "端口不是数字。"; return 1;;
      esac
      "$py" "$helper" "$DIR" modify "$email" IMAP_SERVER_PORT "$np" || return 1
      restart_if_running
      ;;
    4)
      if [ "$is_oauth" != "1" ]; then echo "没这个序号。"; return 1; fi
      mailbox_reauth "$helper" "$py" "$email" || return 1
      echo "重新授权好了，监听下次登录就用新令牌，不用重启。"
      ;;
    0) echo "取消了。"; return 0;;
    *) echo "没这个序号。"; return 1;;
  esac
  return 0
}

manage_mailboxes() {
  if [ ! -f "$DIR/config.py" ]; then echo "还没有配置，先选 1 一键部署。"; return 1; fi
  local helper py
  helper=$(_write_cfg_helper) || return 1
  py="$VENV/bin/python"
  [ -x "$py" ] || py="python3"
  while true; do
    echo ""
    echo "---- 管理邮箱 ----"
    echo " 1) 添加邮箱（Gmail/QQ/163/新浪/cock.li/2925/v.cd/Outlook/自建）"
    echo " 2) 删除邮箱"
    echo " 3) 修改邮箱（密码/服务器/端口/Outlook 重新授权）"
    echo " 0) 返回主菜单"
    local c=""
    read -r -p "输入序号: " c || break
    case "$c" in
      1) mailbox_add "$helper" "$py";;
      2) mailbox_delete "$helper" "$py";;
      3) mailbox_modify "$helper" "$py";;
      0) break;;
      *) echo "没这个序号，重新选。";;
    esac
  done
  rm -f "$helper"
}


configure_wizard() {
echo "一步一步填，Token 和密码输入时会显示在屏幕上，填完后汇总里不会打印出来"
echo "第 1 步：Telegram 机器人"
echo " 先去 @BotFather 建机器人，拿到 Token；再去机器人私聊里发 /start，不然它给你发不了消息。"
local token="" chat_id="" junk_id=""
read -r -p "Bot Token（输入时会显示，输完按回车）: " token || true
echo ""
if [ -z "$token" ]; then echo "Token 没填，配置没写，停在这里了。"; return 1; fi
case "$token" in
*:*)
;;
*)
echo "提醒：Bot Token 一般是 数字:字母 的样子，你填的好像没有冒号。"
if ! ask_yes_no "还要继续用这个 Token 吗？"; then echo "配置没写，回去重填。"; return 1; fi
;;
esac
read -r -p "第 2 步：Telegram 聊天 ID（收邮件的那个数字 ID，例如你自己的用户 ID）: " chat_id || true
case "$chat_id" in
''|*[!0-9-]*) echo "聊天 ID 不是数字，配置没写。"; return 1;;
esac
read -r -p "第 3 步：垃圾邮件聊天 ID（不想收垃圾就直接回车跳过）: " junk_id || true
if [ -n "$junk_id" ]; then
case "$junk_id" in
''|*[!0-9-]*) echo "垃圾邮件 ID 不是数字，配置没写。"; return 1;;
esac
fi

echo "第 4 步：加邮箱，可以加多个，加完选 0 结束"
echo " 建议第一次先加 1-2 个已经拿到授权码的，跑通了再回来加剩下的。"
local entries="" count=0 summary=""
while true; do
pick_provider
local rc=$?
if [ "$rc" -eq 2 ]; then
break
fi
if [ "$rc" -ne 0 ]; then
continue
fi
local email="" pw=""
read -r -p "邮箱完整地址: " email || true
case "$email" in
*@*.*);;
*) echo "邮箱格式不对，跳过这一个。"; continue;;
esac
if [ "${P_USE_OAUTH:-0}" -eq 1 ]; then
echo "OAuth 提示：$P_HINT"
if ! setup_outlook_oauth "$email"; then echo "OAuth 授权没做成，这个邮箱没加。"; continue; fi
entries="$entries
{
'EMAIL': '$(py_escape "$email")',
'PASSWORD': '',
'IMAP_SERVER': '$(py_escape "$P_HOST")',
'IMAP_SERVER_PORT': $P_PORT,
'USE_OAUTH': True,
'OAUTH_TENANT': '$(py_escape "${O_TENANT:-consumers}")',
'OAUTH_CLIENT_ID': '$(py_escape "$O_CLIENT_ID")',
},"
summary="$summary
- $email ($P_HOST:$P_PORT, OAuth)"
count=$((count + 1))
echo "已加入第 $count 个：$email（OAuth）"
if ! ask_yes_no "还要再加一个邮箱吗？"; then
break
fi
continue
fi
echo "密码提示：$P_HINT"
if [ "$P_HOST" = "smtp.mail.v.cd" ]; then
  read -r -p "客户端凭据（输入时会显示，输完按回车）: " pw || true
else
  read -r -p "密码 / 授权码（输入时会显示，输完按回车）: " pw || true
fi
echo ""
if [ -z "$pw" ]; then echo "密码没填，跳过这一个。"; continue; fi
entries="$entries
{
'EMAIL': '$(py_escape "$email")',
'PASSWORD': '$(py_escape "$pw")',
'IMAP_SERVER': '$(py_escape "$P_HOST")',
'IMAP_SERVER_PORT': $P_PORT,
},"
summary="$summary
- $email ($P_HOST:$P_PORT)"
count=$((count + 1))
echo "已加入第 $count 个：$email"
if ! ask_yes_no "还要再加一个邮箱吗？"; then
break
fi
done

if [ "$count" -eq 0 ]; then
echo "一个邮箱都没加，配置没写。"
return 1
fi

if [ -f "$CONFIG" ]; then
cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)" && echo "旧 config.py 已备份到同目录的.bak 文件。"
fi
cat > "$CONFIG" <<EOF
EMAILS = [$entries
]

TELEGRAM_BOT_TOKEN = '$(py_escape "$token")'
TELEGRAM_CHAT_ID = '$chat_id'
TELEGRAM_JUNK_CHAT_ID = '$junk_id'

RETRY_LIMIT = 5
RETRY_DELAY = 5
RECONNECT_INTERVAL = 1800
RETRY_PAUSE = 600
EOF
chmod 600 "$CONFIG"
if ! "$VENV/bin/python" -m py_compile "$CONFIG" 2>/dev/null && ! python3 -m py_compile "$CONFIG" 2>/dev/null; then
echo "config.py 写完后语法检查没过，别启动，先检查上面那一步是不是有特殊字符。"
return 1
fi
echo "配置写好了，共 $count 个邮箱，Token 和密码都没有打印出来：$summary"
echo "聊天 ID：$chat_id"
return 0
}

start_service() {
if is_running; then
echo "已经在跑了，不用重复启动。"
return 0
fi
if [ ! -f "$CONFIG" ]; then
echo "还没有 $CONFIG，先选 2 走配置向导。"
return 1
fi
write_helpers || return 1
if [ ! -x "$DIR/start.sh" ]; then
echo "还没有启动脚本，先选 1 走一键部署，或者先写后台脚本。"
return 1
fi
write_oauth_files || return 1
patch_main_py || return 1
echo "正在启动后台服务..."
(cd "$DIR" && ./start.sh)
sleep 3
if is_running; then
echo "启动成功，正在跑了。日志：$DIR/mail2tg.log"
return 0
else
echo "启动后查不到进程，算失败，看日志最后 20 行："
tail -20 "$DIR/mail2tg.log" 2>/dev/null || echo "还没有 mail2tg.log"
tail -20 "$DIR/log/email_checker.log" 2>/dev/null || true
return 1
fi
}

stop_service() {
if ! is_running; then
echo "本来就没在跑。"
else
pkill -f "mail2tg/main.py" || true
sleep 2
if is_running; then
echo "停是停了命令发了，但进程还在，手动再看一下 pgrep -f mail2tg/main.py。"
return 1
fi
echo "已经停掉了。"
fi
if ask_watchdog_remove; then
remove_crontab
echo "看门狗 crontab 已去掉。"
else
echo "看门狗还留着，5 分钟后它会再把服务拉起来，这就是你选的‘只停一次’。"
fi
return 0
}

show_status() {
echo "---- 状态 ----"
echo "目录：$DIR（存在：$( [ -d "$DIR" ] && echo 是 || echo 否)）"
echo "虚拟环境：$VENV（存在：$( [ -x "$VENV/bin/python" ] && echo 是 || echo 否)）"
echo "配置：$CONFIG（存在：$( [ -f "$CONFIG" ] && echo 是 || echo 否)，权限：$( ls -l "$CONFIG" 2>/dev/null | awk '{print $1}' || echo -)）"
if is_running; then
echo "进程：在跑"
pgrep -af "mail2tg/main.py" || true
else
echo "进程：没在跑"
fi
echo "crontab 看门狗："
crontab -l 2>/dev/null | grep "check_mail2tg.sh" || echo "（没有）"
echo "---- 最近日志（mail2tg.log 最后 20 行）----"
tail -20 "$DIR/mail2tg.log" 2>/dev/null || echo "（还没有 mail2tg.log）"
return 0
}

foreground_test() {
if is_running; then
echo "已经有一个 mail2tg 在跑了（后台或另一个前台），再开一个会让同一封信推两次。"
if ! ask_yes_no "确定还要再开一个前台测试吗？"; then echo "先停掉在跑的那个（菜单 5，或 Ctrl+C 停掉另一个前台）再测。"; return 1; fi
fi
if [ ! -f "$CONFIG" ]; then
echo "还没有 $CONFIG，先选 2 走配置向导。"
return 1
fi
write_oauth_files || return 1
patch_main_py || return 1
local py="python3"
[ -x "$VENV/bin/python" ] && py="$VENV/bin/python"
echo "前台测试开始：TG 收到“登录成功”就说明通了，再给邮箱发封测试信看推不推。"
echo "想停就按 Ctrl+C，停了不会进后台。"
(cd "$DIR" && LANGUAGE=Chinese TIMEZONE=Asia/Shanghai ENABLE_LOGGING=true ENABLE_EVC=false "$py" "$DIR/main.py")
echo "前台测试已退出。"
return 0
}

setup_shortcut() {
local quiet=0
[ "$1" = "quiet" ] && quiet=1
local src=""
if [ -f "$HOME/mail2tg.sh" ]; then src="$HOME/mail2tg.sh";
elif [ -f "$0" ]; then src="$0"; fi
if [ -z "$src" ]; then [ "$quiet" -eq 0 ] && echo "找不到 mail2tg.sh 文件，快捷键 tge 没装上。"; return 1; fi
mkdir -p "$HOME/bin" 2>/dev/null || return 1
ln -sf "$src" "$HOME/bin/tge" 2>/dev/null || return 1
chmod +x "$src" 2>/dev/null || true
local rc=""
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
touch "$rc" 2>/dev/null || continue
if ! grep -Fq 'export PATH="$HOME/bin:$PATH"' "$rc" 2>/dev/null; then
echo 'export PATH="$HOME/bin:$PATH"' >> "$rc" || true
fi
done
if [ -f "$HOME/.zshrc" ] && ! grep -Fq 'export PATH="$HOME/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc" || true
fi
if [ "$quiet" -eq 0 ]; then
echo -e "快捷键已装好：退出后输入 \033[1;32mtge\033[0m 就能再进菜单。"
echo -e "注意：当前这个终端要重登一次 SSH，或先跑 export PATH=\"\$HOME/bin:\$PATH\"，\033[1;32mtge\033[0m 才直接生效；也可以直接跑 ~/bin/tge。"
fi
return 0
}

one_click_deploy() {
echo "================ 一键部署 ================"
echo "按顺序走：权限 → Python → 拉代码装依赖 → 写后台脚本 → 填配置 → 启动"
step_binexec || { echo "一键部署停在第 1 步了。"; return 1;}
step_python || { echo "一键部署停在第 2 步了。"; return 1;}
step_install || { echo "一键部署停在第 3 步了。"; return 1;}
write_helpers || { echo "一键部署停在写后台脚本了。"; return 1;}
write_oauth_files || { echo "一键部署停在写 OAuth 桥接文件了。"; return 1;}
patch_main_py || { echo "一键部署停在打 main.py 补丁了。"; return 1;}
setup_shortcut || echo "快捷键 tge 没装上，不影响部署，退出后用 ./mail2tg.sh 也能进菜单。"
configure_wizard || { echo "一键部署停在配置向导了，依赖和脚本已经在了，改好再选 2 重填就行。"; return 1;}
echo "配置好了，下面选怎么启动："
echo " 1) 先前台测试（推荐第一次，Ctrl+C 停）"
echo " 2) 直接启动后台 + 装看门狗"
echo " 3) 先不启动，只保存配置"
local s=""
read -r -p "输入序号: " s || true
case "$s" in
1)
foreground_test
if ask_yes_no "前台测试通了吗？通了就现在转后台 + 装看门狗？"; then
setup_crontab || return 1
start_service || return 1
else
echo "先不转后台，配置已保存，修好再选 4 启动。"
fi
;;
2)
setup_crontab || return 1
start_service || return 1
;;
3)
echo "只保存了配置，没启动。以后选 4 启动，选 8 装看门狗。"
;;
*)
echo "没选对，默认只保存配置，没启动。"
;;
esac
echo "一键部署走到头了。用菜单 7 查状态、看日志确认。"
return 0
}

uninstall_service() {
echo "一键卸载会：停服务、去掉看门狗 crontab、删掉 ~/mail2tg、~/mail2tg-venv、~/check_mail2tg.sh、~/bin/tge，以及本脚本 ~/mail2tg.sh 本身。"
echo "注意：删完要重装，得重新下载 GitHub 那条。backups、s5.sh、muse2api 这些不相关的文件和目录不会动。"
read -r -p "确认卸载请输入 yes： " ans || true
if [ "$ans" != "yes" ]; then
echo "没输入 yes，取消卸载。"
return 0
fi
pkill -f "mail2tg/main.py" 2>/dev/null || true
remove_crontab
rm -rf "$DIR" "$VENV" "$WATCHDOG"
rm -f "$HOME/bin/tge"
rm -f "$HOME/mail2tg.sh"
UNINSTALLED=1
echo "卸载完了，连本脚本 ~/mail2tg.sh 和快捷键 tge 也已删掉。Outlook 的 OAuth 令牌在 ~/mail2tg/oauth_tokens.json 里，也一起删了，重装后要重新授权。如果以后不用这些邮箱授权码了，记得去各邮箱后台吊销授权码 / 应用专用密码，删本地文件不等于吊销。"
return 0
}

setup_shortcut quiet || true
UNINSTALLED=0
while true; do
echo ""
echo "================ Mail2Telegram Serv00/Ct8 Vps一键部署 ================"
echo "一键部署脚本 By: djkyc"
if [ "$UNINSTALLED" -eq 1 ]; then
echo "提示：已删除清理，欢迎再次使用拉取命令重装"
else
echo -e "提示：退出后输入 \033[1;32mtge\033[0m 可再次呼出菜单"
fi
echo " 1) 一键部署（一步一步提示：权限 → 依赖 → 机器人 → 邮箱 → 启动）"
echo " 2) 只填 / 改配置（重新走机器人 + 邮箱向导，旧配置会自动备份）"
echo " 3) 前台测试运行（Ctrl+C 停止，不进后台）"
echo " 4) 启动后台服务"
echo " 5) 停止服务"
echo " 6) 重启服务"
echo " 7) 查看状态和日志"
echo " 8) 设置 / 检查看门狗 crontab"
echo " 9) 一键卸载"
echo " 10) Outlook OAuth 重新授权（令牌过期/被吊销时用）"
echo " 11) 完成机器人待绑定（机器人里填好地址后，在这里只输密码/授权码）"
echo " 12) 管理邮箱（添加 / 删除 / 修改邮箱，不用重填机器人）"
echo " 0) 退出"
read -r -p "输入序号: " choice || break
case "$choice" in
1) one_click_deploy; pause;;
2)
if [ ! -d "$DIR" ]; then echo "还没有 $DIR，先选 1 一键部署。"; else
if [ ! -x "$VENV/bin/python" ]; then echo "还没有虚拟环境，先选 1 一键部署。"; else
configure_wizard
fi
fi
pause
;;
3) foreground_test; pause;;
4) start_service; pause;;
5) stop_service; pause;;
6) stop_service; start_service; pause;;
7) show_status; pause;;
8) setup_crontab; pause;;
9) uninstall_service; pause;;
10) reauthorize_outlook; pause;;
11) complete_pending_bind; pause;;
12) manage_mailboxes; pause;;
0)
if [ "$UNINSTALLED" -eq 1 ]; then
echo "退出。已经删除清理了，欢迎再次使用："
echo "curl -Ls https://raw.githubusercontent.com/djkyc/serv00-ct8/refs/heads/main/tgeamil/mail2tg.sh -o ~/mail2tg.sh && chmod +x ~/mail2tg.sh && ./mail2tg.sh"
else
echo -e "退出。以后输入 \033[1;32mtge\033[0m 可再次呼出菜单。"
fi
break;;
*) echo "没这个序号，重新选。";;
esac
done
