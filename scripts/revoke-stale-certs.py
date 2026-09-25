#!/usr/bin/env python3
"""吊销 CI 自己攒下来的开发证书。

每次 `xcodebuild -allowProvisioningUpdates` 归档，Apple 都会新建一张名为
"Created via API" 的开发证书。账号的证书配额不大，攒满之后归档直接失败：

    error: Choose a certificate to revoke. Your account has reached the
    maximum number of certificates.

这些证书没有别的用处 —— 下次构建需要时会重新建一张。所以每次归档前先清掉。

只动 displayName 正好是 "Created via API" 的 DEVELOPMENT 证书：开发者本人的证书
（displayName 是真实姓名）和分发证书都不碰 —— 后者只有一张，吊销了就没法归档了。

需要环境变量 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com"
KEEP_TYPES = {"IOS_DISTRIBUTION", "DISTRIBUTION"}
STALE_NAME = "Created via API"


def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    with open(os.environ["ASC_KEY_PATH"]) as f:
        private_key = f.read()
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, private_key, algorithm="ES256",
                      headers={"kid": key_id, "typ": "JWT"})


def request(method, path):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    status, body = request(
        "GET", "/v1/certificates?limit=200&fields[certificates]=certificateType,displayName")
    if status != 200:
        # 清不掉不该拦住构建 —— 配额没满的话归档照样能过。
        print(f"::warning::无法读取证书列表（HTTP {status}），跳过清理")
        return 0

    certificates = json.loads(body)["data"]
    stale = [c["id"] for c in certificates
             if c["attributes"].get("certificateType") not in KEEP_TYPES
             and c["attributes"].get("displayName") == STALE_NAME]

    print(f"证书共 {len(certificates)} 张，其中 CI 遗留 {len(stale)} 张")
    for cid in stale:
        status, _ = request("DELETE", f"/v1/certificates/{cid}")
        print(f"  revoke {cid} -> {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
