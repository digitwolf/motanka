# Keys

- `motanka-archive.asc`: public half of the Motanka archive signing key. The
  current file is a TEST key made by `chumak/gen-test-key`; real releases
  replace it.
- `ubuntu-toolchain-r-test.asc`: signing key of the Ubuntu toolchain PPA
  (ppa:ubuntu-toolchain-r/test), fingerprint
  C8EC952E2A0E1FBDC5090F6A2C277A0A352154E5 (from the Launchpad API). Used only
  inside the build VM to install GCC 16 for 24.04 (noble) builds. The file must
  start with the armour header: apt does not accept `.asc` keys with leading
  comment lines.
