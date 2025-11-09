-- Supabase schema for the multi‑tenant F&B SaaS POS system
--
-- This script defines core database structures including organisations (tenants),
-- memberships, plans, subscriptions, and basic business tables like branches
-- and menu items. It also includes row level security policies to isolate
-- tenant data and a function to provision the first organisation for a new user.

-- ---------- Extensions ----------
create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- ---------- Enums ----------
do $$
begin
  create type org_role as enum ('owner','admin','manager','staff','viewer');
exception when duplicate_object then null;
end
$$;

-- ---------- Tenancy roots ----------
create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists org_memberships (
  user_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid not null references organizations(id) on delete cascade,
  role org_role not null default 'staff',
  created_at timestamptz not null default now(),
  primary key (user_id, org_id)
);

-- ---------- Plans and subscriptions ----------
create table if not exists plans (
  id text primary key,
  name text not null,
  monthly_price_cents int not null,
  features jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists subscriptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  plan_id text not null references plans(id),
  status text not null default 'active',
  period_end timestamptz,
  created_at timestamptz not null default now()
);

-- Insert a basic free plan if it doesn't exist
insert into plans (id, name, monthly_price_cents, features)
  values ('free', 'Free', 0,
    '{"max_branches":1,"max_devices":1,"features":["pos_core","reports_basic"]}')
  on conflict (id) do nothing;

-- ---------- Business tables ----------
create table if not exists branches (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists menu_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  price numeric(12,2) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- Row Level Security ----------
alter table organizations   enable row level security;
alter table org_memberships enable row level security;
alter table plans           enable row level security;
alter table subscriptions   enable row level security;
alter table branches        enable row level security;
alter table menu_items      enable row level security;

-- Remove existing policies if they exist to avoid duplicates
drop policy if exists "org_read" on organizations;
drop policy if exists "org_update_admin" on organizations;
drop policy if exists "mship_read" on org_memberships;
drop policy if exists "mship_admin" on org_memberships;
drop policy if exists "plans_public" on plans;
drop policy if exists "subs_read" on subscriptions;
drop policy if exists "subs_admin" on subscriptions;
drop policy if exists "branches_read" on branches;
drop policy if exists "branches_admin" on branches;
drop policy if exists "menu_read" on menu_items;
drop policy if exists "menu_admin" on menu_items;

-- Policies for organizations
create policy "org_read" on organizations
  for select using (
    exists (
      select 1 from org_memberships m
      where m.org_id = organizations.id and m.user_id = auth.uid()
    )
  );

create policy "org_update_admin" on organizations
  for all using (
    exists (
      select 1 from org_memberships m
      where m.org_id = organizations.id and m.user_id = auth.uid()
        and m.role in ('owner','admin')
    )
  ) with check (
    exists (
      select 1 from org_memberships m
      where m.org_id = organizations.id and m.user_id = auth.uid()
        and m.role in ('owner','admin')
    )
  );

-- Policies for org_memberships
create policy "mship_read" on org_memberships
  for select using (
    org_id in (select org_id from org_memberships where user_id = auth.uid())
  );

create policy "mship_admin" on org_memberships
  for all using (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin'))
  ) with check (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin'))
  );

-- Plans are publicly readable
create policy "plans_public" on plans
  for select using (true);

-- Policies for subscriptions
create policy "subs_read" on subscriptions
  for select using (
    org_id in (select org_id from org_memberships where user_id = auth.uid())
  );

create policy "subs_admin" on subscriptions
  for all using (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin'))
  ) with check (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin'))
  );

-- Policies for branches
create policy "branches_read" on branches
  for select using (
    org_id in (select org_id from org_memberships where user_id = auth.uid())
  );

create policy "branches_admin" on branches
  for all using (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin','manager'))
  ) with check (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin','manager'))
  );

-- Policies for menu_items
create policy "menu_read" on menu_items
  for select using (
    org_id in (select org_id from org_memberships where user_id = auth.uid())
  );

create policy "menu_admin" on menu_items
  for all using (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin','manager'))
  ) with check (
    org_id in (select org_id from org_memberships where user_id = auth.uid() and role in ('owner','admin','manager'))
  );

-- ---------- Provisioning function ----------
-- This function creates the first organisation, membership, subscription and branch
-- for a user if they do not already belong to one. It is idempotent and can be
-- called after every login.
create or replace function provision_first_org(p_org_name text)
returns table (org_id uuid, branch_id uuid)
language plpgsql
security definer
as $$
declare
  v_user uuid := auth.uid();
  v_org  uuid;
  v_branch uuid;
begin
  if v_user is null then
    raise exception 'Not authenticated';
  end if;

  -- Check if the user already belongs to an organisation
  select m.org_id into v_org
    from org_memberships m
    where m.user_id = v_user
    limit 1;

  if v_org is null then
    -- Create a new organisation
    insert into organizations(name)
      values (coalesce(p_org_name, 'My Organisation'))
      returning id into v_org;

    -- Assign the current user as owner
    insert into org_memberships(user_id, org_id, role)
      values (v_user, v_org, 'owner');

    -- Create a free subscription
    insert into subscriptions(org_id, plan_id, status)
      values (v_org, 'free', 'active');
  end if;

  -- Ensure the organisation has at least one branch
  select b.id into v_branch
    from branches b
    where b.org_id = v_org
    limit 1;
  if v_branch is null then
    insert into branches(org_id, name)
      values (v_org, 'Main Branch')
      returning id into v_branch;
  end if;

  return query select v_org, v_branch;
end
$$;