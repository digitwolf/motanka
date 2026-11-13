# Manual test results

This folder holds the records of the manual hardware tests that the VM tests cannot do.

- `<version>-nvidia.md`: the NVIDIA hardware test of one Motanka version, made from the template in `../nvidia.md` and filled in for both releases. `<version>` is the first line of `packaging/VERSION`, for example `0.1.0-nvidia.md`.
- `<version>-nvidia-noble.png` and `<version>-nvidia-resolute.png`: the screenshots that record names.

The publish job of `.github/workflows/ci.yml` runs `ci/check-nvidia-record` and does not publish a version whose record is missing or does not pass (requirement 13.9). A record is never edited after its version is published; a new version gets a new record.
