import { Check, Copy } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useCopyToClipboard } from '@/hooks/useCopyToClipboard'

interface CopyButtonProps {
  text: string
  label: string
}

export default function CopyButton({ text, label }: CopyButtonProps) {
  const { copied, copy } = useCopyToClipboard()

  return (
    <Button
      variant="ghost"
      size="icon-sm"
      onClick={() => copy(text)}
      aria-label={copied ? `${label} copied` : `Copy ${label}`}
    >
      {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
      <span className="sr-only" role="status">
        {copied ? 'Copied to clipboard' : ''}
      </span>
    </Button>
  )
}
