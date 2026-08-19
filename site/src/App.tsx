import { TooltipProvider } from '@/components/ui/tooltip'
import PageHeader from '@/components/layout/PageHeader'
import PageFooter from '@/components/layout/PageFooter'
import HeroSection from '@/components/sections/HeroSection'
import ProblemSection from '@/components/sections/ProblemSection'
import HowItWorksSection from '@/components/sections/HowItWorksSection'
import ZeroCounterStrip from '@/components/sections/ZeroCounterStrip'
import DashboardSection from '@/components/sections/DashboardSection'
import QuickstartSection from '@/components/sections/QuickstartSection'
import TransportSection from '@/components/sections/TransportSection'
import RequirementsSection from '@/components/sections/RequirementsSection'
import FaqSection from '@/components/sections/FaqSection'
import MissionSection from '@/components/sections/MissionSection'
import ClosingCallToActionSection from '@/components/sections/ClosingCallToActionSection'

// Locked section order (D-06, extended to eleven by D-24): hero, problem,
// how it works, zero-counter strip, dashboard, quickstart, transport,
// requirements, FAQ, mission, footer.
// TooltipProvider mounts once here, not per-consumer (DRY; Radix expects a
// single provider). 150ms is short enough to feel responsive without firing
// on an accidental cursor pass-through.
function App() {
  return (
    <TooltipProvider delayDuration={150}>
      <PageHeader />
      <main>
        <HeroSection />
        <ProblemSection />
        <HowItWorksSection />
        <ZeroCounterStrip />
        <DashboardSection />
        <QuickstartSection />
        <TransportSection />
        <RequirementsSection />
        <FaqSection />
        <MissionSection />
        <ClosingCallToActionSection />
      </main>
      <PageFooter />
    </TooltipProvider>
  )
}

export default App
