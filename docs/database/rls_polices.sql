-- ============================================================================
-- ADM — Politiques Row Level Security (RLS)
-- À exécuter APRÈS schema.sql.
--
-- Principes directeurs (cahier des charges §35-36, §61) :
--   1. RLS activé sur TOUTE table contenant des données personnelles.
--   2. Le rôle applicatif n'est JAMAIS déduit d'une valeur envoyée par le
--      client : il est relu depuis admin_roles à chaque vérification, via
--      des fonctions SECURITY DEFINER (évite aussi la récursion RLS).
--   3. Absence de politique = accès refusé (RLS "fail closed"). Les tables
--      sensibles (audit_logs, notifications) n'ont volontairement AUCUNE
--      politique d'INSERT/UPDATE/DELETE pour le rôle authenticated : ces
--      opérations passent uniquement par des fonctions SECURITY DEFINER ou
--      par le service_role (Edge Functions), jamais en écriture directe
--      depuis Flutter/le dashboard.
--   4. Le partage de localisation reste un événement ponctuel et son accès
--      en lecture est strictement limité aux responsables autorisés (§19-20).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. FONCTIONS HELPER (SECURITY DEFINER — court-circuitent RLS en interne
--    pour éviter les dépendances circulaires entre policies et tables)
-- ----------------------------------------------------------------------------

create or replace function fn_has_role(variadic p_roles app_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from admin_roles
    where user_id = auth.uid()
      and is_active
      and role = any(p_roles)
  );
$$;

comment on function fn_has_role(app_role[]) is
  'Vrai si l''utilisateur courant possède un rôle admin actif parmi ceux fournis. '
  'Ne jamais remplacer par une vérification côté client.';

create or replace function fn_is_owner_student(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from students s
    join profiles p on p.id = s.profile_id
    where s.id = p_student_id and p.user_id = auth.uid()
  );
$$;

create or replace function fn_can_manage_student(p_student_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope_cities uuid[];
  v_scope_institutions uuid[];
  v_student_city uuid;
  v_student_institution uuid;
begin
  if fn_has_role('SUPER_ADMIN', 'ADMIN') then
    return true;
  end if;

  select ar.scope_city_ids, ar.scope_institution_ids
    into v_scope_cities, v_scope_institutions
  from admin_roles ar
  where ar.user_id = auth.uid() and ar.is_active and ar.role = 'RESPONSABLE'
  limit 1;

  if not found then
    return false;
  end if;

  -- Décision validée (Mission 1, point 3) : un RESPONSABLE sans périmètre
  -- explicite (aucune ville ET aucun établissement attribués) n'a accès à
  -- AUCUN étudiant. Il n'existe pas d'"accès total implicite" par défaut.
  -- (Corrigé lors de l'audit Phase 1, étape 1 — voir note de bas de fichier.)
  if v_scope_cities = '{}' and v_scope_institutions = '{}' then
    return false;
  end if;

  select p.city_id, s.institution_id into v_student_city, v_student_institution
  from students s
  join profiles p on p.id = s.profile_id
  where s.id = p_student_id;

  if v_scope_cities <> '{}' and not (v_student_city = any(v_scope_cities)) then
    return false;
  end if;
  if v_scope_institutions <> '{}' and not (v_student_institution = any(v_scope_institutions)) then
    return false;
  end if;

  return true;
end;
$$;

comment on function fn_can_manage_student(uuid) is
  'Un RESPONSABLE sans périmètre défini (scope_city_ids et scope_institution_ids '
  'tous deux vides) n''a accès à aucun étudiant — validé Mission 1, point 3. '
  'Un périmètre doit être explicitement attribué par un SUPER_ADMIN.';

-- Verrouillage des privilèges d'exécution : ces fonctions contournent RLS en
-- interne (SECURITY DEFINER) pour lire admin_roles/students/profiles sans
-- récursion. Elles ne doivent être appelables que par des rôles authentifiés
-- via l'API (authenticated) ou par les Edge Functions (service_role) —
-- jamais par anon, et jamais par PUBLIC par défaut.
revoke execute on function fn_has_role(app_role[]) from public;
revoke execute on function fn_is_owner_student(uuid) from public;
revoke execute on function fn_can_manage_student(uuid) from public;
grant execute on function fn_has_role(app_role[]) to authenticated, service_role;
grant execute on function fn_is_owner_student(uuid) to authenticated, service_role;
grant execute on function fn_can_manage_student(uuid) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 1. ACTIVATION DE RLS
-- ----------------------------------------------------------------------------
alter table cities               enable row level security;
alter table universities         enable row level security;
alter table document_types       enable row level security;
alter table scholarship_types    enable row level security;
alter table profiles             enable row level security;
alter table students             enable row level security;
alter table admin_roles          enable row level security;
alter table documents            enable row level security;
alter table news                 enable row level security;
alter table notifications        enable row level security;
alter table device_tokens        enable row level security;
alter table assistance_requests  enable row level security;
alter table emergency_requests   enable row level security;
alter table emergency_locations  enable row level security;
alter table audit_logs           enable row level security;
alter table app_settings         enable row level security;

-- ----------------------------------------------------------------------------
-- 2. TABLES DE RÉFÉRENCE (lecture large, écriture SUPER_ADMIN)
-- ----------------------------------------------------------------------------
create policy ref_select on cities for select using (auth.role() = 'authenticated');
create policy ref_write  on cities for all using (fn_has_role('SUPER_ADMIN')) with check (fn_has_role('SUPER_ADMIN'));

create policy ref_select on universities for select using (auth.role() = 'authenticated');
create policy ref_write  on universities for all using (fn_has_role('SUPER_ADMIN')) with check (fn_has_role('SUPER_ADMIN'));

create policy ref_select on document_types for select using (auth.role() = 'authenticated');
create policy ref_write  on document_types for all using (fn_has_role('SUPER_ADMIN')) with check (fn_has_role('SUPER_ADMIN'));

create policy ref_select on scholarship_types for select using (auth.role() = 'authenticated');
create policy ref_write  on scholarship_types for all using (fn_has_role('SUPER_ADMIN')) with check (fn_has_role('SUPER_ADMIN'));

-- ----------------------------------------------------------------------------
-- 3. PROFILES
-- ----------------------------------------------------------------------------
create policy profiles_select on profiles for select using (
  user_id = auth.uid()
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (
    fn_has_role('RESPONSABLE') and exists (
      select 1 from students s where s.profile_id = profiles.id and fn_can_manage_student(s.id)
    )
  )
);

-- Pas de policy INSERT : la ligne est créée uniquement par le trigger
-- handle_new_user() (SECURITY DEFINER) lors de l'inscription Supabase Auth.

create policy profiles_update on profiles for update using (
  user_id = auth.uid()
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (
    fn_has_role('RESPONSABLE') and exists (
      select 1 from students s where s.profile_id = profiles.id and fn_can_manage_student(s.id)
    )
  )
) with check (
  user_id = auth.uid()
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (
    fn_has_role('RESPONSABLE') and exists (
      select 1 from students s where s.profile_id = profiles.id and fn_can_manage_student(s.id)
    )
  )
);

-- Aucune policy DELETE : la désactivation se fait via profiles.status,
-- jamais par suppression physique (traçabilité, cf. §39).

create or replace function trg_profiles_protect_status()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'DESACTIVE' and new.status = 'ACTIF' and not fn_has_role('SUPER_ADMIN', 'ADMIN') then
    raise exception 'Seul un administrateur peut réactiver un compte désactivé.';
  end if;
  return new;
end;
$$;

create trigger trg_profiles_status_guard
  before update on profiles
  for each row execute function trg_profiles_protect_status();

-- ----------------------------------------------------------------------------
-- 4. STUDENTS
-- ----------------------------------------------------------------------------
create policy students_select on students for select using (
  fn_is_owner_student(id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(id))
);

create policy students_insert on students for insert with check (
  exists (select 1 from profiles p where p.id = students.profile_id and p.user_id = auth.uid())
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
);

create policy students_update on students for update using (
  fn_is_owner_student(id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(id))
) with check (
  fn_is_owner_student(id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(id))
);

-- Aucune policy DELETE.

-- ----------------------------------------------------------------------------
-- 5. ADMIN_ROLES — gestion strictement réservée à SUPER_ADMIN
-- ----------------------------------------------------------------------------
create policy admin_roles_select on admin_roles for select using (
  user_id = auth.uid() or fn_has_role('SUPER_ADMIN')
);
create policy admin_roles_insert on admin_roles for insert with check (fn_has_role('SUPER_ADMIN'));
create policy admin_roles_update on admin_roles for update using (fn_has_role('SUPER_ADMIN')) with check (fn_has_role('SUPER_ADMIN'));
create policy admin_roles_delete on admin_roles for delete using (fn_has_role('SUPER_ADMIN'));

-- ----------------------------------------------------------------------------
-- 6. DOCUMENTS
-- ----------------------------------------------------------------------------
create policy documents_select on documents for select using (
  fn_is_owner_student(student_id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
);

create policy documents_insert on documents for insert with check (
  fn_is_owner_student(student_id)
  and status = 'EN_ATTENTE'
  and verified_by is null
  and verified_at is null
);

-- L'étudiant peut renvoyer un document tant qu'il n'a pas encore été traité ;
-- il ne peut jamais s'auto-valider (status reste EN_ATTENTE/A_RENOUVELER,
-- verified_by/verified_at restent null via cette policy).
create policy documents_update_owner on documents for update using (
  fn_is_owner_student(student_id) and status in ('EN_ATTENTE', 'A_RENOUVELER')
) with check (
  fn_is_owner_student(student_id)
  and status in ('EN_ATTENTE', 'A_RENOUVELER')
  and verified_by is null
  and verified_at is null
);

create policy documents_update_admin on documents for update using (
  fn_has_role('SUPER_ADMIN', 'ADMIN') or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
) with check (
  fn_has_role('SUPER_ADMIN', 'ADMIN') or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
);

-- Aucune policy DELETE : un document rejeté/expiré reste dans l'historique.

-- ----------------------------------------------------------------------------
-- 7. NEWS
-- ----------------------------------------------------------------------------
create policy news_select on news for select using (
  status = 'PUBLIE' or fn_has_role('SUPER_ADMIN', 'ADMIN')
);

create policy news_insert on news for insert with check (
  fn_has_role('SUPER_ADMIN', 'ADMIN') and author_id = auth.uid()
);

create policy news_update on news for update using (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
) with check (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
);

-- Pas de DELETE : utiliser le statut ARCHIVE.

-- ----------------------------------------------------------------------------
-- 8. NOTIFICATIONS — écriture exclusivement via send_notification() / service_role
-- ----------------------------------------------------------------------------
create policy notifications_select on notifications for select using (
  user_id = auth.uid() or fn_has_role('SUPER_ADMIN')
);

create policy notifications_update on notifications for update using (
  user_id = auth.uid()
) with check (
  user_id = auth.uid()
);

create or replace function trg_notifications_protect_fields()
returns trigger
language plpgsql
as $$
begin
  if not fn_has_role('SUPER_ADMIN') then
    if new.title is distinct from old.title
       or new.message is distinct from old.message
       or new.type is distinct from old.type
       or new.user_id is distinct from old.user_id
       or new.reference_id is distinct from old.reference_id then
      raise exception 'Seul le statut de lecture (is_read) peut être modifié.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_notifications_field_guard
  before update on notifications
  for each row execute function trg_notifications_protect_fields();

-- Aucune policy INSERT/DELETE pour authenticated : la création passe par
-- send_notification() (voir ci-dessous) appelée depuis des triggers/Edge
-- Functions de confiance, jamais directement depuis le client.
create or replace function send_notification(
  p_user_id uuid,
  p_title text,
  p_message text,
  p_type notification_type,
  p_reference_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into notifications (user_id, title, message, type, reference_id)
  values (p_user_id, p_title, p_message, p_type, p_reference_id)
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function send_notification(uuid, text, text, notification_type, uuid) from public;
grant execute on function send_notification(uuid, text, text, notification_type, uuid) to service_role;

-- ----------------------------------------------------------------------------
-- 9. DEVICE_TOKENS — strictement privé à son propriétaire
-- ----------------------------------------------------------------------------
create policy device_tokens_all on device_tokens for all using (
  user_id = auth.uid()
) with check (
  user_id = auth.uid()
);

-- ----------------------------------------------------------------------------
-- 10. ASSISTANCE_REQUESTS
-- ----------------------------------------------------------------------------
create policy assistance_select on assistance_requests for select using (
  fn_is_owner_student(student_id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
);

create policy assistance_insert on assistance_requests for insert with check (
  fn_is_owner_student(student_id)
  and status = 'NOUVELLE'
  and assigned_to is null
  and answered_at is null
  and closed_at is null
);

create policy assistance_update_admin on assistance_requests for update using (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
) with check (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
);

-- ----------------------------------------------------------------------------
-- 11. EMERGENCY_REQUESTS
-- ----------------------------------------------------------------------------
create policy emergency_select on emergency_requests for select using (
  fn_is_owner_student(student_id)
  or fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
);

create policy emergency_insert on emergency_requests for insert with check (
  fn_is_owner_student(student_id)
  and status = 'NOUVELLE'
  and assigned_to is null
  and accepted_at is null
  and resolved_at is null
  and closed_at is null
);

-- L'étudiant NE PEUT PAS modifier sa demande après envoi : seule l'ADM traite
-- le workflow (statuts, assignation, dates de prise en charge/clôture).
create policy emergency_update_admin on emergency_requests for update using (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
) with check (
  fn_has_role('SUPER_ADMIN', 'ADMIN')
  or (fn_has_role('RESPONSABLE') and fn_can_manage_student(student_id))
  or assigned_to = auth.uid()
);

-- ----------------------------------------------------------------------------
-- 12. EMERGENCY_LOCATIONS — accès le plus restrictif du schéma (§19-20)
-- ----------------------------------------------------------------------------
create policy emergency_locations_select on emergency_locations for select using (
  exists (
    select 1 from emergency_requests er
    where er.id = emergency_locations.emergency_id
      and (
        fn_is_owner_student(er.student_id)
        or fn_has_role('SUPER_ADMIN', 'ADMIN')
        or (fn_has_role('RESPONSABLE') and fn_can_manage_student(er.student_id))
        or er.assigned_to = auth.uid()
      )
  )
);

create policy emergency_locations_insert on emergency_locations for insert with check (
  exists (
    select 1 from emergency_requests er
    where er.id = emergency_locations.emergency_id
      and fn_is_owner_student(er.student_id)
  )
);

-- Aucune policy UPDATE/DELETE : un partage de position est un instantané
-- immuable ; un nouveau partage crée une nouvelle ligne.

-- ----------------------------------------------------------------------------
-- 13. AUDIT_LOGS — lecture SUPER_ADMIN uniquement, écriture système only
-- ----------------------------------------------------------------------------
create policy audit_logs_select on audit_logs for select using (
  fn_has_role('SUPER_ADMIN')
);

-- Aucune policy INSERT/UPDATE/DELETE pour authenticated : passage obligatoire
-- par log_audit_action() (SECURITY DEFINER, définie dans schema.sql) ou par
-- le service_role depuis une Edge Function.
revoke execute on function log_audit_action(uuid, text, text, uuid, jsonb) from public;
grant execute on function log_audit_action(uuid, text, text, uuid, jsonb) to authenticated, service_role;
-- Note : authenticated garde l'exécution de log_audit_action() car certaines
-- actions à journaliser (ex. consultation d'un dossier sensible) sont
-- déclenchées par des admins authentifiés côté dashboard ; la fonction ne
-- fait qu'insérer un log et ne permet aucune autre écriture.

-- ----------------------------------------------------------------------------
-- 14. APP_SETTINGS
-- ----------------------------------------------------------------------------
create policy app_settings_select on app_settings for select using (
  auth.role() = 'authenticated'
);
create policy app_settings_write on app_settings for all using (
  fn_has_role('SUPER_ADMIN')
) with check (
  fn_has_role('SUPER_ADMIN')
);

-- ============================================================================
-- Fin de rls_policies.sql
-- ============================================================================
