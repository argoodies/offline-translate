#!/usr/bin/env bash
# 证明这个 app 确实碰不到网络。
#
# 「不发网络请求」是 QW! 商店页上的第一句话，也是它存在的理由。光靠人肉 review
# 保不住：某天有人加一个 AsyncImage、一个埋点 SDK，或者 MarkdownUI 换个默认的
# image provider 去拉远端图片，代码 diff 里看不出什么，但 app 在中国区就会弹
# 「想要使用无线局域网与蜂窝网络」—— 那一刻这句话就成假的了。
#
# 所以改成构建期检查：直接看链接出来的可执行文件里有没有网络相关的符号和
# 依赖。有就让构建失败。
#
# 用法: ./scripts/check-no-network.sh <path/to/QW.app>
set -euo pipefail

APP="${1:?用法: check-no-network.sh <QW.app>}"
BIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

echo "==> 检查 $BIN"

# 直接链接进来的库。系统框架里 Foundation 自己会间接用到 CFNetwork，
# 所以这里只看**我们这个二进制自己**的 load command，不递归。
FORBIDDEN_LIBS='CFNetwork|/Network\.framework|libnetwork|Alamofire|FirebaseCore|GoogleAnalytics'
if otool -L "$BIN" | tail -n +2 | grep -Ei "$FORBIDDEN_LIBS"; then
    echo "错误：二进制直接链接了网络库（上面那几行）。" >&2
    exit 1
fi

# 未定义符号 —— 真正调用了什么。比看链接哪些库准：Foundation 一直在那儿，
# 但只有真写了 URLSession 才会在这里留下记号。
FORBIDDEN_SYMS='NSURLSession|NSURLConnection|CFURLRequest|CFHTTP|_nw_connection|_nw_endpoint|NWConnection|NWPathMonitor|_SCNetworkReachability'
if nm -u "$BIN" 2>/dev/null | grep -E "$FORBIDDEN_SYMS"; then
    echo "错误：二进制引用了网络 API（上面那几行）。" >&2
    echo "如果这是有意加的，先改掉商店描述和隐私页里「不发任何网络请求」那句话。" >&2
    exit 1
fi

# Info.plist 里也不该出现任何网络相关的声明 —— 有 NSAppTransportSecurity
# 或者本地网络用途说明，本身就说明有人打算联网。
if /usr/libexec/PlistBuddy -c 'Print' "$APP/Info.plist" \
    | grep -Ei 'NSAppTransportSecurity|NSLocalNetworkUsageDescription|NSBonjourServices'; then
    echo "错误：Info.plist 里有网络相关的声明。" >&2
    exit 1
fi

echo "==> 干净：没有网络库、没有网络符号、Info.plist 里也没有网络声明。"
