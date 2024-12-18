#!/usr/bin/env bash

# Exit on error, undefined variables, and pipe failures
#set -euo pipefail

# Function to check if vncserver is already installed
check_installed() {
  if command -v vncserver >/dev/null 2>&1; then
    echo "vncserver is already installed."
    return 0
  else
    return 1
  fi
}

# Function to download a file using curl, wget, or busybox as a fallback
download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output"
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget "$url" -O "$output"
  else
    echo "ERROR: No download tool available (curl, wget, or busybox required)"
    exit 1
  fi
}

# Function to install kasmvncserver for debian-based distros
install_deb() {
  local url="$1"
  local kasmdeb="/tmp/kasmvncserver.deb"

  download_file "$url" "$kasmdeb"

  CACHE_DIR="/var/lib/apt/lists/partial"
  if [[ ! -d "$CACHE_DIR" ]] || ! find "$CACHE_DIR" -mmin -60 -print -quit >/dev/null 2>&1; then
    echo "Stale package cache, updating..."
    sudo apt-get -o DPkg::Lock::Timeout=300 -qq update
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install --yes -qq --no-install-recommends "$kasmdeb"
  rm "$kasmdeb"
}

# Function to install kasmvncserver for rpm-based distros
install_rpm() {
  local url="$1"
  local kasmrpm="/tmp/kasmvncserver.rpm"

  download_file "$url" "$kasmrpm"

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf localinstall -y "$kasmrpm"
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y "$kasmrpm"
  elif command -v yum >/dev/null 2>&1; then
    sudo yum localinstall -y "$kasmrpm"
  elif command -v rpm >/dev/null 2>&1; then
    sudo rpm -i "$kasmrpm"
  else
    echo "ERROR: No supported package manager available (dnf, zypper, yum, or rpm required)"
    exit 1
  fi

  rm "$kasmrpm"
}

# Function to install kasmvncserver for Alpine Linux
install_alpine() {
  local url="$1"
  local kasmtgz="/tmp/kasmvncserver.tgz"

  download_file "$url" "$kasmtgz"

  tar -xzf "$kasmtgz" -C /usr/local/bin/
  rm "$kasmtgz"
}

# Detect system information
if [[ ! -f /etc/os-release ]]; then
  echo "ERROR: Cannot detect OS: /etc/os-release not found"
  exit 1
fi

source /etc/os-release

distro="$ID"
distro_version="$VERSION_ID"
codename="$VERSION_CODENAME"
arch="$(uname -m)"

if [[ "$ID" == "ol" ]]; then
  distro="oracle"
  distro_version="${distro_version%%.*}"
elif [[ "$ID" == "fedora" ]]; then
  distro_version="$(grep -oP '\(\K[\w ]+' /etc/fedora-release | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
fi

case "$arch" in
  x86_64)
    if [[ "$distro" =~ ^(ubuntu|debian|kali)$ ]]; then
      arch="amd64"
    fi
    ;;
  aarch64)
    if [[ "$distro" =~ ^(ubuntu|debian|kali)$ ]]; then
      arch="arm64"
    fi
    ;;
  arm64)
    ;; # No-op
  *)
    echo "ERROR: Unsupported architecture: $arch"
    exit 1
    ;;
esac

# Check if vncserver is installed, and install if not
if ! check_installed; then
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    echo "ERROR: sudo NOPASSWD access required!"
    exit 1
  fi

  base_url="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}"

  echo "Installing KASM version: ${KASM_VERSION}"
  case $distro in
    ubuntu | debian | kali)
      bin_name="kasmvncserver_${codename}_${KASM_VERSION}_${arch}.deb"
      install_deb "$base_url/$bin_name"
      ;;
    oracle | fedora | opensuse)
      bin_name="kasmvncserver_${distro}_${distro_version}_${KASM_VERSION}_${arch}.rpm"
      install_rpm "$base_url/$bin_name"
      ;;
    alpine)
      bin_name="kasmvnc.alpine_${distro_version//./}_${arch}.tgz"
      install_alpine "$base_url/$bin_name"
      ;;
    *)
      echo "Unsupported distribution: $distro"
      exit 1
      ;;
  esac
else
  echo "vncserver already installed. Skipping installation."
fi

kasm_config_file="/etc/kasmvnc/kasmvnc.yaml"
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo"
else
  kasm_config_file="$HOME/.vnc/kasmvnc.yaml"
  SUDO=""

  echo "WARNING: Sudo access not available, using user config dir!"

  if [[ -f "$kasm_config_file" ]]; then
    echo "WARNING: Custom user KasmVNC config exists, not overwriting!"
    echo "WARNING: Ensure that you manually configure the appropriate settings."
    kasm_config_file="/dev/stderr"
  else
    mkdir -p "$HOME/.vnc"
  fi
fi

$SUDO tee "$kasm_config_file" > /dev/null << EOF
network:
  protocol: http
  websocket_port: ${PORT}
  ssl:
    require_ssl: false
    pem_certificate:
    pem_key:
  udp:
    public_ip: 127.0.0.1
EOF

vncpasswd << EOF
password
password
EOF

printf "\u1F680 Starting KasmVNC server...\n"
vncserver -select-de "${DESKTOP_ENVIRONMENT}" -disableBasicAuth > /tmp/kasmvncserver.log 2>&1 &

pid=$!
sleep 5
grep -v '^[[:space:]]*$' /tmp/kasmvncserver.log | tail -n 10
if ! ps -p $pid >/dev/null 2>&1; then
  echo "ERROR: Failed to start KasmVNC server. Check full logs at /tmp/kasmvncserver.log"
  exit 1
fi
printf "\u1F680 KasmVNC server started successfully!\n"
