-- ============================================================================
-- ADM — Données de départ (seed)
-- À exécuter APRÈS schema.sql et rls_policies.sql, avec un rôle privilégié
-- (postgres / service_role), car app_settings, document_types et
-- scholarship_types sont en écriture SUPER_ADMIN uniquement.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Villes marocaines courantes (liste de départ, à compléter depuis le dashboard)
-- ----------------------------------------------------------------------------
insert into cities (name, country) values
  ('Rabat', 'Maroc'),
  ('Casablanca', 'Maroc'),
  ('Fès', 'Maroc'),
  ('Marrakech', 'Maroc'),
  ('Tanger', 'Maroc'),
  ('Agadir', 'Maroc'),
  ('Oujda', 'Maroc'),
  ('Meknès', 'Maroc')
on conflict (name, country) do nothing;

-- ----------------------------------------------------------------------------
-- Types de documents (§9)
-- ----------------------------------------------------------------------------
insert into document_types (name, description, requires_expiry_date, is_required, sort_order) values
  ('Carte de séjour',            'Titre de séjour marocain en cours de validité', true,  true,  1),
  ('Attestation d''inscription', 'Attestation d''inscription à l''établissement pour l''année en cours', true,  true,  2),
  ('Attestation de résidence',   'Justificatif de domicile',                       false, false, 3),
  ('Passeport',                  'Passeport djiboutien en cours de validité',      true,  true,  4),
  ('Autre document',             'Tout autre document utile transmis à l''ADM',    false, false, 5)
on conflict (name) do nothing;

-- ----------------------------------------------------------------------------
-- Types de bourse (exemples — à ajuster avec l'ADM)
-- ----------------------------------------------------------------------------
insert into scholarship_types (name, description) values
  ('Bourse d''État djiboutienne', 'Bourse accordée par le gouvernement de Djibouti'),
  ('Bourse d''excellence',        'Bourse au mérite académique'),
  ('Autre bourse',                'Bourse accordée par un autre organisme')
on conflict (name) do nothing;

-- ----------------------------------------------------------------------------
-- app_settings : seuils, listes modifiables, textes légaux (§10, §17, §21)
-- ----------------------------------------------------------------------------
insert into app_settings (key, value, description) values
  (
    'document_expiry_thresholds',
    '{"valide": 90, "a_surveiller": 30, "expiration_prochaine": 7}',
    'Seuils (en jours restants) utilisés par get_document_alert_level() pour classer les documents.'
  ),
  (
    'institution_types',
    '["public", "privé", "autre"]',
    'Valeurs autorisées pour students.institution_type, éditables sans mise à jour de l''application.'
  ),
  (
    'academic_levels',
    '["Licence 1", "Licence 2", "Licence 3", "Master 1", "Master 2", "Doctorat", "Autre"]',
    'Suggestions de niveaux académiques affichées dans le formulaire étudiant.'
  ),
  (
    'emergency_categories',
    '["Problème médical", "Accident", "Problème administratif", "Perte ou vol", "Problème lié au logement", "Problème avec les autorités", "Autre"]',
    'Catégories proposées lors d''une demande d''urgence (§17).'
  ),
  (
    'news_categories',
    '["Annonce", "Communiqué", "Événement", "Information académique", "Information administrative", "Culture", "Urgent", "Autre"]',
    'Catégories d''actualités (§13).'
  ),
  (
    'emergency_disclaimer_fr',
    '"En cas de danger immédiat ou d''urgence nécessitant une intervention des services publics, contactez directement les services d''urgence compétents. L''application ADM constitue un canal d''assistance et de contact avec l''association, et non un service d''urgence officiel."',
    'Texte affiché avant toute confirmation d''envoi d''une demande d''urgence (§21).'
  )
on conflict (key) do nothing;

-- ============================================================================
-- Fin de seed_data.sql
-- ============================================================================
