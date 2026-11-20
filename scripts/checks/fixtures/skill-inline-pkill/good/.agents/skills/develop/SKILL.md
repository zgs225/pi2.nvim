# Good skill — cleanup that does not eat its own shell

Prose names the anti-pattern on purpose: a one-liner like
`pkill -f "wezterm-gui.*$SOCK"` matches its own shell (G16), so the cleanup is a
file instead.

```bash
bash .agents/skills/develop/scripts/gui_cleanup.sh wezterm-gui.*pi_gui_test
```

```bash
pgrep -l wezterm-gui   # process-name match, not a full-cmdline match
```

```python
# a fence in another language is not a shell one-liner
subprocess.run(["pkill", "-f", "wezterm-gui.*pi_gui_test"])
```
