# Recording notes

`demo.gif` (light) and `demo-dark.gif` (dark) are rendered from `demo.cast`,
a real terminal session against the released Opaque package in a throwaway
`HOME`. Every value that looks like a secret in the recording is a dummy
value, and Harborlight is a fictional lender. It was recorded against
Opaque 0.4.0 and has not been re-recorded for 0.6.0.

The recording runs in CI mode (`insecure_auto_approve`), so no native
approval prompt appears; the on-screen banner states this and the mode is
attributed in the audit chain it shows. It covers Acts 1, 2, and 4 — the
leak, the allow/deny simulation, and the denial, verified chain, and
tamper detection. Act 3's native approval is an OS dialog and does not
appear in a terminal capture.

Re-record (needs `brew install asciinema agg`; the driver sources
`acts/_lib.sh` and follows the same throwaway-HOME pattern as the acts):

```sh
asciinema rec -q --cols 126 --rows 30 -c "bash <driver script>" assets/demo.cast
agg --quiet --theme github-light --idle-time-limit 3.5 --speed 0.8 assets/demo.cast assets/demo.gif
agg --quiet --theme github-dark  --idle-time-limit 3.5 --speed 0.8 assets/demo.cast assets/demo-dark.gif
```

The driver is a trimmed composition of the act scripts: title, the Act 1
leak line, `ensure_initialized` plus the two `opaque policy simulate`
calls, then the Act 4 denial, `audit tail --kind policy.denied`,
`audit verify`, `stop_daemon`, the sqlite3 tamper, and the failing verify.
Verify the cast before shipping it: the text must contain the
`Audit chain BROKEN` line.
