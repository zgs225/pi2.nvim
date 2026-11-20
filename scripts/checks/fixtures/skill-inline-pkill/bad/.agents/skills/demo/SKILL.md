# Bad skill — inline G16 one-liners

Prose only, never a finding: an inline `pgrep -f "wezterm-gui.*$SOCK"` matches its
own shell, so cleanup belongs in a script.

```bash
pkill -f "wezterm-gui.*pi_gui_test"
```

```sh
pgrep -af "wezterm-gui.*$SOCK"
```

```
pkill -lf wezterm-gui.*
```

```text
pkill -f "a non-shell fence is not a shell one-liner"
```

```python
subprocess.run(["pkill", "-f", "wezterm-gui.*pi_gui_test"])
```

```bash
# pkill -f is explained in gotchas.md G16 — a comment does not execute
pgrep -l wezterm-gui
bash .agents/skills/demo/scripts/cleanup.sh
```
