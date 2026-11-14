#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for test/vm/fpowned.py: removing what Motanka installed from a
# Fingerprint before the isolation test compares it (5.10).

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  FPOWNED="$BATS_TEST_DIRNAME/../vm/fpowned.py"
  IN="$BATS_TEST_TMPDIR/in"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$IN"
  printf 'bash\t5.2\tinstalled\nmotanka-core\t0.1\tinstalled\nlibfoo1:amd64\t1.0\tinstalled\n' >"$IN/packages.tsv"
  printf 'bash\nmotanka\n' >"$IN/manual.txt"
  printf '# root /etc\n/etc\td\t0755\t0:0\t-\n/etc/hostname\tf\t0644\t0:0\t%s\n/etc/dconf/db/motanka\tf\t0644\t0:0\t%s\n' "$SHA_A" "$SHA_A" >"$IN/etc.sha256"
  printf 'system ssh.service enabled enabled\nglobal motanka-session.target static -\nglobal pipewire.service enabled enabled\n# root /usr/lib/systemd/user\n/usr/lib/systemd/user/motanka-session.target\tf\t0644\t0:0\t%s\n' "$SHA_A" >"$IN/units.txt"
  printf '# root /home/tester\n/home/tester\td\t0750\t1000:1000\t-\n/home/tester/.bashrc\tf\t0644\t1000:1000\t%s\n/home/tester/.config/hypr/hyprland.lua\tf\t0644\t1000:1000\t%s\n/home/tester/.config/omarchy\td\t0755\t1000:1000\t-\n/home/tester/.config/omarchy/a\tf\t0644\t1000:1000\t%s\n/home/tester/.config/omarchyx\tf\t0644\t1000:1000\t%s\n' \
    "$SHA_A" "$SHA_A" "$SHA_A" "$SHA_A" >"$IN/home-tester.sha256"
  printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'default'" >"$IN/dconf-tester.ini"
  printf 'motanka\nmotanka-core\nlibfoo1\n' >"$BATS_TEST_TMPDIR/pkgs"
  printf '/etc/dconf/db/motanka\n/usr/lib/systemd/user/motanka-session.target\n/home/tester/.config/hypr/hyprland.lua\n/home/tester/.config/omarchy/\n' >"$BATS_TEST_TMPDIR/paths"
}

@test "owned packages, files, units and home paths are removed; the rest is kept" {
  run python3 -I "$FPOWNED" "$BATS_TEST_TMPDIR/pkgs" "$BATS_TEST_TMPDIR/paths" "$IN" "$OUT"
  assert_success
  run cat "$OUT/packages.tsv"
  assert_output $'bash\t5.2\tinstalled'
  run cat "$OUT/manual.txt"
  assert_output 'bash'
  run grep -c 'motanka' "$OUT/etc.sha256"
  assert_output 0
  run cat "$OUT/units.txt"
  assert_output $'system ssh.service enabled enabled\nglobal pipewire.service enabled enabled\n# root /usr/lib/systemd/user'
  run cut -f1 "$OUT/home-tester.sha256"
  assert_output $'# root /home/tester\n/home/tester\n/home/tester/.bashrc\n/home/tester/.config/omarchyx'
  cmp "$IN/dconf-tester.ini" "$OUT/dconf-tester.ini"
}

@test "a missing input folder or a wrong argument count exits 2" {
  run python3 -I "$FPOWNED" "$BATS_TEST_TMPDIR/pkgs" "$BATS_TEST_TMPDIR/paths" "$BATS_TEST_TMPDIR/none" "$OUT"
  assert_failure 2
  run python3 -I "$FPOWNED" a b
  assert_failure 2
  assert_output --partial 'Usage: fpowned.py'
}
