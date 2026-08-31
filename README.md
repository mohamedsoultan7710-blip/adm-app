# ADM — Association Djiboutienne au Maroc

Application mobile (Flutter) + dashboard web (Next.js) + backend Supabase, pour la gestion des étudiants djiboutiens au Maroc par l'ADM.

## État du projet

**Phase 1 — Fondations, en cours.** Voir [`docs/PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) pour l'analyse complète, l'arborescence cible, le plan de développement par phases et les décisions validées.

- [x] Mission 1 : analyse, schéma SQL, RLS, rôles, plan de développement
- [x] Phase 1 / étape 1 : audit et correction de `schema.sql` / `rls_policies.sql` / `seed_data.sql`
- [x] Phase 1 / étape 6 : buckets Storage privés + politiques
- [ ] Phase 1 / étape 7 : migrations Supabase versionnées
- [ ] Phase 1 / étape 8 : initialisation Flutter (`mobile/`)
- [ ] Phase 1 / étape 9 : initialisation Next.js (`dashboard/`)
- [ ] Phase 1 / étapes 10-13 : `.env.example`, authentification, guards, tests RLS

## Structure du dépôt

```
adm-app/
├── docs/
│   ├── PROJECT_PLAN.md        # analyse, arborescence cible, RBAC, plan par phases
│   └── database/               # schéma SQL Supabase (à migrer en supabase/migrations/ à l'étape 7)
│       ├── schema.sql
│       ├── rls_policies.sql
│       ├── seed_data.sql
│       ├── storage_policies.sql
│       └── STORAGE.md
├── env-examples/                # gabarits de variables d'environnement (jamais de vrais secrets)
├── mobile/                      # (à venir — Flutter)
├── dashboard/                   # (à venir — Next.js)
├── supabase/                    # (à venir — migrations versionnées, Edge Functions)
└── .gitignore
```

## Mise en place d'un projet Supabase de développement

Dans l'ordre, sur un projet Supabase vide (SQL Editor du dashboard, ou `psql`) :

```sql
\i docs/database/schema.sql
\i docs/database/rls_policies.sql
\i docs/database/seed_data.sql
\i docs/database/storage_policies.sql
```

⚠️ Ne jamais exécuter ces fichiers sur `production` sans être passé par une revue — voir `docs/PROJECT_PLAN.md` pour le principe des trois environnements (development / staging / production).
