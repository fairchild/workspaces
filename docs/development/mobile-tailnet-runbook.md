# Mobile over tailnet — operator runbook

How to reach this Mac's web-next from a phone on the tailnet, and how to shut
it off again. Companion to `mobile-pairing-isolation.md` (which covers
disabling the feature) and the ADR `../decisions/mobile-tailnet-design.md`
(which covers why it is shaped this way).

Two paths reach the same server. **Use the app** if you are running the desktop
app — Window → Pair Mobile Device does everything below for you and renders a
QR. Use the **headless path** when you want the server without the app, which
is the case this document exists for: phone Safari against a checkout, demos,
or a machine with no GUI session.

Before either, read the one thing that decides how carefully you handle the
token.

## The token is filesystem read access

The sign-in token authorizes an agent lane that can read **any file this user
can read** — not only the workspace. That was probed, not assumed; the verdict
and its evidence are in the ADR under "Read-tool jail probe". Treat a leaked QR
or a token in a chat log as a disclosure of your home directory, and rotate
immediately (below).

Nothing here binds beyond loopback. `tailscale serve` is the only thing that
makes the server reachable, you run it yourself, and it is one-time node state
the app deliberately never mutates.

## Headless path

Four steps on the Mac, one on the phone.

**0. Find the CLI.** On macOS the Tailscale app does not put `tailscale` on
your `PATH`, so every command below needs the real binary. The desktop app
tries these three, in order, and so should you:

```sh
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale   # or
TS=/opt/homebrew/bin/tailscale                            # or
TS=/usr/local/bin/tailscale
```

Verified on this machine: only the first exists, and a bare `tailscale` is
`command not found`. The rest of this document writes `$TS`.

**1. Put `tailscale serve` in front of the loopback bind.** One time per node;
it survives reboots.

```sh
$TS serve --bg 3140
```

Serve terminates TLS with the tailnet's own certificate and forwards to
`127.0.0.1:3140` (`--bg` runs it in the background; without it the command
holds the foreground). Port 3140 is the app's embedded default
(`WebNextServerSettings.port`); the standalone server defaults to 3100, so pass
a matching `PORT` below or a matching port here.

**2. Learn this Mac's MagicDNS name.** The origin is `https://` plus that name,
with the trailing dot stripped.

```sh
$TS status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
```

This is the same field the app reads (`TailnetIdentity`, `.Self.DNSName`).

Call the result `$FQDN`. It changes only when the machine is renamed.

**3. Start the server with that origin allowlisted.** The Host gate is
exact-match, so the origin string must match byte for byte — scheme included.

```sh
cd web-next
PORT=3140 \
WEB_NEXT_DATA_DIR="$HOME/.workspaces-web-next" \
WEB_NEXT_EXTRA_LOCAL_ORIGINS="https://$FQDN" \
pnpm start:local
```

Do not run this at the same time as the app's embedded server — the app owns
its port, and two servers fighting for 3140 is the failure `mobile-server.sh`
was deleted for causing.

**4. Take the URL the server prints.** With the allowlist set, `start:local`
prints the tailnet URL directly:

```
Local sign-in: http://localhost:3140/sign-in?token=<token>
Proxy sign-in: https://your-mac.tailnet.ts.net/sign-in?token=<token>
Local token: /Users/you/.workspaces-web-next/local-sign-in-token
```

**`Proxy sign-in` is the one for the phone.** Earlier revisions of this flow
required hand-editing the `localhost` line onto the tailnet FQDN; that is no
longer true, and hand-editing risks a near-miss that the exact-match gate will
reject. If only the `Local sign-in` line appears, `WEB_NEXT_EXTRA_LOCAL_ORIGINS`
did not reach the process.

**5. On the phone:** open `Proxy sign-in` in Safari, on the tailnet. It sets a
session cookie, marked `Secure` because the origin is https, and lands on the
sessions list. Transfer the URL by QR or AirDrop rather than by a channel that
keeps history.

## Verifying it works

From another tailnet peer, before involving the phone:

```sh
curl -sS "https://$FQDN/api/healthz"                          # {"ok":true,"localMode":true}
curl -sS -o /dev/null -w '%{http_code}\n' "https://$FQDN/"    # redirect to /sign-in
```

`/api/healthz` is public but still behind the Host gate — the gate runs before
the public-path check — so a 200 here proves the allowlist matched, not just
that the server is up.

Then confirm the gate still refuses a forged Host, which is the invariant the
whole design rests on:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: evil.example' \
  "https://$FQDN/api/sessions"              # 403
```

That must stay 403 with the allowlist set, and every non-loopback Host must
403 when `WEB_NEXT_EXTRA_LOCAL_ORIGINS` is unset. Dotted paths are gated too
(`/api/sessions/foo.bar`), which is not obvious from the matcher and is why
`web-next/src/middleware.matcher.test.ts` compiles it with Next's own
`getMiddlewareMatchers` and asserts over paths.

Streaming through `serve` was measured unbuffered: 1-second ticks arrived about
90 ms after send (#1465). If a live turn appears to stall and then dump, suspect
something else in the path before suspecting serve.

## Rotating the token

Rotation is deletion plus a restart. There is no revocation list, and disabling
the pairing feature does **not** invalidate a token a phone already holds.

```sh
# stop the server (or quit the app), then:
rm "$WEB_NEXT_DATA_DIR/local-sign-in-token"
```

The next start mints a fresh 32-byte token at `0600` and every previously
paired phone is signed out. Rotate whenever a QR was photographed by someone
else, a token reached a shared channel, or a paired phone left your control.

## Turning reachability off

```sh
$TS serve status    # see what is currently fronted
$TS serve reset     # remove it
```

`reset` is the current spelling (verified against Tailscale 1.102); the
`--https=443 off` form from older docs is not what this version documents. The
server returns to loopback-only immediately, with no app change and no restart.
To also remove the pairing surface from the app, see
`mobile-pairing-isolation.md`.

## When it does not work

- **403 from the phone, healthz fine from curl.** The Host the phone sends does
  not byte-match the allowlist. Compare the `Proxy sign-in` origin against
  `WEB_NEXT_EXTRA_LOCAL_ORIGINS` character by character; a trailing slash, a
  port, or `http` for `https` all fail the exact match by design.
- **Redirected to `localhost` and nothing loads.** The server did not see the
  allowlist, so it built the redirect from the loopback origin. Check the env
  var reached the process, then look for the `Proxy sign-in` line.
- **`Local sign-in` prints but `Proxy sign-in` does not.**
  `WEB_NEXT_EXTRA_LOCAL_ORIGINS` is unset or empty in that shell.
- **Connection refused from a peer, server running.** Serve is not fronting the
  port. `$TS serve status` shows the mapping.
- **`tailscale: command not found`.** Expected on macOS — see step 0.
- **The app's pairing window says there is no tailnet.** `$TS status` from a
  shell will say the same thing and why; the window surfaces the node state
  rather than changing it.
