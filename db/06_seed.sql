-- =============================================================================
-- 06_seed.sql  -  reference data (apps, roles, permissions, sidebar) + demo users.
-- Change who sees what by editing DATA here, not code.
-- =============================================================================

-- ---------------------------------------------------------------- apps ------
INSERT INTO iam.app (code, name, description, icon, route, schema_name, sort_order) VALUES
    ('ERP',     'ERP',     'Payables, payments and supplier ageing',      'receipt',   '/app/erp',     'erp',     1),
    ('AML',     'AML',     'Alerts, investigation cases and risk review', 'shield',    '/app/aml',     'aml',     2),
    ('LENDING', 'Lending', 'Loan applications and disbursements',         'landmark',  '/app/lending', 'lending', 3);

-- --------------------------------------------------------- permissions ------
INSERT INTO iam.permission (code, description) VALUES
    ('dashboard.view',      'See dashboards and KPIs'),
    ('dataset.view',        'See uploaded batches and their records'),
    ('dataset.upload',      'Upload source files'),
    ('mapping.review',      'Review and approve field mappings'),
    ('data_quality.review', 'Resolve validation issues'),
    ('batch.commit',        'Commit a validated batch (checker)'),
    ('report.view',         'Open reports'),
    ('report.generate',     'Generate and download reports/documents'),
    ('template.view',       'See templates'),
    ('template.edit',       'Create and edit template drafts'),
    ('template.approve',    'Approve and publish templates (checker)'),
    ('assistant.use',       'Use Smart Assistance'),
    ('admin.users',         'Manage users and roles in this app');

-- ---------------------------------------------------------------- roles -----
INSERT INTO iam.role (code, name, description) VALUES
    ('APP_ADMIN', 'App Admin', 'Everything in the app, including user management'),
    ('REVIEWER',  'Reviewer',  'Checker: approves commits and templates'),
    ('ANALYST',   'Analyst',   'Maker: uploads, maps, fixes data, drafts templates'),
    ('VIEWER',    'Viewer',    'Read dashboards and reports');

-- Role -> permission matrix.
INSERT INTO iam.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM (VALUES
    ('VIEWER',   ARRAY['dashboard.view','dataset.view','report.view','report.generate','template.view','assistant.use']),
    ('ANALYST',  ARRAY['dashboard.view','dataset.view','report.view','report.generate','template.view','assistant.use',
                       'dataset.upload','mapping.review','data_quality.review','template.edit']),
    ('REVIEWER', ARRAY['dashboard.view','dataset.view','report.view','report.generate','template.view','assistant.use',
                       'mapping.review','data_quality.review','batch.commit','template.approve']),
    ('APP_ADMIN', (SELECT array_agg(code) FROM iam.permission))
) AS m(role_code, perms)
JOIN iam.role r ON r.code = m.role_code
JOIN iam.permission p ON p.code = ANY (m.perms);

-- -------------------------------------------------------------- sidebar -----
-- Shared by all apps (app_id NULL). Parents first, then children.
INSERT INTO iam.menu_item (code, label, route, icon, sort_order, required_permission_id)
SELECT m.code, m.label, m.route, m.icon, m.sort_order, p.permission_id
FROM (VALUES
    ('dashboard',      'Dashboard',         '/dashboard',     'layout-dashboard', 10, 'dashboard.view'),
    ('datasets',       'Datasets',          '/datasets',      'database',         20, 'dataset.view'),
    ('mapping',        'Mapping Review',    '/mapping',       'git-compare',      30, 'mapping.review'),
    ('data_quality',   'Data Quality',      '/data-quality',  'badge-check',      40, 'data_quality.review'),
    ('reports',        'Reports',           '/reports',       'file-bar-chart',   50, 'report.view'),
    ('templates',      'Templates',         '/templates',     'file-text',        60, 'template.view'),
    ('assistant',      'Smart Assistance',  '/assistant',     'sparkles',         70, 'assistant.use'),
    ('admin',          'Administration',    '/admin',         'settings',         80, 'admin.users')
) AS m(code, label, route, icon, sort_order, perm)
JOIN iam.permission p ON p.code = m.perm;

INSERT INTO iam.menu_item (parent_id, code, label, route, icon, sort_order, required_permission_id)
SELECT parent.menu_item_id, m.code, m.label, m.route, m.icon, m.sort_order, p.permission_id
FROM (VALUES
    ('datasets', 'datasets.list',   'All batches',  '/datasets',        'list',   1, 'dataset.view'),
    ('datasets', 'datasets.upload', 'Upload file',  '/datasets/upload', 'upload', 2, 'dataset.upload'),
    ('admin',    'admin.users',     'Users & roles','/admin/users',     'users',  1, 'admin.users')
) AS m(parent_code, code, label, route, icon, sort_order, perm)
JOIN iam.menu_item parent ON parent.code = m.parent_code
JOIN iam.permission p ON p.code = m.perm;

-- ---------------------------------------------------------- demo users ------
-- DEMO ONLY. All demo accounts share the password: Studio#2026
--   admin@studio.local      super admin (all apps, all permissions)
--   manager@studio.local    REVIEWER in ERP, AML, LENDING     -> sees 3 cards
--   associate@studio.local  ANALYST  in ERP, AML              -> sees 2 cards
--   viewer@studio.local     VIEWER   in LENDING               -> sees 1 card
--   erpadmin@studio.local   APP_ADMIN in ERP                  -> manages ERP users
INSERT INTO iam.app_user (email, full_name, password_hash, is_super_admin) VALUES
    ('admin@studio.local',     'Super Admin',     iam._hash_password('Studio#2026'), true),
    ('manager@studio.local',   'Maya Manager',    iam._hash_password('Studio#2026'), false),
    ('associate@studio.local', 'Arun Associate',  iam._hash_password('Studio#2026'), false),
    ('viewer@studio.local',    'Vera Viewer',     iam._hash_password('Studio#2026'), false),
    ('erpadmin@studio.local',  'Eshan ERP Admin', iam._hash_password('Studio#2026'), false);

INSERT INTO iam.user_app_role (user_id, app_id, role_id)
SELECT u.user_id, a.app_id, r.role_id
FROM (VALUES
    ('manager@studio.local',   'ERP',     'REVIEWER'),
    ('manager@studio.local',   'AML',     'REVIEWER'),
    ('manager@studio.local',   'LENDING', 'REVIEWER'),
    ('associate@studio.local', 'ERP',     'ANALYST'),
    ('associate@studio.local', 'AML',     'ANALYST'),
    ('viewer@studio.local',    'LENDING', 'VIEWER'),
    ('erpadmin@studio.local',  'ERP',     'APP_ADMIN')
) AS g(email, app_code, role_code)
JOIN iam.app_user u ON u.email = g.email::citext
JOIN iam.app a      ON a.code = g.app_code
JOIN iam.role r     ON r.code = g.role_code;
