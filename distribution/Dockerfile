FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
# site/ 是 CI 现生成的：install.html、manifest.plist 和那个 500 多 MB 的 .ipa。
# 仓库里不存 .ipa（GitHub 单文件上限 100 MB），所以本地 build 这个镜像会得到一个空页面。
COPY site/ /usr/share/nginx/html/
