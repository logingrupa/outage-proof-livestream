import { siteCopy } from '@/copy'

// Quiet, small, muted (D-01) -- outside <main>, after the mission section.
export default function PageFooter() {
  const { footer } = siteCopy

  return (
    <footer id="footer" className="border-t border-border py-10">
      <div className="mx-auto flex max-w-5xl flex-col gap-3 px-6 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
        <p>
          {footer.licencePrefix}
          <a href={footer.licenceHref} className="underline underline-offset-4 hover:text-foreground">
            {footer.licenceLinkLabel}
          </a>
          {footer.licenceSuffix}
        </p>
        <div className="flex items-center gap-4">
          <a href={footer.repositoryHref} className="underline underline-offset-4 hover:text-foreground">
            {footer.repositoryLabel}
          </a>
          <span>{footer.attribution}</span>
        </div>
      </div>
    </footer>
  )
}
