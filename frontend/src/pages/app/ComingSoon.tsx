import { Construction } from 'lucide-react'
import { Link } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Card, EmptyState, PageHeader } from '../../components/ui/Misc'
import { useApp } from '../../lib/appContext'

/** Screens whose backend is not built yet. Honest about it instead of showing fake data. */
export function ComingSoon({ title, description }: { title: string; description: string }) {
  const { app } = useApp()
  return (
    <>
      <PageHeader title={title} description={description} />
      <Card>
        <EmptyState icon={Construction} title="Not available yet"
                    action={<Link to={`${app.route}/datasets`}><Button>Go to datasets</Button></Link>}>
          This module is being connected to the processing pipeline. Your access to it is already configured.
        </EmptyState>
      </Card>
    </>
  )
}
