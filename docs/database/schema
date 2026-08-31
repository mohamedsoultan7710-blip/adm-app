-- ============================================================================
-- ADM (Association Djiboutienne au Maroc) — Application mobile + Dashboard
-- Schéma PostgreSQL / Supabase — v1.0
--
-- Ce fichier crée : extensions, types énumérés, tables, contraintes, index,
-- triggers utilitaires et fonctions métier (calcul d'expiration, audit).
--
-- Les politiques RLS sont dans rls_policies.sql (à exécuter APRÈS ce fichier).
-- Les données de départ (app_settings, document_types, etc.) sont dans
-- seed_data.sql (à exécuter APRÈS rls_policies.sql, avec un rôle privilégié).
--
-- Convention : tous les timestamps sont en UTC (timestamptz). Toutes les clés
-- primaires sont des UUID générés côté serveur (gen_random_uuid(), disponible
-- nativement depuis PostgreSQL 13, utilisé par Supabase).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. EXTENSIONS
-- ----------------------------------------------------------------------------
create extension if not exists "pgcrypto";      -- gen_random_uuid(), digest()
create extension if not exists "pg_trgm";        -- recherche floue (nom/email/etc.)
create extension if not exists "unaccent";       -- recherche insensible aux accents

-- ----------------------------------------------------------------------------
-- 1. TYPES ÉNUMÉRÉS
-- ----------------------------------------------------------------------------
-- NB : les listes "métier" qui doivent rester modifiables SANS migration SQL
-- (types d'établissement, catégories d'urgence, catégories d'actualité, etc.)
-- ne sont volontairement PAS des enums : elles vivent dans app_settings ou
-- dans une table de référence dédiée (voir section 3). Les enums ci-dessous
-- ne couvrent que des machines à états internes, peu susceptibles de changer.

create type app_role as enum (
  'SUPER_ADMIN',
  'ADMIN',
  'RESPONSABLE',
  'ETUDIANT'
);

create type scholarship_status as enum (
  'BOURSIER',
  'NON_BOURSIER'
);

create type document_status as enum (
  'EN_ATTENTE',
  'VERIFIE',
  'REFUSE',
  'EXPIRE',
  'A_RENOUVELER'
);

create type news_status as enum (
  'BROUILLON',
  'PUBLIE',
  'ARCHIVE'
);

create type notification_type as enum (
  'ACTUALITE',
  'DOCUMENT',
  'EXPIRATION',
  'URGENCE',
  'ASSISTANCE',
  'ADMINISTRATION',
  'GENERAL'
);

create type emergency_status as enum (
  'NOUVELLE',
  'PRISE_EN_CHARGE',
  'EN_COURS',
  'RESOLUE',
  'FERMEE'
);

create type emergency_priority as enum (
  'FAIBLE',
  'MOYENNE',
  'ELEVEE',
  'CRITIQUE'
);

-- Statut générique réutilisé par assistance_requests (proposition, voir §12)
create type request_status as enum (
  'NOUVELLE',
  'EN_COURS',
  'REPONDUE',
  'FERMEE'
);

create type account_status as enum (
  'ACTIF',
  'DESACTIVE'
);

-- ----------------------------------------------------------------------------
-- Fonction utilitaire : maintien automatique de updated_at
-- ----------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- 2. TABLES DE RÉFÉRENCE (lookup tables) — gérées par SUPER_ADMIN
-- ============================================================================

create table cities (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  country     text not null default 'Maroc',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (name, country)
);

create table universities (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  city_id     uuid references cities(id) on delete set null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table document_types (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null unique,
  description           text,
  requires_expiry_date  boolean not null default true,
  is_required           boolean not null default false,
  is_active             boolean not null default true,
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now()
);

create table scholarship_types (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- 3. IDENTITÉ & PROFILS
-- ============================================================================

-- profiles : une ligne par utilisateur Supabase Auth (étudiant OU membre ADM).
-- Le rôle applicatif n'est PAS stocké ici : il vit exclusivement dans
-- admin_roles (voir §4). Un utilisateur sans ligne admin_roles active est
-- traité comme ETUDIANT par défaut côté RLS.
create table profiles (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null unique references auth.users(id) on delete cascade,
  first_name     text not null,
  last_name      text not null,
  phone          text,
  email          text not null,
  photo_url      text,
  date_of_birth  date,
  city_id        uuid references cities(id) on delete set null,
  address        text,
  status         account_status not null default 'ACTIF',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on profiles
  for each row execute function set_updated_at();

-- students : extension du profil pour les utilisateurs ayant le rôle ETUDIANT.
-- Séparée de profiles pour ne pas polluer les comptes ADM avec des champs
-- académiques qui ne les concernent pas.
create table students (
  id                    uuid primary key default gen_random_uuid(),
  profile_id            uuid not null unique references profiles(id) on delete cascade,
  institution_id        uuid references universities(id) on delete set null,
  level                 text,                     -- ex: "Licence 2" — liste modifiable via app_settings
  field_of_study        text,
  institution_type      text not null default 'public', -- 'public' | 'privé' | 'autre' — voir app_settings.institution_types
  scholarship_status    scholarship_status not null default 'NON_BOURSIER',
  scholarship_type_id   uuid references scholarship_types(id) on delete set null,
  academic_year         text,                     -- ex: "2025-2026"
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint chk_scholarship_type_consistency check (
    scholarship_status = 'NON_BOURSIER' or scholarship_type_id is not null
  )
);

create trigger trg_students_updated_at
  before update on students
  for each row execute function set_updated_at();

-- admin_roles : source de vérité unique pour le RBAC. Un même user_id peut
-- avoir plusieurs lignes (rare) mais en pratique une seule ligne active.
-- scope_city_ids / scope_institution_ids : périmètre optionnel pour le rôle
-- RESPONSABLE (proposition — à valider avec l'ADM, voir PROJECT_PLAN.md §6).
create table admin_roles (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users(id) on delete cascade,
  role                   app_role not null,
  scope_city_ids         uuid[] not null default '{}',
  scope_institution_ids  uuid[] not null default '{}',
  is_active              boolean not null default true,
  granted_by             uuid references auth.users(id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint chk_admin_role_not_etudiant check (role <> 'ETUDIANT')
);

create trigger trg_admin_roles_updated_at
  before update on admin_roles
  for each row execute function set_updated_at();

create unique index uq_admin_roles_active_user_role
  on admin_roles(user_id, role) where is_active;

-- ============================================================================
-- 4. DOCUMENTS
-- ============================================================================

create table documents (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references students(id) on delete cascade,
  document_type_id  uuid not null references document_types(id) on delete restrict,
  file_path         text not null,          -- chemin dans le bucket privé Storage (jamais d'URL publique)
  issue_date        date,
  expiry_date       date,
  status            document_status not null default 'EN_ATTENTE',
  rejection_reason  text,
  verified_by       uuid references auth.users(id) on delete set null,
  verified_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint chk_rejection_reason_required check (
    status <> 'REFUSE' or rejection_reason is not null
  )
);

create trigger trg_documents_updated_at
  before update on documents
  for each row execute function set_updated_at();

create index idx_documents_student on documents(student_id);
create index idx_documents_status on documents(status);
create index idx_documents_expiry on documents(expiry_date) where expiry_date is not null;

-- ============================================================================
-- 5. ACTUALITÉS
-- ============================================================================

create table news (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  summary        text,
  content        text not null,
  image_path     text,                     -- chemin dans un bucket Storage (public ou privé selon config)
  category       text not null default 'Annonce',  -- voir app_settings.news_categories
  status         news_status not null default 'BROUILLON',
  author_id      uuid not null references auth.users(id) on delete restrict,
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger trg_news_updated_at
  before update on news
  for each row execute function set_updated_at();

create index idx_news_status_published on news(status, published_at desc);
create index idx_news_category on news(category);

-- ============================================================================
-- 6. NOTIFICATIONS
-- ============================================================================

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  title          text not null,
  message        text not null,
  type           notification_type not null default 'GENERAL',
  reference_id   uuid,                     -- id libre vers l'entité liée (news, document, urgence, ...)
  is_read        boolean not null default false,
  created_at     timestamptz not null default now()
);

create index idx_notifications_user_unread on notifications(user_id, is_read, created_at desc);

-- device_tokens (PROPOSITION — non listée explicitement au §25 mais requise
-- par le §49 "notifications push ciblées" ; nécessaire pour associer un
-- jeton FCM/APNs à un utilisateur et permettre l'envoi ciblé).
create table device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token        text not null,
  platform     text not null check (platform in ('android', 'ios')),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, token)
);

create trigger trg_device_tokens_updated_at
  before update on device_tokens
  for each row execute function set_updated_at();

-- ============================================================================
-- 7. ASSISTANCE (PROPOSITION)
-- ============================================================================
-- Le cahier des charges distingue clairement "demande d'assistance" (§6, §42
-- écran 17 "Centre d'assistance") de "demande d'urgence" (§16-21), mais la
-- liste minimale de tables (§25) ne mentionne qu'emergency_requests. Pour ne
-- pas mélanger deux workflows différents (l'assistance est non-géolocalisée,
-- non-critique, traitée comme un ticket de support), on propose une table
-- dédiée, structurellement proche mais plus simple. À valider avec l'ADM :
-- si "assistance" et "urgence" doivent finalement être unifiées, cette table
-- peut être supprimée sans impact sur le reste du schéma.
create table assistance_requests (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references students(id) on delete cascade,
  subject      text not null,
  message      text not null,
  status       request_status not null default 'NOUVELLE',
  assigned_to  uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  closed_at    timestamptz
);

create index idx_assistance_student on assistance_requests(student_id);
create index idx_assistance_status on assistance_requests(status);

-- ============================================================================
-- 8. URGENCES
-- ============================================================================

create table emergency_requests (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references students(id) on delete cascade,
  category       text not null,           -- voir app_settings.emergency_categories
  message        text not null,
  priority       emergency_priority not null default 'MOYENNE',
  status         emergency_status not null default 'NOUVELLE',
  assigned_to    uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  accepted_at    timestamptz,
  resolved_at    timestamptz,
  closed_at      timestamptz
);

create index idx_emergency_student on emergency_requests(student_id);
create index idx_emergency_status on emergency_requests(status);
create index idx_emergency_active on emergency_requests(status)
  where status not in ('RESOLUE', 'FERMEE');

-- emergency_locations : partage VOLONTAIRE et PONCTUEL uniquement (jamais de
-- suivi permanent — voir §19 et §61). Accès restreint aux responsables
-- autorisés via RLS (rls_policies.sql).
create table emergency_locations (
  id            uuid primary key default gen_random_uuid(),
  emergency_id  uuid not null references emergency_requests(id) on delete cascade,
  latitude      double precision not null check (latitude between -90 and 90),
  longitude     double precision not null check (longitude between -180 and 180),
  shared_at     timestamptz not null default now()
);

create index idx_emergency_locations_emergency on emergency_locations(emergency_id);

-- ============================================================================
-- 9. AUDIT & CONFIGURATION
-- ============================================================================

-- audit_logs : append-only. Aucune politique RLS d'UPDATE/DELETE ne sera
-- créée (voir rls_policies.sql) — l'absence de politique équivaut à un refus
-- avec RLS activé, ce qui protège la table contre toute altération.
create table audit_logs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  action       text not null,             -- ex: 'DOCUMENT_VERIFIED', 'STUDENT_VIEWED', 'ROLE_CHANGED'
  target_type  text not null,             -- ex: 'document', 'student', 'news', 'emergency_request'
  target_id    uuid,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

create index idx_audit_logs_user on audit_logs(user_id, created_at desc);
create index idx_audit_logs_target on audit_logs(target_type, target_id);

-- app_settings : configuration clé/valeur modifiable par SUPER_ADMIN sans
-- déploiement. Utilisée pour : seuils d'expiration, listes déroulantes
-- modifiables (institution_types, emergency_categories, news_categories),
-- textes légaux (avertissement urgence, politique de confidentialité).
create table app_settings (
  key          text primary key,
  value        jsonb not null,
  description  text,
  updated_by   uuid references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now()
);

create trigger trg_app_settings_updated_at
  before update on app_settings
  for each row execute function set_updated_at();

-- ============================================================================
-- 10. FONCTIONS MÉTIER
-- ============================================================================

-- Seuils par défaut (utilisés si app_settings.document_expiry_thresholds est
-- absente) : cf. §10 du cahier des charges.
create or replace function get_document_alert_level(p_expiry_date date)
returns text
language plpgsql
stable
as $$
declare
  v_days_left integer;
  v_thresholds jsonb;
begin
  if p_expiry_date is null then
    return 'NON_APPLICABLE';
  end if;

  select value into v_thresholds from app_settings where key = 'document_expiry_thresholds';
  if v_thresholds is null then
    v_thresholds := '{"valide": 90, "a_surveiller": 30, "expiration_prochaine": 7}'::jsonb;
  end if;

  v_days_left := p_expiry_date - current_date;

  if v_days_left < 0 then
    return 'EXPIRE';
  elsif v_days_left < (v_thresholds->>'expiration_prochaine')::int then
    return 'URGENT';
  elsif v_days_left < (v_thresholds->>'a_surveiller')::int then
    return 'EXPIRATION_PROCHAINE';
  elsif v_days_left < (v_thresholds->>'valide')::int then
    return 'A_SURVEILLER';
  else
    return 'VALIDE';
  end if;
end;
$$;

comment on function get_document_alert_level(date) is
  'Calcule le niveau d''alerte visuel (VALIDE / A_SURVEILLER / EXPIRATION_PROCHAINE / URGENT / EXPIRE) '
  'à partir de la date d''expiration. Distinct du champ documents.status, qui reflète le workflow '
  'de vérification administrative. Les seuils sont configurables via app_settings.';

-- Vue pratique combinant documents + niveau d'alerte calculé, utilisée par le
-- dashboard et par la tâche planifiée d'envoi de rappels (§11).
--
-- security_invoker = true est OBLIGATOIRE ici (corrigé lors de l'audit Phase 1,
-- étape 1) : par défaut, une vue PostgreSQL s'exécute avec les droits de son
-- PROPRIÉTAIRE sur les tables sous-jacentes, pas ceux du rôle qui l'interroge.
-- Or le propriétaire d'une table (le rôle des migrations) contourne RLS par
-- défaut, sauf FORCE ROW LEVEL SECURITY. Sans cette option, n'importe quel
-- rôle authenticated interrogeant cette vue via l'API verrait TOUS les
-- documents de TOUS les étudiants, contournant entièrement les politiques RLS
-- de la table documents. Toute future vue de ce projet doit reprendre cette
-- option par défaut, sauf besoin explicite contraire.
create or replace view v_documents_with_alert
  with (security_invoker = true)
as
select
  d.*,
  get_document_alert_level(d.expiry_date) as alert_level
from documents d;

-- Journalisation générique, appelée depuis les Edge Functions ou des triggers
-- SECURITY DEFINER (jamais directement par le client — voir rls_policies.sql).
create or replace function log_audit_action(
  p_user_id uuid,
  p_action text,
  p_target_type text,
  p_target_id uuid,
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into audit_logs (user_id, action, target_type, target_id, metadata)
  values (p_user_id, p_action, p_target_type, p_target_id, p_metadata);
end;
$$;

-- Trigger : création automatique du profil à l'inscription (auth.users).
-- Les métadonnées (first_name, last_name, ...) sont fournies lors du signUp
-- via `data:` côté Flutter (supabase_flutter) et récupérées ici.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, first_name, last_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'first_name', ''),
    coalesce(new.raw_user_meta_data->>'last_name', ''),
    new.email
  );
  return new;
end;
$$;

create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function handle_new_user();

-- Trigger : historise automatiquement la vérification d'un document dans
-- audit_logs dès que son statut change vers VERIFIE ou REFUSE.
create or replace function trg_documents_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status and new.status in ('VERIFIE', 'REFUSE') then
    perform log_audit_action(
      new.verified_by,
      case when new.status = 'VERIFIE' then 'DOCUMENT_VERIFIED' else 'DOCUMENT_REJECTED' end,
      'document',
      new.id,
      jsonb_build_object('rejection_reason', new.rejection_reason)
    );
  end if;
  return new;
end;
$$;

create trigger trg_documents_status_audit
  after update on documents
  for each row execute function trg_documents_audit();

-- ============================================================================
-- 11. INTÉGRITÉ DES CHAMPS DE WORKFLOW (anti-spoofing)
-- ============================================================================
-- Ajouté lors de l'audit Phase 1, étape 1. Constat : les politiques RLS
-- (rls_policies.sql) autorisent un admin/responsable à UPDATE une ligne
-- documents/emergency_requests/assistance_requests, mais rien n'empêchait ce
-- même UPDATE de fournir des valeurs arbitraires pour verified_by,
-- verified_at, accepted_at, resolved_at, closed_at, answered_at — un admin
-- aurait pu (par erreur applicative ou intentionnellement) attribuer une
-- vérification à un autre administrateur, ou falsifier une date de prise en
-- charge. Ces triggers BEFORE UPDATE recalculent ces colonnes côté serveur à
-- partir de auth.uid()/now() dès qu'une transition de statut pertinente est
-- détectée, et ignorent toute valeur envoyée par le client pour ces colonnes
-- précises. Comme un trigger BEFORE ROW modifie NEW avant l'évaluation des
-- contraintes (dont les clauses RLS WITH CHECK), cette réécriture est
-- systématique et ne peut pas être contournée par le client.

create or replace function trg_documents_set_verification_meta()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('VERIFIE', 'REFUSE') then
      new.verified_by := auth.uid();
      new.verified_at := now();
    elsif new.status in ('EN_ATTENTE', 'A_RENOUVELER') then
      new.verified_by := null;
      new.verified_at := null;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_documents_verification_meta
  before update on documents
  for each row execute function trg_documents_set_verification_meta();

create or replace function trg_emergency_set_status_meta()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'PRISE_EN_CHARGE' and new.accepted_at is null then
      new.accepted_at := now();
    elsif new.status = 'RESOLUE' and new.resolved_at is null then
      new.resolved_at := now();
    elsif new.status = 'FERMEE' and new.closed_at is null then
      new.closed_at := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_emergency_status_meta
  before update on emergency_requests
  for each row execute function trg_emergency_set_status_meta();

create or replace function trg_assistance_set_status_meta()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'REPONDUE' and new.answered_at is null then
      new.answered_at := now();
    elsif new.status = 'FERMEE' and new.closed_at is null then
      new.closed_at := now();
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_assistance_status_meta
  before update on assistance_requests
  for each row execute function trg_assistance_set_status_meta();

-- ============================================================================
-- 12. VALIDATION DES LISTES CONFIGURABLES (app_settings)
-- ============================================================================
-- Ajouté lors de l'audit Phase 1, étape 1. Constat : students.institution_type,
-- emergency_requests.category et news.category sont des colonnes TEXT libres,
-- documentées comme devant respecter les listes configurables dans
-- app_settings (institution_types / emergency_categories / news_categories),
-- mais rien ne l'imposait côté serveur — un client bogué ou malveillant
-- pouvait écrire n'importe quelle chaîne. Le trigger ci-dessous vérifie la
-- valeur contre la liste app_settings correspondante. Comportement permissif
-- tant que la clé app_settings n'existe pas encore (évite un blocage avant
-- l'exécution de seed_data.sql ou pendant l'initialisation d'un projet) : la
-- contrainte devient active dès que la clé est présente.
create or replace function trg_validate_configured_value()
returns trigger
language plpgsql
as $$
declare
  v_key text;
  v_value text;
  v_allowed jsonb;
begin
  if tg_table_name = 'students' then
    v_key := 'institution_types';
    v_value := new.institution_type;
  elsif tg_table_name = 'emergency_requests' then
    v_key := 'emergency_categories';
    v_value := new.category;
  elsif tg_table_name = 'news' then
    v_key := 'news_categories';
    v_value := new.category;
  else
    return new;
  end if;

  select value into v_allowed from app_settings where key = v_key;
  if v_allowed is null then
    return new;
  end if;

  if not (v_allowed ? v_value) then
    raise exception 'Valeur "%" non autorisée pour %.% — voir app_settings["%"] pour les valeurs permises.',
      v_value, tg_table_name, v_key, v_key;
  end if;

  return new;
end;
$$;

create trigger trg_students_validate_institution_type
  before insert or update on students
  for each row execute function trg_validate_configured_value();

create trigger trg_emergency_validate_category
  before insert or update on emergency_requests
  for each row execute function trg_validate_configured_value();

create trigger trg_news_validate_category
  before insert or update on news
  for each row execute function trg_validate_configured_value();

-- ============================================================================
-- Fin de schema.sql — enchaîner avec rls_policies.sql
-- ============================================================================
