#!/usr/bin/env bash
# shell-script: bootstrap Zsh, Oh My Zsh, zsh-autosuggestions, BBR and Docker.
set -Eeuo pipefail

readonly OH_MY_ZSH_GITHUB='https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh'
readonly OH_MY_ZSH_GITEE='https://gitee.com/pocmon/ohmyzsh/raw/master/tools/install.sh'
readonly AUTOSUGGESTIONS_GITHUB='https://github.com/zsh-users/zsh-autosuggestions.git'
readonly AUTOSUGGESTIONS_GITEE='https://gitee.com/chenweizhen/zsh-autosuggestions.git'
readonly SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcIRzVitCOlG85WZG1YGBSkLT6UvCHN83x0JLSbaE8M gz2'
readonly LOW_MEMORY_THRESHOLD_KIB=512000
readonly SWAP_TARGET_KIB=1048576

use_mirror=false
install_docker=true
configure_bbr=true
change_shell=true
configure_swap=true

usage() {
  cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/Jannerzhang/shell-script/main/install.sh | bash

Options:
  --mirror       Use Gitee mirrors for Oh My Zsh and zsh-autosuggestions.
  --skip-docker  Do not install or start Docker.
  --skip-bbr     Do not configure fq + BBR.
  --skip-shell   Do not change the invoking user's login shell to Zsh.
  --skip-swap    Do not create automatic swap on hosts below 500 MiB RAM.
  -h, --help     Show this help text.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --mirror) use_mirror=true ;;
    --skip-docker) install_docker=false ;;
    --skip-bbr) configure_bbr=false ;;
    --skip-shell) change_shell=false ;;
    --skip-swap) configure_swap=false ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

target_user="${SUDO_USER:-${USER:-root}}"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
if [[ -z "$target_home" || ! -d "$target_home" ]]; then
  printf 'Cannot determine home directory for %s\n' "$target_user" >&2
  exit 1
fi

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

as_target_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    if [[ "$target_user" == 'root' ]]; then
      "$@"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "$target_user" -- "$@"
    else
      sudo -u "$target_user" -H "$@"
    fi
  else
    "$@"
  fi
}

log() {
  printf '\n==> %s\n' "$*"
}

ensure_low_memory_swap() {
  local memory_kib swap_kib required_kib swap_file count_mib
  memory_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  if [[ -z "$memory_kib" || "$memory_kib" -ge "$LOW_MEMORY_THRESHOLD_KIB" ]]; then
    log "Physical memory is ${memory_kib:-unknown} KiB; automatic swap is not required"
    return
  fi

  swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
  if [[ -n "$swap_kib" && "$swap_kib" -ge "$SWAP_TARGET_KIB" ]]; then
    log "Low-memory host detected, but ${swap_kib} KiB of swap is already available"
    return
  fi

  required_kib=$((SWAP_TARGET_KIB - ${swap_kib:-0}))
  swap_file='/swapfile.shell-script'
  if [[ -e "$swap_file" ]]; then
    printf 'Swap file %s already exists but total swap is below 1 GiB; resolve it manually or rerun with --skip-swap.\n' "$swap_file" >&2
    exit 1
  fi

  log "Low-memory host detected (${memory_kib} KiB RAM); creating ${required_kib} KiB persistent swap"
  if ! as_root fallocate -l "$((required_kib * 1024))" "$swap_file"; then
    count_mib=$(((required_kib + 1023) / 1024))
    as_root dd if=/dev/zero of="$swap_file" bs=1M count="$count_mib" status=progress
  fi
  as_root chmod 600 "$swap_file"
  as_root mkswap "$swap_file"
  as_root swapon "$swap_file"
  if ! as_root grep -qxF "$swap_file none swap sw 0 0" /etc/fstab; then
    printf '%s\n' "$swap_file none swap sw 0 0" | as_root tee -a /etc/fstab >/dev/null
  fi
  log "Persistent swap is ready; total swap: $(awk '/^SwapTotal:/ { print $2 " KiB" }' /proc/meminfo)"
}

install_packages() {
  log 'Installing zsh, git, curl, unzip and required system tools'
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh git curl unzip ca-certificates procps
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y zsh git curl unzip ca-certificates procps-ng
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y zsh git curl unzip ca-certificates procps-ng
  else
    printf '%s\n' 'Unsupported distribution: expected apt-get, dnf, or yum.' >&2
    exit 1
  fi
}

configure_node_name() {
  local node_name_file="$target_home/.config/shell-script/node-name"
  local default_name entered_name node_name
  default_name="$(hostname)"
  entered_name="${SHELL_SCRIPT_NODE_NAME:-}"

  if [[ -z "$entered_name" && -t 0 && -t 1 ]]; then
    printf 'Prompt display hostname (leave blank to use %s): ' "$default_name"
    IFS= read -r entered_name || true
  fi
  node_name="${entered_name:-$default_name}"
  if [[ ! "$node_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    printf 'Invalid display hostname: %s. Use 1-63 letters, digits, dots, underscores, or hyphens.\n' "$node_name" >&2
    exit 1
  fi

  log "Saving prompt display hostname: $node_name"
  as_target_user mkdir -p "$(dirname "$node_name_file")"
  as_target_user sh -c 'umask 077; printf "%s\n" "$1" > "$2"' sh "$node_name" "$node_name_file"
}

install_oh_my_zsh() {
  local installer_url="$OH_MY_ZSH_GITHUB"
  if "$use_mirror"; then
    installer_url="$OH_MY_ZSH_GITEE"
  fi

  if [[ -d "$target_home/.oh-my-zsh" ]]; then
    log 'Oh My Zsh is already installed; skipping installer'
    return
  fi

  log 'Installing Oh My Zsh'
  curl -fsSL "$installer_url" | as_target_user env RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh
}

install_autosuggestions() {
  local plugin_url="$AUTOSUGGESTIONS_GITHUB"
  local plugin_dir="$target_home/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
  if "$use_mirror"; then
    plugin_url="$AUTOSUGGESTIONS_GITEE"
  fi

  if [[ -d "$plugin_dir/.git" ]]; then
    log 'Updating zsh-autosuggestions'
    as_target_user git -C "$plugin_dir" pull --ff-only
  elif [[ -e "$plugin_dir" ]]; then
    printf 'Plugin path exists but is not a Git repository: %s\n' "$plugin_dir" >&2
    exit 1
  else
    log 'Installing zsh-autosuggestions'
    as_target_user mkdir -p "$(dirname "$plugin_dir")"
    as_target_user git clone --depth 1 "$plugin_url" "$plugin_dir"
  fi
}

write_theme() {
  local theme_dir="$target_home/.oh-my-zsh/custom/themes"
  local theme_file="$theme_dir/node-info.zsh-theme"
  log 'Writing the node-info Zsh theme'
  as_target_user mkdir -p "$theme_dir"
  as_target_user sh -c "cat > '$theme_file'" <<'EOF'
typeset shell_script_ip
typeset shell_script_name
typeset shell_script_name_file="$HOME/.config/shell-script/node-name"
if [[ -r "$shell_script_name_file" ]]; then
  IFS= read -r shell_script_name < "$shell_script_name_file"
fi
shell_script_name="${shell_script_name:-$(hostname)}"
shell_script_ip="$(timeout 1 curl -4 -fsS --connect-timeout 1 --max-time 1 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
export NODE_NAME="${shell_script_name}_${shell_script_ip:-unknown}"

PROMPT='%{$fg[magenta]%}%1{?%} %{$fg[cyan]%}%~ '
PROMPT+='%{$fg[green]%}[%n@%{$fg_no_bold[yellow]%}$NODE_NAME%{$fg[green]%}] '
PROMPT+='%{$fg_bold[green]%}%B$%b%{$reset_color%} '

ZSH_THEME_GIT_PROMPT_PREFIX='%{$fg_bold[blue]%}git:(%{$fg[red]%}'
ZSH_THEME_GIT_PROMPT_SUFFIX='%{$reset_color%} '
ZSH_THEME_GIT_PROMPT_DIRTY='%{$fg[blue]%}) %{$fg[yellow]%}%1{✗%}'
ZSH_THEME_GIT_PROMPT_CLEAN='%{$fg[blue]%})'
EOF
}

install_ssh_public_key() {
  local ssh_dir="$target_home/.ssh"
  local authorized_keys="$ssh_dir/authorized_keys"
  log "Ensuring the managed SSH public key is authorized for $target_user"
  as_target_user mkdir -p "$ssh_dir"
  as_target_user chmod 700 "$ssh_dir"
  as_target_user touch "$authorized_keys"
  as_target_user chmod 600 "$authorized_keys"
  if ! as_target_user grep -qxF "$SSH_PUBLIC_KEY" "$authorized_keys"; then
    as_target_user sh -c 'printf "%s\n" "$1" >> "$2"' sh "$SSH_PUBLIC_KEY" "$authorized_keys"
  fi
}

configure_zshrc() {
  local zshrc="$target_home/.zshrc"
  log 'Configuring Zsh plugins and theme'
  as_target_user touch "$zshrc"

  if grep -Eq '^plugins=\([^)]*\)$' "$zshrc"; then
    if ! grep -Eq '^plugins=\([^)]*\bzsh-autosuggestions\b' "$zshrc"; then
      as_target_user sed -i -E 's/^plugins=\((.*)\)$/plugins=(\1 zsh-autosuggestions)/' "$zshrc"
    fi
  elif grep -q '^plugins=(' "$zshrc"; then
    if ! grep -Eq '\bzsh-autosuggestions\b' "$zshrc"; then
      as_target_user sed -i '/^plugins=(/a\  zsh-autosuggestions' "$zshrc"
    fi
  else
    as_target_user sh -c "printf '\nplugins=(git zsh-autosuggestions)\n' >> '$zshrc'"
  fi

  if grep -q '^ZSH_THEME=' "$zshrc"; then
    as_target_user sed -i -E 's|^ZSH_THEME=.*$|ZSH_THEME="node-info"|' "$zshrc"
  else
    as_target_user sh -c "printf '\nZSH_THEME=\"node-info\"\n' >> '$zshrc'"
  fi
}

configure_bbr_settings() {
  local sysctl_file='/etc/sysctl.d/99-shell-script-bbr.conf'
  log 'Configuring fq and BBR'
  as_root sh -c "cat > '$sysctl_file'" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  as_root sysctl --system
  if sysctl -n net.ipv4.tcp_congestion_control | grep -qx 'bbr'; then
    log 'BBR is active'
  else
    printf '%s\n' 'BBR was configured but is not active. Your kernel may not support it; inspect sysctl output above.' >&2
  fi
}

install_docker_engine() {
  log 'Installing Docker Engine using Docker official convenience script'
  local temp_script
  temp_script="$(mktemp)"
  trap 'rm -f "$temp_script"' RETURN
  curl -fsSL https://get.docker.com -o "$temp_script"
  as_root sh "$temp_script"
  as_root systemctl enable --now docker
  as_root usermod -aG docker "$target_user"
  printf '%s\n' "Docker is installed. Log out and back in (or run 'newgrp docker') before using Docker without sudo."
}

set_login_shell() {
  local zsh_path configured_shell
  zsh_path="$(command -v zsh)"
  configured_shell="$(getent passwd "$target_user" | cut -d: -f7)"
  if [[ "$configured_shell" == "$zsh_path" ]]; then
    log 'Zsh is already the login shell'
    return
  fi
  log "Changing $target_user login shell to $zsh_path"
  as_root chsh -s "$zsh_path" "$target_user"
  configured_shell="$(getent passwd "$target_user" | cut -d: -f7)"
  if [[ "$configured_shell" != "$zsh_path" ]]; then
    printf 'Failed to set the login shell for %s: expected %s, got %s\n' "$target_user" "$zsh_path" "$configured_shell" >&2
    exit 1
  fi
  log "Zsh is now the default login shell for $target_user"
}

"$configure_swap" && ensure_low_memory_swap
install_packages
install_oh_my_zsh
install_autosuggestions
configure_node_name
write_theme
configure_zshrc
install_ssh_public_key
"$change_shell" && set_login_shell
"$configure_bbr" && configure_bbr_settings
"$install_docker" && install_docker_engine

log 'Completed successfully'
printf 'Open a new SSH session to use Zsh by default, or switch now with: exec zsh\n'
