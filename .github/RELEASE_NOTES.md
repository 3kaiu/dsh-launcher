# 安装

方式一(推荐,一条命令自动完成):

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

方式二(手动下载发行包):

```bash
curl -LO https://github.com/3kaiu/dsh-pwa/releases/latest/download/dsh-pwa.zip && unzip dsh-pwa.zip && bash install.sh
```

安装完成会自动打开 dsh 页面;Safari 菜单栏 文件 → 添加到程序坞,应用名 **DeepSeek Harness**。

升级:重跑 install.sh(自动跟随官方 node LTS / dsh latest)。