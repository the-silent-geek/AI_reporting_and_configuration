import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Card, PageHeader } from '../../components/ui/Misc'
import { api } from '../../lib/api'
import { useApp } from '../../lib/appContext'

type Document = { template_code: string; version: number; template: { title: string; sections: { heading: string; fields: { label: string; binding: string }[] }[] }; record: Record<string, unknown> }
export function RecordTemplate() {
  const { app, code } = useApp()
  const [params] = useSearchParams()
  const entity=params.get('entity') ?? '', key=params.get('key') ?? ''
  const [doc,setDoc]=useState<Document|null>(null)
  const [error,setError]=useState('')
  useEffect(()=>{
    let active=true
    setDoc(null); setError('')
    api<Document>(`/api/apps/${code}/templates/record/preview?${new URLSearchParams({entity,record_key:key})}`)
      .then(d=>{if(active) setDoc(d)}).catch(e=>{if(active) setError(e.message)})
    return ()=>{active=false}
  },[code,entity,key])
  return <><PageHeader title={doc?.template.title ?? 'Record template'} description={`Record: ${key}`} />
    <Link className="text-sm underline" to={`${app.route}/assistant`}>Back to Smart Assistance</Link>
    {error && <p role="alert" className="mt-4 text-danger">{error}</p>}
    {!doc&&!error&&<p role="status" className="mt-4">Loading record…</p>}
    {doc&&<Card className="mt-4 p-6"><p className="mb-4 text-xs text-fg-muted">{doc.template_code} · Version {doc.version} · Current committed data</p>
      {doc.template.sections.map((s,i)=><section key={i}><h2 className="mb-3 font-semibold">{s.heading}</h2><dl className="grid grid-cols-1 gap-3 sm:grid-cols-2">{s.fields.map(f=><div key={f.binding} className="border-b border-border pb-2"><dt className="text-xs text-fg-muted">{f.label}</dt><dd className="mt-1 break-words text-sm">{String(doc.record[f.binding] ?? '—')}</dd></div>)}</dl></section>)}
    </Card>}
  </>
}
