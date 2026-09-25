#!/usr/bin/env python3
"""Static regression checks that never execute CachyOS package operations."""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cachyos-gaming-setup.sh"
source = SCRIPT.read_text(encoding="utf-8")


def run(*command: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode != expect:
        print(f"Command {' '.join(command)} returned {result.returncode}, expected {expect}.", file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(1)
    return result


run("bash", "-n", str(SCRIPT))
help_output = run(str(SCRIPT), "--help").stdout
if "--run-maintenance" not in help_output or "--profile balanced" not in help_output:
    raise SystemExit("Help output is missing documented safety options.")
run(str(SCRIPT), "--profile", "invalid", expect=2)
run(str(SCRIPT), "--enable-mitigations-off", "--yes", expect=2)

# Every generated Bash helper must parse before it is written to a user's home.
helpers = list(
    re.finditer(
        r"cat <<'EOF' > \"\$HOME(?P<path>[^\"]+)\"\n(?P<body>.*?)\nEOF",
        source,
        re.DOTALL,
    )
)
bash_helpers = [match for match in helpers if match.group("body").startswith("#!/usr/bin/env bash")]
if len(bash_helpers) != 9:
    raise SystemExit(f"Expected 9 generated Bash helpers, found {len(bash_helpers)}.")

helper_by_path = {match.group("path"): match.group("body") for match in bash_helpers}
update_helper = helper_by_path.get("/.local/bin/update-arch", "")
if "flatpak repair" in update_helper or "ufw " in update_helper:
    raise SystemExit("The recurring update helper must not repair Flatpak or modify firewall policy.")
if "sudo pacman -Syyu" in update_helper:
    raise SystemExit("The recurring update helper must not force a redundant database refresh.")

maintenance_start = source.index('# ---------- 6. SICHERE WARTUNG')
maintenance_end = source.index('# ---------- 7. VERIFY', maintenance_start)
maintenance_phase = source[maintenance_start:maintenance_end]
first_cleanup = maintenance_phase.index('rm -rf -- "$HOME/.thumbnails/')
first_opt_in = maintenance_phase.index('if [[ "$RUN_MAINTENANCE" == "true" ]]')
if first_cleanup < first_opt_in:
    raise SystemExit("Maintenance cleanup must remain behind --run-maintenance.")

with tempfile.TemporaryDirectory() as temporary_directory:
    temporary_root = Path(temporary_directory)
    for helper in bash_helpers:
        helper_file = temporary_root / helper.group("path").lstrip("/").replace("/", "__")
        helper_file.write_text(helper.group("body") + "\n", encoding="utf-8")
        run("bash", "-n", str(helper_file))

print("Static checks passed: main script, option parser, and generated Bash helpers.")
