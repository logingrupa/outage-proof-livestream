import SectionShell from '@/components/SectionShell'
import DashboardGallery from '@/components/DashboardGallery'
import ServiceFiguresPanel from '@/components/ServiceFiguresPanel'
import ServiceRecoveryChart from '@/components/ServiceRecoveryChart'
import { siteCopy } from '@/copy'
import { excludeShot } from '@/lib/shots'

// D-24: sits between the zero-counters and quickstart, so the real evidence
// lands immediately before the conversion moment. Composition only -- the
// gallery, the figures and the chart each own their own rendering.
export default function DashboardSection() {
  const { dashboard } = siteCopy

  return (
    <SectionShell id="dashboard" heading={dashboard.heading} lead={dashboard.lead}>
      <div className="flex flex-col gap-16">
        {/* The catch-up shot lives in the hero, so it is not repeated here. */}
        <DashboardGallery shots={excludeShot(dashboard.shots, 'catchingUp')} />

        <section aria-labelledby="recovery-chart-heading" className="flex flex-col gap-6">
          <div className="flex flex-col gap-2">
            <h3 id="recovery-chart-heading" className="text-xl font-semibold tracking-tight">
              {dashboard.chart.heading}
            </h3>
            <p className="max-w-2xl text-muted-foreground">{dashboard.chart.lead}</p>
          </div>
          <ServiceRecoveryChart />
        </section>

        <ServiceFiguresPanel figures={dashboard.figures} />
      </div>
    </SectionShell>
  )
}
