# ADM — Supabase Storage (Phase 1, étape 6)

Complète `storage_policies.sql`. Documente la convention de chemin et le flux d'upload que devra suivre le code Flutter/Next.js écrit en Phase 2+ — rien de fonctionnel n'est implémenté à ce stade.

## Buckets créés

| Bucket | Public | Contenu | Taille max | Types autorisés |
|---|---|---|---|---|
| `student-documents` | **Non** | Documents étudiants (carte de séjour, passeport, etc.) | 10 Mo | PDF, JPEG, PNG, HEIC, WEBP |
| `profile-photos` | Non | Photos de profil (étudiants et membres ADM) | 5 Mo | JPEG, PNG, WEBP |
| `news-images` | Non | Images d'actualités | 5 Mo | JPEG, PNG, WEBP |

Aucun des trois n'est un bucket "public" Supabase (qui exposerait une URL fixe sans aucune vérification). `news-images` est lisible par tout utilisateur **authentifié** (pas anonyme), par cohérence avec le reste du schéma où rien n'est exposé à `anon`.

## Convention de chemin

```
student-documents/{student_id}/{uuid}.{ext}     student_id = students.id (PAS auth.users.id)
profile-photos/{user_id}/{uuid}.{ext}            user_id = auth.users.id
news-images/{news_id}/{uuid}.{ext}               news_id = news.id
```

Le premier segment du chemin encode le propriétaire. Les politiques RLS le relisent via `storage.foldername(name)[1]` et réutilisent **exactement** les fonctions `fn_is_owner_student()` / `fn_can_manage_student()` déjà auditées et testées à l'étape 1 pour la table `documents` — aucune nouvelle règle d'autorisation n'a été inventée pour le Storage.

⚠️ `student_id` (l'identifiant de la ligne `students`), pas `auth.uid()` — car c'est ce que `fn_is_owner_student()` / `fn_can_manage_student()` attendent. Le mobile doit donc connaître son propre `students.id` (récupérable via `select id from students where profile_id = ...` — autorisé par `students_select`) avant de construire le chemin d'upload.

## Flux d'upload (à implémenter en Phase 2, `documents/data/`)

1. L'app récupère le `students.id` de l'utilisateur courant.
2. Elle génère un UUID côté client pour le nom de fichier (ex. `uuid_v4()` du package `uuid`).
3. Elle uploade vers `student-documents/{student_id}/{uuid}.{ext}` via `supabase.storage.from('student-documents').upload(path, file)`.
4. **Seulement après succès de l'upload**, elle insère la ligne `documents` avec `file_path` = ce chemin exact.

Ordre important : si l'insertion de la ligne `documents` échouait après un upload réussi, le fichier resterait orphelin (accessible par son seul propriétaire, sans impact de sécurité, juste un fichier à nettoyer plus tard) — l'inverse (ligne `documents` sans fichier) serait pire (référence cassée). D'où l'ordre upload → insert.

**Remplacement d'un document** (ex. après un refus) : toujours un **nouvel** upload avec un nouvel UUID, jamais un écrasement du fichier existant (`student-documents` n'a pas de politique UPDATE — voir justification dans `storage_policies.sql` §2.3). L'app met ensuite à jour `documents.file_path` vers le nouveau chemin.

## Téléchargement / affichage — URLs signées

Les buckets étant privés, il n'existe pas d'URL publique permanente. Pour afficher ou télécharger un fichier :

```dart
final signedUrl = await supabase.storage
    .from('student-documents')
    .createSignedUrl(path, 120); // 120 secondes
```

`createSignedUrl` est lui-même soumis à la politique RLS `SELECT` sur `storage.objects` : un utilisateur qui n'a pas le droit de lire l'objet obtient une erreur, pas une URL signée qui ne fonctionnerait pas — la vérification a lieu **avant** l'émission du lien.

Recommandation : générer l'URL signée **au moment de l'affichage**, avec une durée courte (60–300 s selon l'usage — aperçu vs téléchargement), jamais en amont ni mise en cache/stockée. Ceci répond directement au §37 du cahier des charges ("URLs signées avec une durée limitée").

## Ce qui reste volontairement absent à ce stade

- Aucune Edge Function de suppression coordonnée (Storage + ligne `documents`) — prévue en Phase 4/5 pour les demandes de suppression RGPD (§39).
- Aucun nettoyage automatique des fichiers orphelins — à envisager en Phase 6 (qualité) si nécessaire.
- Aucun code Flutter/Next.js n'a été écrit (`storage_service.dart` viendra en Phase 2, conformément à l'arborescence définie en Mission 1).
