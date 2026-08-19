import CopyButton from '@/components/CopyButton'

interface CommandBlockProps {
  command: string
}

export default function CommandBlock({ command }: CommandBlockProps) {
  return (
    <div className="flex items-start justify-between gap-3 rounded-md border border-border bg-muted/40 px-4 py-3">
      <pre className="command-wrap min-w-0 flex-1">
        <code className="font-mono text-sm">{command}</code>
      </pre>
      <CopyButton text={command} label="command" />
    </div>
  )
}
