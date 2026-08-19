import type { QuickstartCopy } from '../types'

export const quickstart: QuickstartCopy = {
  // Deliberately NOT "Get it running" -- that string must occur exactly
  // once on the page, as the hero's one loud CTA (D-01).
  heading: 'Set it up',
  lead: 'Two machines, two short setups. Neither one needs anything exotic.',
  groups: [
    {
      id: 'windows',
      title: 'Windows (the church PC)',
      steps: [
        {
          prose: 'Clone this repository onto the machine running OBS.',
          command: 'git clone https://github.com/logingrupa/outage-proof-livestream.git',
        },
        {
          prose:
            'Copy .env.example to .env and set RECORDING_FOLDER_PATH (the folder OBS records .ts files into), RELAY_HOST, and RELAY_PORT (your VPS relay’s address and port).',
          command: 'copy .env.example .env',
        },
        {
          prose:
            'Run install.ps1 from an elevated (Administrator) PowerShell prompt. It registers a Windows Scheduled Task that starts the supervisor at boot -- idle, streaming nothing until you press Start on the dashboard.',
          command: '.\\install.ps1',
        },
      ],
    },
    {
      id: 'vps',
      title: 'VPS (the relay)',
      steps: [
        {
          prose: 'Copy the tools/vps/ folder to the VPS.',
        },
        {
          prose: 'Run it once with DRYRUN=1 to preview what it would do, with zero side effects.',
          command: 'DRYRUN=1 bash tools/vps/setup-vps.sh',
        },
        {
          prose:
            'Run it for real. It installs ffmpeg if missing, creates a chmod-600 env file, and installs and starts the relay service listening on the default port.',
          command: 'bash tools/vps/setup-vps.sh',
        },
        {
          prose: 'Add your YouTube ingest URL to the env file it created.',
          command:
            "echo 'YT_URL=rtmps://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY' | sudo tee -a /etc/default/outage-proof-relay",
        },
        {
          prose: 'Restart the relay service so it picks up the new ingest URL.',
          command: 'sudo systemctl restart outage-proof-relay.service',
        },
        {
          prose:
            'Open the relay port (8890 by default) in the VPS firewall -- TCP for the default transport, UDP if you chose SRT.',
        },
      ],
    },
  ],
}
