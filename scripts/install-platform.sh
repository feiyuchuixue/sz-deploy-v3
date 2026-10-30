#!/bin/bash
# 首次安装的系统差异；PKG_MGR 始终由安装输入选择。

install_platform_require_manager() {
  case "${PKG_MGR:-dnf}" in
    dnf|apt|yum) ;;
    *) printf '不支持的 PKG_MGR，只能选择 dnf、apt 或 yum\n' >&2; return 1 ;;
  esac
  command -v "$PKG_MGR" >/dev/null 2>&1 || {
    printf '找不到所选包管理器 %s，请检查安装输入和服务器环境\n' "$PKG_MGR" >&2
    return 1
  }
}

install_platform_resolve_repository() {
  local ID='' VERSION_CODENAME='' UBUNTU_CODENAME=''
  [[ -r /etc/os-release ]] || { printf '缺少 /etc/os-release，无法确定 Docker 软件源\n' >&2; return 1; }
  . /etc/os-release
  case "$PKG_MGR" in
    apt)
      case "$ID" in
        ubuntu) INSTALL_DOCKER_DISTRO=ubuntu; INSTALL_DOCKER_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}" ;;
        debian) INSTALL_DOCKER_DISTRO=debian; INSTALL_DOCKER_CODENAME="$VERSION_CODENAME" ;;
        *) printf 'apt 安装当前仅支持 Ubuntu 和 Debian，请先适配该发行版\n' >&2; return 1 ;;
      esac
      [[ "$INSTALL_DOCKER_CODENAME" =~ ^[a-z][a-z0-9._-]*$ ]] || {
        printf '缺少或非法的发行版 codename，停止配置 Docker APT 源\n' >&2; return 1;
      }
      INSTALL_DOCKER_ARCH="$(dpkg --print-architecture)"
      [[ "$INSTALL_DOCKER_ARCH" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
      ;;
    dnf|yum)
      case "$ID" in
        centos|rocky|almalinux) INSTALL_DOCKER_DISTRO=centos ;;
        rhel) INSTALL_DOCKER_DISTRO=rhel ;;
        *) printf 'dnf/yum 安装当前仅支持 CentOS、Rocky、AlmaLinux 和 RHEL 系列\n' >&2; return 1 ;;
      esac
      ;;
  esac
}

install_platform_remove_conflicts() {
  local package state
  local -a candidates installed=()
  if [[ "$PKG_MGR" == apt ]]; then
    candidates=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
    for package in "${candidates[@]}"; do
      if state="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" && [[ "$state" == 'install ok installed' ]]; then
        installed+=("$package")
      fi
    done
  else
    candidates=(docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker containerd runc)
    for package in "${candidates[@]}"; do
      if rpm -q "$package" >/dev/null 2>&1; then installed+=("$package"); fi
    done
  fi
  if (( ${#installed[@]} )); then
    sudo "$PKG_MGR" remove -y "${installed[@]}"
  fi
}

install_platform_prepare_docker_repository() {
  install_platform_resolve_repository
  if [[ "$PKG_MGR" == apt ]]; then
    local source_content
    source_content="$(printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
      "$INSTALL_DOCKER_DISTRO" "$INSTALL_DOCKER_CODENAME" "$INSTALL_DOCKER_ARCH")"
    # 不能与旧 .list 或其他维护者的不同源配置并存、混用 Signed-By。
    if [[ -e /etc/apt/sources.list.d/docker.list || -L /etc/apt/sources.list.d/docker.list \
       || -L /etc/apt/sources.list.d/docker.sources ]]; then
      printf '已有 Docker APT 源配置，请先核对并整理 docker.list/docker.sources\n' >&2
      return 1
    fi
    if [[ -e /etc/apt/sources.list.d/docker.sources \
       && "$(< /etc/apt/sources.list.d/docker.sources)" != "$source_content" ]]; then
      printf '已有不同的 Docker APT 源，停止覆盖，请先人工核对\n' >&2
      return 1
    fi
    install_platform_remove_conflicts
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/$INSTALL_DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    printf '%s\n' "$source_content" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
    sudo apt update
  else
    install_platform_remove_conflicts
    if [[ "$PKG_MGR" == yum ]]; then
      sudo yum install -y yum-utils
      sudo yum-config-manager --add-repo "https://download.docker.com/linux/$INSTALL_DOCKER_DISTRO/docker-ce.repo"
    else
      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo "https://download.docker.com/linux/$INSTALL_DOCKER_DISTRO/docker-ce.repo"
    fi
  fi
}
