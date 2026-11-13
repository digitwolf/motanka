#!/usr/bin/env bash
# Provision the multiuser base image: the fresh server image plus the users
# alice and bob, each with a home folder and a few dotfiles, including
# Shared_Files (~/.bashrc, ~/.profile, ~/.gitconfig, GTK settings,
# mimeapps.list) that Motanka must leave unchanged.
# Runs as root inside a build VM, fed through stdin by test/vm/image.
set -euo pipefail

add_user() {
  local user=$1 home
  if id -u "$user" >/dev/null 2>&1; then
    echo "user $user already exists"
    return 0
  fi
  useradd --create-home --shell /bin/bash --comment "Test user $user" "$user"
  home=$(getent passwd "$user" | cut -d: -f6)

  mkdir -p "$home/.config/gtk-3.0" "$home/.config/gtk-4.0" "$home/.local/share/notes"
  printf '[user]\n\tname = %s\n\temail = %s@example.test\n' "$user" "$user" >"$home/.gitconfig"
  printf '[Settings]\ngtk-application-prefer-dark-theme=0\n' >"$home/.config/gtk-3.0/settings.ini"
  printf '[Settings]\ngtk-application-prefer-dark-theme=0\n' >"$home/.config/gtk-4.0/settings.ini"
  printf '[Default Applications]\ntext/plain=org.gnome.TextEditor.desktop\n' >"$home/.config/mimeapps.list"
  printf 'set number\n' >"$home/.vimrc"
  printf '\n# added by the multiuser test image\nalias ll="ls -l"\n' >>"$home/.bashrc"
  printf 'notes of %s\n' "$user" >"$home/.local/share/notes/todo.txt"
  chown -R "$user:$user" "$home"
  echo "created user $user with home $home"
}

main() {
  exec </dev/null
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
  add_user alice
  add_user bob
}

main "$@"
