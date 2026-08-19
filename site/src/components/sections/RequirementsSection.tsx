import SectionShell from '@/components/SectionShell'
import { siteCopy } from '@/copy'

// Plain, scannable, no icons.
export default function RequirementsSection() {
  const { requirements } = siteCopy

  return (
    <SectionShell id="requirements" heading={requirements.heading}>
      <div className="grid grid-cols-1 gap-10 sm:grid-cols-2">
        {requirements.groups.map((group) => (
          <div key={group.title}>
            <h3 className="text-sm font-semibold text-foreground">{group.title}</h3>
            <ul className="mt-3 flex flex-col gap-2">
              {group.items.map((item) => (
                <li key={item} className="text-sm text-muted-foreground">
                  {item}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </SectionShell>
  )
}
