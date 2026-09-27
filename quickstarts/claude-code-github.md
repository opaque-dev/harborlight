# Use Opaque with Claude Code

Wire Claude Code to the broker, watch it call gated tools with zero
credentials, then publish a real GitHub Actions secret it never sees.

Finish [the four acts](../README.md) first. This page assumes `opaque`,
`opaqued`, and `opaque-mcp` are installed and that you have Claude Code.
Steps 1–3 need no external accounts. Step 4 needs a disposable GitHub token
and a test repository.

The acts ran in a throwaway `HOME`. Claude Code runs in your project under
your real `HOME`, so this page uses your real `~/.opaque`. If you have not
initialized it, run `opaque init --preset github-secrets`. If a configuration
already exists, review it instead of overwriting it — `opaque init` is for
setup, not a repair or reset command for existing custody. Whatever `HOME`
the daemon runs under, Claude Code must share it: the MCP adapter finds the
daemon's socket the same way the CLI does.

This is a local learning exercise: agent and daemon share your user account.
It does not isolate credentials from other processes with that account's
access. Use a throwaway value and test repository, not production credentials
or data.

## 1. Wire the broker into Claude Code

Write a project-local `.mcp.json` in the repository where you run Claude
Code, using the absolute path from `command -v opaque-mcp`:

```json
{
  "mcpServers": {
    "opaque": {
      "command": "/opt/homebrew/bin/opaque-mcp",
      "args": []
    }
  }
}
```

Copy [mcp/mcp.json.example](../mcp/mcp.json.example) and adjust the path.
The server takes no arguments; `--stdio` is accepted and changes nothing. The
equivalent CLI form is `claude mcp add opaque -s project -- "$(command -v opaque-mcp)"`
— this matches `claude mcp add --help`, and the file above is what it produces.

Since 0.6.0, `opaque connect claude` can write the entry for you. It
registers the server in your user-scope `~/.claude.json` with the absolute
path of `opaque-mcp` and an empty `args` list, merges into whatever servers
that file already holds, and on a second run reports that the entry exists
instead of rewriting it. Captured against 0.6.0:

```text
$ opaque connect claude
✔  Registered opaque MCP server with Claude Code
$ opaque connect claude
ℹ  opaque MCP server is already configured in Claude Code
```

In 0.4.0 this command wrote a configuration the adapter rejected
([#110](https://github.com/opaque-dev/opaque/issues/110), closed), which is
why this page used to insist on the hand-written file.

Start the daemon if it is not running, then restart Claude Code in that
project and check the connection with `/mcp`. The adapter identifies itself
as `opaque-mcp 0.6.0+7067aa0` and lists 22 tools against this daemon,
including `opaque_github_set_actions_secret`. The list is what the connected
daemon serves: 0.4.0 advertised 24, two of them signed-contract tools this
daemon does not run
([#120](https://github.com/opaque-dev/opaque/issues/120), closed).

## 2. First tool calls, zero credentials

Ask Claude Code:

> Using the opaque tools, list the sandbox profiles and show the secrets
> status for the analyst profile.

Two tool calls come back, and neither can return a value. Real output,
captured against the running daemon:

```json
opaque_sandbox_list_profiles {}
[
  {
    "name": "analyst",
    "description": "Harborlight analyst sandbox (synthetic data only)"
  }
]

opaque_secrets_status {"profile": "analyst"}
[
  {
    "env_name": "HARBORLIGHT_SOURCE_TOKEN",
    "scheme": "env",
    "reference": "env:OPAQUE_DEMO_VALUE_SRC"
  }
]
```

`opaque_secrets_status` parses configuration only: names, schemes, and
references. The agent learns what a profile can inject and nothing about the
values behind it. A malformed call is refused with the failing field named,
so the agent corrects itself instead of guessing:

```text
opaque_secrets_status {}
{"code": -32602, "message": "tool arguments do not match the input schema: missing required field \"/profile\""}
```

## 3. Preview a publish, still zero credentials

Ask Claude Code:

> Build an Opaque env manifest from .env.example for your-org/your-test-repo,
> then preview publishing it with a dry run.

The manifest helpers are offline CLI commands, so Claude Code runs them in
its shell — the broker treats that CLI exactly as it treats the MCP tools:

```sh
opaque github build-manifest --repo your-org/your-test-repo \
  --value-ref-template "keychain:opaque/{name}"
opaque github publish-manifest --repo your-org/your-test-repo --dry-run
```

```text
✔  Manifest created. Update refs manually if needed, then run publish-manifest.

Publish Manifest Secrets
  repo:            your-org/your-test-repo
  manifest_file:   .opaque/env-manifest.json
  mode:            dry-run
  ✔  DATABASE_URL
      ref: keychain:opaque/DATABASE_URL
✔  Dry run complete: 2 secret(s) planned
```

`build-manifest` captures key names and value refs, never values. The dry
run previews the plan without calling the daemon. Nothing so far required a
GitHub account.

## 4. Publish a real secret

Now the reader-supplied parts: a disposable GitHub token authorized to
manage Actions secrets on a test repository, and a throwaway secret value.
Store both by reference — the default token location is
`keychain:opaque/github-pat`:

```sh
opaque secrets add github-pat        # the disposable token, from stdin
opaque secrets add tutorial-value    # a throwaway value, from stdin
```

Ask Claude Code:

> Use the opaque tools to set the Actions secret DEMO_KEY on
> your-org/your-test-repo from keychain:opaque/tutorial-value.

The tool call is:

```json
opaque_github_set_actions_secret {
  "repo": "your-org/your-test-repo",
  "secret_name": "DEMO_KEY",
  "value_ref": "keychain:opaque/tutorial-value"
}
```

The `github-secrets` preset holds this operation at `always` approval, so
your Touch ID or polkit prompt appears before anything is resolved. Approve
it, then read the receipt:

```sh
opaque audit tail --operation github.set_actions_secret --limit 5
opaque audit verify
```

The agent asked. You approved. The broker resolved both references, called
GitHub, and recorded the result. The value crossed from your keychain to
GitHub without entering the agent's context.

## What the agent cannot do

- Read the value back. The tool returns status; the operation never returns
  the secret value or ciphertext.
- See sandbox output. Over MCP, `opaque_sandbox_exec` withholds content and
  returns exit code and byte lengths only.
- Escape the policy. A tool call outside the rules comes back as a denial,
  and the denial lands in the audit chain — Act 4 of
  [the quickstart](../README.md) shows exactly what that looks like.

The [boundary honesty section](../README.md#what-this-shows-and-what-it-does-not)
applies here unchanged: Opaque governs operations routed through its broker,
and an agent's other credentials, readable files, and direct access remain
outside that boundary.

---

Steps 1–3 were verified against a live `opaqued` and `opaque-mcp`
0.6.0+7067aa0 on 2026-09-26; the JSON outputs above are captured, not
composed. Step 4 follows the
[core tutorial](https://github.com/opaque-dev/opaque/blob/main/docs/tutorial.md)
and needs your own disposable token and test repository.
