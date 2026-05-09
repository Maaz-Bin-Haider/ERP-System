# Module: `authentication`

> **Role:** Standard Django authentication and session management. Provides users, groups, permissions, content types, admin activity logging, and session storage. All custom tables in Financee reference `auth_user` for `created_by` audit fields.

---

## Folder Structure

```
authentication/
├── indexes/          ← 13 index definitions for auth tables
└── tables/           ← 10 Django-standard tables
    ├── auth_group.sql
    ├── auth_group_permissions.sql
    ├── auth_permission.sql
    ├── auth_user.sql
    ├── auth_user_groups.sql
    ├── auth_user_user_permissions.sql
    ├── django_admin_log.sql
    ├── django_content_type.sql
    ├── django_migrations.sql
    └── django_session.sql
```

---

## Tables

### `auth_user`

The core user account table — every Financee user has a row here.

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer PK | Identity sequence |
| `username` | varchar(150) UNIQUE | Login name |
| `password` | varchar(128) | Hashed password (Django PBKDF2) |
| `email` | varchar(254) | User email address |
| `first_name` | varchar(150) | First name |
| `last_name` | varchar(150) | Last name |
| `is_superuser` | boolean | Superuser bypass for all permissions |
| `is_staff` | boolean | Can access Django admin |
| `is_active` | boolean | Soft-disable accounts without deletion |
| `last_login` | timestamptz | Last login timestamp |
| `date_joined` | timestamptz | Account creation timestamp |

**Usage across the database:** Every operational table (`items`, `parties`, `payments`, `receipts`, `purchaseinvoices`, `salesinvoices`, etc.) has a `created_by integer` column that is a foreign key to `auth_user.id` (ON DELETE SET NULL). This provides an audit trail of who created each record.

---

### `auth_group`

Named groups of users (e.g. "Admins", "Cashiers").

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer PK | Identity sequence |
| `name` | varchar(150) UNIQUE | Group name |

---

### `auth_permission`

Individual permissions defined per Django model action (add, change, delete, view).

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer PK | Identity sequence |
| `name` | varchar(255) | Human-readable description |
| `content_type_id` | integer FK → django_content_type | Which model this permission applies to |
| `codename` | varchar(100) | Machine-readable code (e.g. `add_item`) |

Unique constraint on `(content_type_id, codename)`.

---

### `auth_group_permissions` (Junction)

Many-to-many: Groups ↔ Permissions.

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | Identity sequence |
| `group_id` | integer FK → auth_group | |
| `permission_id` | integer FK → auth_permission | |

Unique constraint on `(group_id, permission_id)`.

---

### `auth_user_groups` (Junction)

Many-to-many: Users ↔ Groups.

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | Identity sequence |
| `user_id` | integer FK → auth_user | |
| `group_id` | integer FK → auth_group | |

Unique constraint on `(user_id, group_id)`.

---

### `auth_user_user_permissions` (Junction)

Many-to-many: Users ↔ direct Permissions (bypasses group assignment).

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | Identity sequence |
| `user_id` | integer FK → auth_user | |
| `permission_id` | integer FK → auth_permission | |

Unique constraint on `(user_id, permission_id)`.

---

### `django_content_type`

Maps each installed Django model to an `(app_label, model)` pair. Used by the permissions system.

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer PK | Identity sequence |
| `app_label` | varchar(100) | Django app name |
| `model` | varchar(100) | Model class name (lowercase) |

---

### `django_admin_log`

Audit log of all actions performed through the Django admin interface.

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer PK | Identity sequence |
| `action_time` | timestamptz | When the action occurred |
| `object_id` | text | PK of the affected object (as string) |
| `object_repr` | varchar(200) | String representation of the object |
| `action_flag` | smallint ≥ 0 | 1=Add, 2=Change, 3=Delete |
| `change_message` | text | JSON description of changes made |
| `content_type_id` | integer FK → django_content_type | Which model was affected |
| `user_id` | integer FK → auth_user | Who performed the action |

---

### `django_migrations`

Tracks which Django database migrations have been applied.

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigint PK | Identity sequence |
| `app` | varchar(255) | Django app name |
| `name` | varchar(255) | Migration filename |
| `applied` | timestamptz | When the migration ran |

---

### `django_session`

Server-side session storage for Django's session framework.

| Column | Type | Notes |
|--------|------|-------|
| `session_key` | varchar(40) PK | Unique session identifier |
| `session_data` | text | Base64-encoded, signed session payload |
| `expire_date` | timestamptz | Session expiry time |

---

## Indexes (13 total)

All indexes are standard Django auto-generated indexes for FK and unique-like columns:

| Index | Table | Column(s) |
|-------|-------|-----------|
| `auth_group_name_a6ea08ec_like` | auth_group | name (varchar_pattern_ops) |
| `auth_group_permissions_group_id_b120cbf9` | auth_group_permissions | group_id |
| `auth_group_permissions_permission_id_84c5c92e` | auth_group_permissions | permission_id |
| `auth_permission_content_type_id_2f476e4b` | auth_permission | content_type_id |
| `auth_user_groups_group_id_97559544` | auth_user_groups | group_id |
| `auth_user_groups_user_id_6a12ed8b` | auth_user_groups | user_id |
| `auth_user_username_6821ab7c_like` | auth_user | username (varchar_pattern_ops) |
| `auth_user_user_permissions_permission_id_1fbb5f2c` | auth_user_user_permissions | permission_id |
| `auth_user_user_permissions_user_id_a95ead1b` | auth_user_user_permissions | user_id |
| `django_admin_log_content_type_id_c4bce8eb` | django_admin_log | content_type_id |
| `django_admin_log_user_id_c564eba6` | django_admin_log | user_id |
| `django_session_expire_date_a5c62663` | django_session | expire_date |
| `django_session_session_key_c0390e0f_like` | django_session | session_key (varchar_pattern_ops) |

---

## Dependencies

- **Used by:** All operational modules reference `auth_user.id` via `created_by` FK
- **Depends on:** None (this is the foundational system module)
