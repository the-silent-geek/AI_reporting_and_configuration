/* The DB stores icon keys (iam.app.icon, iam.menu_item.icon). Map them here. */
import {
  BadgeCheck, Database, FileChartColumn, FileText, GitCompare, Landmark, LayoutDashboard, List,
  Receipt, Settings, Shield, Sparkles, Square, Upload, Users, type LucideIcon,
} from 'lucide-react'

const ICONS: Record<string, LucideIcon> = {
  'layout-dashboard': LayoutDashboard,
  database: Database,
  'git-compare': GitCompare,
  'badge-check': BadgeCheck,
  'file-bar-chart': FileChartColumn,
  'file-text': FileText,
  sparkles: Sparkles,
  settings: Settings,
  list: List,
  upload: Upload,
  users: Users,
  receipt: Receipt,
  shield: Shield,
  landmark: Landmark,
}

export const iconFor = (key: string | undefined): LucideIcon => (key && ICONS[key]) || Square
