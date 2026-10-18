# outage-proof-livestream

A church-service livestream pipeline that survives network, router, and relay outages with zero content loss.

## Value proposition

OBS records the service to a local `.ts` file on disk and never touches the network directly. A small Windows service (`pusher.ps1`) tails that growing file and pushes it to a relay VPS, which fans it out to YouTube.

Any outage in the network, the router, or the relay means **zero content loss** — the disk file on the church PC *is* the buffer. When connectivity comes back, the pusher resumes from the exact byte offset it left off at and catches up faster than realtime, so the YouTube DVR stays gapless.

Nothing is ever skipped, and nothing is ever reordered. The pusher reads the recording file strictly in consecutive byte order — that guarantee is what makes the output gapless, even after a multi-minute outage.

## Architecture

```
OBS  -->  local .ts file  -->  pusher.ps1 (tails from byte offset)  -->  [tcp | srt]  -->  VPS relay  -->  YouTube
```

The leftmost hop (OBS writing to disk) never leaves the machine — the `.ts` file is the buffer that makes every hop to its right recoverable. If the pusher, the network, or the relay drops out, the file just keeps growing on disk until the pusher can resume sending from where it left off.

## Requirements

- **Church PC:** Windows 10 or newer, PowerShell 7.4+, ffmpeg 7.1.x on `PATH`
- **Relay:** an Ubuntu VPS with a public IP (no bonded WAN, no special router, no tunnel required)

## Quickstart — Windows (the church PC)

1. Clone this repository onto the machine running OBS.
2. Copy `.env.example` to `.env` and set at least:
   - `RECORDING_FOLDER_PATH` — the folder OBS records `.ts` files into
   - `RELAY_HOST` / `RELAY_PORT` — the VPS relay's address and port
3. Run `install.ps1` from an elevated (Administrator) PowerShell prompt.

`install.ps1` is honest about what it does and does not do: it registers a Windows Scheduled Task (`GaplessSupervisor`) that starts the supervisor at boot. The task runs `supervisor.ps1` as the account that ran the elevated installer (or the one passed as `-OperatorUserName`) under S4U, so it runs at boot before anyone logs on and stores no password. It has a boot trigger, a daily 04:05 watchdog and no execution time limit. The daily watchdog repeats every 5 minutes, so a supervisor that died is relaunched within 5 minutes, and a running one is never touched. A legacy `GaplessSrtPusher` task from older installs is removed automatically. The supervisor comes up **idle** and streams nothing until an operator explicitly presses Start on the dashboard.

## Quickstart — VPS (the relay)

1. Copy the `tools/vps/` folder to the VPS.
2. Run it once with `DRYRUN=1` to preview what it would do, with zero side effects:
   ```bash
   DRYRUN=1 bash tools/vps/setup-vps.sh
   ```
3. Run it for real:
   ```bash
   bash tools/vps/setup-vps.sh
   ```
   This installs ffmpeg if missing, creates a chmod-600 env file at `/etc/default/outage-proof-relay` (empty — you must fill it in yourself), and installs + starts a systemd relay unit listening on port `8890` (the default; override with `RELAY_PORT=...`).
4. Add your YouTube ingest URL to the env file it created:
   ```bash
   echo 'YT_URL=rtmps://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY' | sudo tee -a /etc/default/outage-proof-relay
   sudo systemctl restart outage-proof-relay.service
   ```
5. Open the relay port (`8890` by default) in the VPS firewall — TCP for the default transport, UDP if you chose SRT.

Re-running `setup-vps.sh` is safe at any time, including while a stream is live: it only restarts the relay unit when its configuration actually changed. `DRYRUN=1` mutates nothing at all — not the filesystem, not systemd.

## Transport comparison

| Transport | Status | Notes |
|-----------|--------|-------|
| `tcp` | **Default, recommended** | Plain TCP; the kernel's own congestion control paces the send. No libsrt build needed on either end. Works through NAT with a single forwarded port. |
| `srt` | Advanced | Needs a libsrt-enabled ffmpeg on **both** ends. Rides UDP. Requires `transtype=file` on **both** the pusher and the relay listener — a mismatch is rejected at handshake with `REJECT 1012 MessageAPI/StreamAPI collision`. |

`tcp` is the default because an uncontrolled UDP path can let SRT's file-mode retransmission feed back on itself: packet loss triggers retransmits, retransmits add more load, more load causes more loss — a retransmit storm that gets worse the harder it tries to recover. TCP's own congestion control does not have that failure mode, so it is the safer default for anyone starting from scratch. `srt` remains available for setups that specifically need it, as long as both ends are kept in file mode.

## Dashboard

Once the pusher is running, a live status dashboard is served at `http://localhost:8787`. It is plain HTML and JS with no build step and no bundler — the pusher process serves it directly.

## Scope, honestly

This is church-tech tooling extracted from one production deployment, not a polished product. It assumes a specific workflow (OBS records to disk, a pusher tails that file, a VPS relay fans out to YouTube) and it has sharp edges. Read the code before you trust it with a service you can't afford to lose.

## License

Licensed under the [GNU Affero General Public License v3.0](./LICENSE) (AGPL-3.0).
