import { useState } from 'react'
import { Printer } from 'lucide-react'
import { Button } from '../../components/ui/Button'
import { Badge, Card, PageHeader } from '../../components/ui/Misc'

/** Synthetic preview: never writes mock payments into the business database. */
export function Templates() {
  const [preview, setPreview] = useState(true)
  return <>
    <PageHeader title="Templates" description="Preview a sample document template with synthetic data." />
    <Card className="p-6 print:hidden">
      <Badge>Mock template</Badge>
      <h2 className="mt-3 font-semibold">Payment advice</h2>
      <p className="my-3 text-sm text-fg-muted">Payment details and invoice allocations. This example uses fictional records.</p>
      <Button variant="primary" onClick={() => setPreview(true)}>Generate mock document</Button>
    </Card>
    {preview && <Card className="mt-6 p-6">
      <div className="flex justify-between"><h2 className="text-xl font-semibold">Payment Advice</h2><Button icon={Printer} onClick={() => window.print()} className="print:hidden">Print</Button></div>
      <p className="my-4 text-sm text-fg-muted">MOCK • Synthetic example • Not a payment confirmation</p>
      <dl className="grid grid-cols-2 gap-3 text-sm">
        <dt>Payment ID</dt><dd>DEMO-PAY-001</dd><dt>Supplier</dt><dd>Example Supplies Ltd</dd>
        <dt>Payment date</dt><dd>31 October 2026</dd><dt>Amount</dt><dd>INR 25,000.00</dd>
      </dl>
      <h3 className="mt-6 mb-3 font-semibold">Allocations</h3>
      <table className="w-full text-left text-sm"><thead><tr><th>Invoice</th><th className="text-right">Amount (INR)</th></tr></thead>
        <tbody><tr><td className="py-2">DEMO-INV-001</td><td className="text-right">15,000.00</td></tr><tr><td>DEMO-INV-002</td><td className="text-right">10,000.00</td></tr></tbody>
      </table>
      <p className="mt-6 text-xs text-fg-muted">Sample template only. Live template editing and approval are not available on this screen yet.</p>
    </Card>}
  </>
}
