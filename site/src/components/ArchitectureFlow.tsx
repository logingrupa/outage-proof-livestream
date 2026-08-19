import { cn } from '@/lib/utils'
import { siteCopy } from '@/copy'

// The page's original device (D-17): a semantic ordered list, not a stock
// diagram or SVG-of-text. Horizontal flow on wide screens, vertical stack on
// narrow; connectors are plain CSS dividers between list items.
export default function ArchitectureFlow() {
  const { flowNodes } = siteCopy.howItWorks

  return (
    <ol className="flex flex-col divide-y divide-border rounded-lg border border-border md:flex-row md:divide-x md:divide-y-0">
      {flowNodes.map((node, index) => (
        <li
          key={node.id}
          className={cn(
            'flex-1 p-5',
            node.emphasised && 'bg-primary/10',
          )}
        >
          <span className="text-xs text-muted-foreground">{index + 1}</span>
          <p
            className={cn(
              'mt-1 font-mono text-sm font-medium',
              node.emphasised && 'text-primary',
            )}
          >
            {node.label}
          </p>
          <p className="mt-1 text-sm text-muted-foreground">{node.description}</p>
        </li>
      ))}
    </ol>
  )
}
