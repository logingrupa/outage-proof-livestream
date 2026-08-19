import SectionShell from '@/components/SectionShell'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from '@/components/ui/table'
import { siteCopy } from '@/copy'

// Secondary section (D-06) -- brief, must not out-shout the quickstart.
export default function TransportSection() {
  const { transport } = siteCopy

  return (
    <SectionShell id="transport" heading={transport.heading} lead={transport.lead}>
      <div className="max-w-2xl">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Transport</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Notes</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {transport.rows.map((row) => (
              <TableRow key={row.transport}>
                <TableCell className="font-mono whitespace-normal">{row.transport}</TableCell>
                <TableCell className="whitespace-normal">{row.status}</TableCell>
                <TableCell className="whitespace-normal text-muted-foreground">{row.notes}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <p className="mt-6 text-sm leading-relaxed text-muted-foreground">{transport.defaultReason}</p>
      </div>
    </SectionShell>
  )
}
