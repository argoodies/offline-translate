#!/usr/bin/env bash
# 生成分发页的静态内容：安装页 + OTA 清单 + .ipa 本体。
#
# 用法：make-install-site.sh <ipa 路径> <主机名> <build 号>
#
# OTA 安装（itms-services:）要求清单走 HTTPS，fly.dev 自带证书，所以这条路是通的。
# 注意这只对 ad-hoc / 企业签名有效：app-store 方式导出的包下载下来装不上，
# 那种包只有 App Store 和 TestFlight 能装。
set -euo pipefail

IPA="${1:?用法: make-install-site.sh <ipa> <host> <build>}"
HOST="${2:?缺少主机名}"
BUILD="${3:?缺少 build 号}"

BUNDLE_ID="dev.expo.client.cdk6asipshwbwfmintawzxd2uwcbu5iejxt3t4gqkoq4o"
VERSION="0.1.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${ROOT}/distribution/site"

rm -rf "${SITE}"
mkdir -p "${SITE}"
cp "${IPA}" "${SITE}/QW.ipa"

SIZE_MB=$(( $(wc -c < "${SITE}/QW.ipa") / 1024 / 1024 ))

cat > "${SITE}/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>https://${HOST}/QW.ipa</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>${BUNDLE_ID}</string>
        <key>bundle-version</key><string>${VERSION}</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>QW</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

cat > "${SITE}/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>QW ${VERSION} (${BUILD})</title>
<style>
  :root { color-scheme: light dark; --ink: #000; --dim: #6b6b6b; --bg: #fff; --line: #e0e0e0; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #fff; --dim: #8e8e8e; --bg: #000; --line: #2a2a2a; }
  }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: var(--bg); color: var(--ink);
    font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    padding: 40px 24px; box-sizing: border-box;
  }
  main { max-width: 340px; width: 100%; text-align: center; }
  h1 { font-size: 34px; letter-spacing: -0.02em; margin: 0 0 6px; }
  .ver { color: var(--dim); font-size: 15px; margin: 0 0 32px; }
  a.install {
    display: block; background: var(--ink); color: var(--bg); text-decoration: none;
    padding: 15px; border-radius: 13px; font-weight: 600;
  }
  a.file { display: block; margin-top: 14px; color: var(--dim); font-size: 14px; }
  .note {
    margin-top: 32px; padding-top: 20px; border-top: 1px solid var(--line);
    color: var(--dim); font-size: 13px; text-align: left;
  }
  .note p { margin: 0 0 8px; }
</style>
<main>
  <h1>QW</h1>
  <p class="ver">${VERSION} (${BUILD}) · ${SIZE_MB} MB</p>

  <a class="install" href="itms-services://?action=download-manifest&amp;url=https://${HOST}/manifest.plist">Install on this iPhone</a>
  <a class="file" href="/QW.ipa">Download .ipa</a>

  <div class="note">
    <p>Open this page in <strong>Safari on the device</strong> — the install link does nothing in other browsers.</p>
    <p>This is an ad-hoc build. It only installs on devices registered to the developer account.</p>
    <p>Settings &rsaquo; General &rsaquo; VPN &amp; Device Management to trust it on first launch.</p>
  </div>
</main>
HTML

echo "site 已生成：${SITE} (QW.ipa ${SIZE_MB} MB)"
