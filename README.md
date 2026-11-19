# Catlash

Catlash 是基于 Mihomo 的原生 iOS 代理客户端。它使用 SwiftUI 构建界面，通过 Network Extension 在 iPhone 上运行 VPN 隧道，支持 iOS 18 及以上版本。

## 主要功能

- 导入 YAML 文件或订阅，使用 iCloud Drive 同步配置。
- 在规则、全局和直连模式之间切换。在策略组内选择节点、测量延迟、查看出口 IP 和网络类型。
- 浏览和编辑分流规则，查看当前内核使用的配置，在线更新节点和规则资源。
- 查看连接、流量与 DNS 查询记录，测量网络质量和 UDP 可达性。

## 从源码构建

在安装了 Xcode 的 Mac 上准备 Go 1.27.1、Python 3、Ruby 和 xcodeproj gem。克隆仓库时一并获取固定版本的 Mihomo 子模块。

```sh
git clone --recurse-submodules https://github.com/mashpolo/catlash.git
cd catlash
gem install xcodeproj
```

首次构建前，从上游下载三个地区与 ASN 数据文件并校验 SHA-256。在仓库根目录执行以下命令。生成的应用会随安装包携带这些文件，首次启动 VPN 时可离线读取。

```sh
(
  set -eu
  geo_dir="$PWD/Resources/Geo"
  staging=$(mktemp -d)
  trap 'rm -rf "$staging"' EXIT
  cd "$staging"
  release=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest
  for asset in country.mmdb geoip.dat GeoLite2-ASN.mmdb; do
    curl -fLsS --retry 3 -O "$release/$asset"
    curl -fLsS --retry 3 -O "$release/$asset.sha256sum"
    shasum -a 256 -c "$asset.sha256sum"
  done
  cp country.mmdb "$geo_dir/Country.mmdb"
  cp geoip.dat "$geo_dir/GeoIP.dat"
  cp GeoLite2-ASN.mmdb "$geo_dir/ASN.mmdb"
)
```

构建 Mihomo 框架并生成 Xcode 工程：

```sh
GO_BIN="$(command -v go)" ./build-core.sh
ruby generate-project.rb
open MihomoProbe.xcodeproj
```

在 Xcode 中选择 `FlClashIOSProbe` scheme。安装到自己的 iPhone 时，需要为主应用和 Packet Tunnel 扩展配置开发团队、可用的 Bundle ID、App Groups 和 Network Extension 权限。使用自有 App Group 时，两个目标的 entitlements 与 Swift 代码中访问共享容器的标识须一致。

## 许可证与数据来源

Catlash 使用 GNU GPL v3。Mihomo 和其他依赖保留各自的许可证。[项目许可证](LICENSE) · [Mihomo 源码](https://github.com/chen08209/Clash.Meta)

地区数据库从 MetaCubeX 发布的资源获取。相关数据来自 Loyalsoldier/geoip 项目及其列出的贡献者。This product includes GeoLite Data created by MaxMind. [MetaCubeX 发布页](https://github.com/MetaCubeX/meta-rules-dat/releases/tag/latest) · [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) · [MaxMind](https://www.maxmind.com/) · [GeoLite 使用条款](https://www.maxmind.com/en/geolite/eula)
