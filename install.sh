#!/usr/bin/env bash
# shell-script: bootstrap Zsh, Oh My Zsh, zsh-autosuggestions, BBR and Docker.
set -Eeuo pipefail

readonly OH_MY_ZSH_GITHUB='https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh'
readonly OH_MY_ZSH_GITEE='https://gitee.com/pocmon/ohmyzsh/raw/master/tools/install.sh'
readonly AUTOSUGGESTIONS_GITHUB='https://github.com/zsh-users/zsh-autosuggestions.git'
readonly AUTOSUGGESTIONS_GITEE='https://gitee.com/chenweizhen/zsh-autosuggestions.git'

use_mirror=false
install_docker=true
configure_bbr=true
change_shell=true

usage() {
  cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/Jannerzhang/shell-script/main/install.sh | bash

Options:
  --mirror       Use Gitee mirrors for Oh My Zsh and zsh-autosuggestions.
  --skip-docker  Do not install or start Docker.
  --skip-bbr     Do not configure fq + BBR.
  --skip-shell   Do not change the invoking user's login shell to Zsh.
  -h, --help     Show this help text.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --mirror) use_mirror=true ;;
    --skip-docker) install_docker=false ;;
    --skip-bbr) configure_bbr=false ;;
    --skip-shell) change_shell=false ;;
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

install_packages() {
  log 'Installing zsh, git, curl and required system tools'
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh git curl ca-certificates procps
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y zsh git curl ca-certificates procps-ng
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y zsh git curl ca-certificates procps-ng
  else
    printf '%s\n' 'Unsupported distribution: expected apt-get, dnf, or yum.' >&2
    exit 1
  fi
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
local shell_script_ip
shell_script_ip="$(timeout 1 curl -4 -fsS --connect-timeout 1 --max-time 1 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
export NODE_NAME="$(hostname)_${shell_script_ip:-unknown}"

PROMPT='%{$fg[magenta]%}%1{?%} %{$fg[cyan]%}%~ '
PROMPT+='%{$fg[green]%}[%n@%{$fg_no_bold[yellow]%}$NODE_NAME%{$fg[green]%}] '
PROMPT+='%{$fg_bold[green]%}%B$%b%{$reset_color%} '

ZSH_THEME_GIT_PROMPT_PREFIX='%{$fg_bold[blue]%}git:(%{$fg[red]%}'
ZSH_THEME_GIT_PROMPT_SUFFIX='%{$reset_color%} '
ZSH_THEME_GIT_PROMPT_DIRTY='%{$fg[blue]%}) %{$fg[yellow]%}%1{✗%}'
ZSH_THEME_GIT_PROMPT_CLEAN='%{$fg[blue]%})'
EOF
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

install_packages
install_oh_my_zsh
install_autosuggestions
write_theme
configure_zshrc
"$change_shell" && set_login_shell
"$configure_bbr" && configure_bbr_settings
"$install_docker" && install_docker_engine

log 'Completed successfully'
printf 'Open a new SSH session to use Zsh by default, or switch now with: exec zsh\n'
