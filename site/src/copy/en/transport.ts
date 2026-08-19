import type { TransportCopy } from '../types'

export const transport: TransportCopy = {
  heading: 'Choosing a transport',
  lead: 'Two ways to get bytes from the church PC to the relay.',
  rows: [
    {
      transport: 'tcp',
      status: 'Default, recommended',
      notes:
        "Plain TCP; the kernel's own congestion control paces the send. No libsrt build needed on either end. Works through NAT with a single forwarded port.",
    },
    {
      transport: 'srt',
      status: 'Advanced',
      notes:
        'Needs a libsrt-enabled ffmpeg on both ends. Rides UDP. Requires transtype=file on both the pusher and the relay listener -- a mismatch is rejected at handshake.',
    },
  ],
  defaultReason:
    "tcp is the default because an uncontrolled UDP path can let SRT's file-mode retransmission feed back on itself: packet loss triggers retransmits, retransmits add more load, more load causes more loss. TCP's own congestion control has no such failure mode, so it is the safer default for anyone starting from scratch. srt remains available for setups that specifically need it, as long as both ends are kept in file mode.",
}
