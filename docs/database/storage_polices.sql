-- ============================================================================
-- ADM — Supabase Storage : buckets et politiques d'accès (Phase 1, étape 6)
-- À exécuter APRÈS schema.sql, rls_policies.sql et seed_data.sql (les
-- politiques ci-dessous réutilisent fn_is_owner_student() et
-- fn_can_manage_student(), définies dans rls_policies.sql).
--
-- storage.objects est déjà une table avec RLS ACTIVÉ par défaut sur tout
-- projet Supabase — on n'exécute donc jamais ALTER TABLE dessus, seulement
-- CREATE POLICY. storage.buckets, lui, n'a pas besoin de RLS : la visibilité
-- d'un bucket "public" ou "privé" est gérée par le flag buckets.public et par
-- les politiques sur storage.objects.
--
-- Convention de chemin (cœur du modèle de sécurité) :
--   student-documents/{student_id}/{uuid}.{ext}   ← student_id = students.id
--   profile-photos/{user_id}/{uuid}.{ext}          ← user_id = auth.users.id
--   news-images/{news_id}/{uuid}.{ext}             ← news_id = news.id (pas de
--                                                     contrôle par propriétaire,
--                                                     seul le rôle compte)
--
-- Le premier segment du chemin (storage.foldername(name)[1]) permet à chaque
-- politique de retrouver le propriétaire SANS dépendre de l'existence d'une
-- ligne dans documents/profiles à l'instant de l'upload (utile : au moment où
-- le fichier est envoyé, la ligne documents correspondante n'existe pas
-- encore — c'est l'app qui doit créer le chemin AVANT d'insérer la ligne,
-- puis insérer documents.file_path = ce même chemin).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. BUCKETS
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'student-documents', 'student-documents', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-photos', 'profile-photos', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'news-images', 'news-images', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Les TROIS buckets sont privés (public = false). "news-images" n'est pas un
-- bucket "public" Supabase (qui exposerait une URL fixe sans aucune
-- vérification) : la lecture y est ouverte à tout utilisateur AUTHENTIFIÉ via
-- une politique RLS (§2.3), jamais à un visiteur anonyme, par cohérence avec
-- le reste du schéma (aucune donnée n'est exposée à anon).

-- ============================================================================
-- 2. POLITIQUES — bucket "student-documents" (le plus sensible)
-- ============================================================================

-- 2.1 Lecture : le propriétaire, ou un admin/responsable autorisé sur CE
-- student précis. Réutilise exactement la même logique que la table
-- documents (fn_is_owner_student / fn_can_manage_student), déjà auditée et
-- testée à l'étape 1 — aucune nouvelle règle métier n'est introduite ici.
create policy "student_documents_select" on storage.objects for select using (
  bucket_id = 'student-documents'
  and (
    fn_is_owner_student(((storage.foldername(name))[1])::uuid)
    or fn_has_role('SUPER_ADMIN', 'ADMIN')
    or (fn_has_role('RESPONSABLE') and fn_can_manage_student(((storage.foldername(name))[1])::uuid))
  )
);

-- 2.2 Écriture (upload) : le propriétaire UNIQUEMENT — aligné sur la
-- politique documents_insert (rls_policies.sql), qui n'autorise elle non
-- plus que l'étudiant propriétaire à créer sa propre ligne documents. Un
-- admin ne peut pas déposer un fichier "au nom" d'un étudiant tant que
-- documents_insert n'évolue pas dans le même sens (décision à prendre
-- séparément si ce besoin apparaît).
create policy "student_documents_insert" on storage.objects for insert with check (
  bucket_id = 'student-documents'
  and fn_is_owner_student(((storage.foldername(name))[1])::uuid)
);

-- 2.3 Pas de politique UPDATE. Remplacer un document = uploader un NOUVEAU
-- fichier (nouveau chemin avec un nouvel uuid) puis mettre à jour
-- documents.file_path en conséquence. Ce choix évite qu'un fichier déjà
-- référencé par une ligne documents (potentiellement déjà vérifiée) puisse
-- être remplacé silencieusement à son insu — cohérent avec le fait que
-- documents_update_owner (rls_policies.sql) n'autorise déjà la modification
-- que tant que status ∈ (EN_ATTENTE, A_RENOUVELER).

-- 2.4 Suppression : SUPER_ADMIN uniquement (aucune suppression pour
-- ETUDIANT/ADMIN/RESPONSABLE, cohérent avec l'absence totale de politique
-- DELETE sur la table documents — §61 "ne jamais supprimer automatiquement
-- les documents"). Cette politique couvre une suppression MANUELLE
-- ponctuelle (ex. demande de suppression RGPD, §39) ; en pratique, une telle
-- suppression doit passer par une Edge Function qui supprime À LA FOIS
-- l'objet Storage ET traite la ligne documents correspondante de façon
-- cohérente (jamais l'un sans l'autre) — à mettre en place en Phase 4/5.
create policy "student_documents_delete" on storage.objects for delete using (
  bucket_id = 'student-documents' and fn_has_role('SUPER_ADMIN')
);

-- ============================================================================
-- 3. POLITIQUES — bucket "profile-photos"
-- ============================================================================
-- Moins sensible que les documents (une photo de profil n'est pas une pièce
-- d'identité), donc modèle plus souple : le propriétaire peut aussi
-- remplacer (UPDATE) sa propre photo.

create policy "profile_photos_select" on storage.objects for select using (
  bucket_id = 'profile-photos'
  and (
    ((storage.foldername(name))[1])::uuid = auth.uid()
    or fn_has_role('SUPER_ADMIN', 'ADMIN')
    or (
      fn_has_role('RESPONSABLE') and exists (
        select 1
        from profiles p
        join students s on s.profile_id = p.id
        where p.user_id = ((storage.foldername(name))[1])::uuid
          and fn_can_manage_student(s.id)
      )
    )
  )
);

create policy "profile_photos_insert" on storage.objects for insert with check (
  bucket_id = 'profile-photos' and ((storage.foldername(name))[1])::uuid = auth.uid()
);

create policy "profile_photos_update" on storage.objects for update using (
  bucket_id = 'profile-photos' and ((storage.foldername(name))[1])::uuid = auth.uid()
) with check (
  bucket_id = 'profile-photos' and ((storage.foldername(name))[1])::uuid = auth.uid()
);

create policy "profile_photos_delete" on storage.objects for delete using (
  bucket_id = 'profile-photos'
  and (((storage.foldername(name))[1])::uuid = auth.uid() or fn_has_role('SUPER_ADMIN'))
);

-- ============================================================================
-- 4. POLITIQUES — bucket "news-images"
-- ============================================================================
-- Pas de logique de propriétaire : la lecture est ouverte à tout utilisateur
-- authentifié (une actualité publiée est, par nature, destinée à être vue par
-- tous les étudiants) ; l'écriture reste réservée à SUPER_ADMIN/ADMIN, comme
-- pour la table news elle-même (news_insert / news_update).

create policy "news_images_select" on storage.objects for select using (
  bucket_id = 'news-images' and auth.role() = 'authenticated'
);

create policy "news_images_insert" on storage.objects for insert with check (
  bucket_id = 'news-images' and fn_has_role('SUPER_ADMIN', 'ADMIN')
);

create policy "news_images_update" on storage.objects for update using (
  bucket_id = 'news-images' and fn_has_role('SUPER_ADMIN', 'ADMIN')
) with check (
  bucket_id = 'news-images' and fn_has_role('SUPER_ADMIN', 'ADMIN')
);

create policy "news_images_delete" on storage.objects for delete using (
  bucket_id = 'news-images' and fn_has_role('SUPER_ADMIN', 'ADMIN')
);

-- ============================================================================
-- Fin de storage_policies.sql
-- ============================================================================
