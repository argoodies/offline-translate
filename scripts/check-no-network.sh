#!/usr/bin/env bash
# 证明这个 app 确实碰不到网络。
#
# 「不发任何网络请求」是 QW! 商店页上的第一句话，也是它存在的理由。光靠人肉 review
# 保不住：某天有人加一个 AsyncImage、一个埋点 SDK，或者哪个依赖换了默认实现去拉
# 远端资源，代码 diff 里看不出什么，但 app 在中国区就会弹「想要使用无线局域网与
# 蜂窝网络」—— 那一刻这句话就成假的了。
#
# 分两道：
#   1. 源码扫一遍。对我们自己写的代码，这一道最准 —— 一个符号都不许有。
#   2. 二进制比基线。依赖里带进来的网络代码拦不住（链接进来但走不到），
#      所以不是「有就挂」，而是「跟 network-symbols.allow 对不上就挂」。
#      基线那份文件里每一行都写清楚了凭什么放行。
#
# 用法: ./scripts/check-no-network.sh <path/to/QW.app>
set -euo pipefail

APP="${1:?用法: check-no-network.sh <QW.app>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW="$ROOT/scripts/network-symbols.allow"
BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

fail() { echo "错误：$1" >&2; exit 1; }

# ---- 1. 源码 ----------------------------------------------------------------
echo "==> 扫 Sources/"
SRC_FORBIDDEN='URLSession|URLConnection|NWConnection|NWPathMonitor|NWListener|AsyncImage|CFSocket|SCNetworkReachability|import Network$'
# 整行注释不算 —— 解释「为什么不用 URLSession」的注释里必然会写出 URLSession，
# 那种命中全是噪音，留着这道检查就会被当成狼来了。
SRC_HITS="$(grep -rnE "$SRC_FORBIDDEN" "$ROOT/Sources" --include='*.swift' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$SRC_HITS" ]]; then
    echo "$SRC_HITS" >&2
    fail "源码里出现了网络 API（上面那几行）。这个 app 不联网。"
fi

# ---- 2. 链接了哪些库 --------------------------------------------------------
echo "==> 检查 $BIN"
# 只看这个二进制自己的 load command，不递归 —— Foundation 自己会间接用到
# CFNetwork，递归下去无论如何都会命中。
if otool -L "$BIN" | tail -n +2 | grep -Ei 'CFNetwork|/Network\.framework|libnetwork|Alamofire|FirebaseCore|GoogleAnalytics'; then
    fail "二进制直接链接了网络库（上面那几行）。"
fi

# ---- 3. 引用了哪些网络符号 --------------------------------------------------
SYM_PATTERN='NSURLSession|NSURLConnection|CFURLRequest|CFHTTP|_nw_connection|_nw_endpoint|NWPathMonitor|_SCNetworkReachability'
FOUND="$(nm -u "$BIN" 2>/dev/null | grep -E "$SYM_PATTERN" | sort -u || true)"
ALLOWED="$(grep -vE '^\s*(#|$)' "$ALLOW" | sort -u)"
NEW="$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED"))"

if [[ -n "$NEW" ]]; then
    echo "$NEW" >&2
    echo >&2
    fail "上面这些网络符号不在 scripts/network-symbols.allow 里。
如果是某个依赖带进来、确认走不到的，把它加进那份文件并写明凭什么放行。
如果是我们自己要联网 —— 先去改掉商店描述和隐私页里「不发任何网络请求」那句话。"
fi

# 基线里列了但二进制里已经没有的，说明依赖变了，顺手提醒清掉，别让它一直挂着
# 假装还在挡什么。
STALE="$(comm -13 <(echo "$FOUND") <(echo "$ALLOWED"))"
[[ -n "$STALE" ]] && echo "提示：network-symbols.allow 里这几行已经用不上了，可以删：" && echo "$STALE"

# ---- 4. Info.plist ----------------------------------------------------------
# 有 NSAppTransportSecurity 或者本地网络用途说明，本身就说明有人打算联网。
if /usr/libexec/PlistBuddy -c 'Print' "$APP/Info.plist" \
    | grep -Ei 'NSAppTransportSecurity|NSLocalNetworkUsageDescription|NSBonjourServices'; then
    fail "Info.plist 里有网络相关的声明。"
fi

echo "==> 干净：源码无网络 API，二进制符号与基线一致，Info.plist 无网络声明。"
