# Contributing

Thanks for considering a contribution! This project lives from suggestions.

## How to suggest something

- **Small idea / question:** Open a GitHub **Issue** with `feature request` template
- **Bug:** Use `bug report` template, attach `~/cachyos-logs/errors_*.log` (sanitize with `inxi -Fz --filter` if needed)
- **Small fix:** Fork → branch → Pull Request

No Discord DMs needed – everything via GitHub stays transparent.

## Requirements for Pull Requests

1. `bash -n cachyos-gaming-setup.sh` must pass (CI checks syntax)
2. Keep automatic hardware detection – no hard-coded drivers without `lspci`/`lscpu` check
3. No Vencord / Vesktop / MessageLogger and no Spotify ad-blocking in public version (ToS-safe). Theming only is fine.
4. Do not suppress errors from required package, bootloader or configuration changes. Optional capability checks such as `command -v` may be quiet.
5. Keep logs: every phase must write to `~/cachyos-logs/`, no hidden `rm -rf`
6. Update `README.md` if you change phases or helper commands
7. Keep documentation and user-facing output consistent, update the README for behavior changes, and test on a fresh CachyOS VM if possible

## Style

- Bash `set -Euo pipefail`, quoted variables `"$VAR"`, functions `log`/`info`/`warn`/`fail`
- No `pacman -Rdd`, no blind `--overwrite '*'`
- Comments explain *why*, not just *what*

## What happens with your suggestion

- I will maintain this actively. I try to respond within 2-3 days.
- Good ideas get marked `help wanted` / `good first issue` so others can pick them up
- Breaking changes get a `vX.Y.0` tag, small fixes `vX.Y.Z`

## Code of Conduct

Be respectful. No harassment, no spam. For major changes, open an Issue first to discuss before coding.
