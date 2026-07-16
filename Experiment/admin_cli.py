#!/usr/bin/env python3
"""
GradeVault Admin CLI — manage user credits directly via Supabase.

Run this locally in a terminal. Never paste a Supabase secret key into a
browser page — Supabase blocks secret keys from browser requests by design
(it always returns 401), so a webpage-based admin tool like this can't work.

Setup:
    pip install requests

Credentials — easiest option is a local .env file next to this script,
so you only enter them once and they're never typed or exported by hand:

    1. Copy .env.example to .env in this same folder
    2. Fill in SUPABASE_URL and SUPABASE_SECRET_KEY
    3. Add .env to .gitignore — never commit it, it's a secret key

(.env is auto-loaded below — no extra packages needed. Environment
variables, if already set in your shell, still take priority over .env.)

Run:
    python admin_cli.py
"""

import json
import mimetypes
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("Missing dependency. Install it with: pip install requests")


def load_env_file():
    """Load KEY=VALUE pairs from a .env file next to this script, if present.
    Never overrides variables already set in the real environment."""
    env_path = Path(__file__).resolve().parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def get_credentials():
    load_env_file()
    url = os.environ.get("SUPABASE_URL") or input("Supabase Project URL: ").strip()
    key = os.environ.get("SUPABASE_SECRET_KEY") or input("Secret Key (sb_secret_...): ").strip()
    if not url or not key:
        sys.exit("Missing credentials. Set them in .env or as environment variables.")
    return url.rstrip("/"), key


def headers(key):
    return {
        "Content-Type": "application/json",
        "apikey": key,
        "Authorization": f"Bearer {key}",
    }


def fetch_users(url, key):
    resp = requests.get(f"{url}/auth/v1/admin/users?per_page=1000", headers=headers(key))
    resp.raise_for_status()
    return resp.json().get("users", [])


def fetch_credits(url, key):
    resp = requests.get(f"{url}/rest/v1/credits?select=id,balance", headers=headers(key))
    resp.raise_for_status()
    return {row["id"]: row["balance"] for row in resp.json()}


def fetch_gpa_roles(url, key):
    """Return {user_id: {role, verified, username}} from gpa_data."""
    resp = requests.get(
        f"{url}/rest/v1/gpa_data?select=id,username,role,verified",
        headers=headers(key),
    )
    resp.raise_for_status()
    return {row["id"]: row for row in resp.json()}


def set_verified(url, key, user_id, status: bool):
    """Set gpa_data.verified for one user. Returns the updated row."""
    resp = requests.patch(
        f"{url}/rest/v1/gpa_data?id=eq.{user_id}",
        headers={**headers(key), "Prefer": "return=representation"},
        json={"verified": status},
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else None


VALID_ROLES = ("student", "contributor", "admin")


def set_role(url, key, user_id, role: str):
    """Set gpa_data.role for one user. Returns the updated row."""
    if role not in VALID_ROLES:
        raise ValueError(f"Invalid role '{role}'. Must be one of: {', '.join(VALID_ROLES)}")
    resp = requests.patch(
        f"{url}/rest/v1/gpa_data?id=eq.{user_id}",
        headers={**headers(key), "Prefer": "return=representation"},
        json={"role": role},
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else None


CREDIT_LABELS = {
    "t": ("admin_topup", "Top-up"),
    "top": ("admin_topup", "Top-up"),
    "topup": ("admin_topup", "Top-up"),
    "b": ("admin_bonus", "Bonus"),
    "bonus": ("admin_bonus", "Bonus"),
    "s": ("signup_bonus", "Signup Bonus"),
    "signup": ("signup_bonus", "Signup Bonus"),
}


# ── Pending-grant journal ────────────────────────────────
#
# grant_credits is idempotent server-side on reference_id (schema24.sql),
# but that only helps if a retry actually reuses the same reference_id.
# A ref_id held only in a local variable dies with the process. This
# journal writes intent to disk BEFORE the network call, so a crash or
# killed terminal mid-request leaves a record the operator can resume
# (safe — same reference_id, server dedupes) or discard (after manually
# confirming the grant never landed).

JOURNAL_PATH = Path(__file__).resolve().parent / ".pending_grants.json"


def _read_journal():
    if not JOURNAL_PATH.exists():
        return []
    try:
        with open(JOURNAL_PATH, "r") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        # Corrupt journal shouldn't block the CLI from starting. Surface
        # it, don't silently discard — copy it aside for manual inspection.
        backup = JOURNAL_PATH.with_suffix(".json.corrupt")
        try:
            JOURNAL_PATH.replace(backup)
            print(f"Warning: pending-grant journal was unreadable; moved to {backup}")
        except OSError:
            print(f"Warning: pending-grant journal at {JOURNAL_PATH} is unreadable and could not be moved.")
        return []


def _write_journal(entries):
    if not entries:
        if JOURNAL_PATH.exists():
            JOURNAL_PATH.unlink()
        return
    with open(JOURNAL_PATH, "w") as f:
        json.dump(entries, f, indent=2)


def journal_add_pending(ref_id, user_id, user_email, amount, reason):
    entries = _read_journal()
    entries.append({
        "reference_id": ref_id,
        "user_id": user_id,
        "user_email": user_email,
        "amount": amount,
        "reason": reason,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })
    _write_journal(entries)


def journal_clear_entry(ref_id):
    entries = [e for e in _read_journal() if e.get("reference_id") != ref_id]
    _write_journal(entries)


def check_pending_journal(url, key):
    """Run at startup. Any entry present means a prior grant call was
    attempted but never confirmed cleared. Force explicit resolution
    before letting the operator do anything else."""
    entries = _read_journal()
    if not entries:
        return

    print(f"\n{len(entries)} pending grant(s) from a previous session were not confirmed complete:")
    for e in entries:
        print(
            f"  ref={e.get('reference_id')}  user={e.get('user_email', e.get('user_id'))}  "
            f"amount={e.get('amount')}  reason={e.get('reason')}  at={e.get('timestamp')}"
        )

    for e in list(entries):
        ref_id = e.get("reference_id")
        print(f"\nPending: {e.get('user_email', e.get('user_id'))} — {e.get('amount')}C ({e.get('reason')})")
        choice = input("  [r]esume (retry, safe — server dedupes on reference_id), "
                        "[d]iscard (I confirmed manually it never landed), "
                        "[l]eave (decide later): ").strip().lower()
        if choice in ("r", "resume"):
            try:
                new_balance = grant_credits(url, key, e["user_id"], e["amount"], e["reason"], ref_id)
            except requests.HTTPError as err:
                print(f"  Resume failed: {err}. Left in journal — try again next run.")
                continue
            print(f"  Resumed. New balance: {new_balance}C")
            journal_clear_entry(ref_id)
        elif choice in ("d", "discard"):
            journal_clear_entry(ref_id)
            print("  Discarded from journal.")
        else:
            print("  Left pending. Will prompt again next run.")


def grant_credits(url, key, user_id, amount, reason, reference_id=None):
    """Credit a user via the grant_credits RPC. Logs a ledger row and,
    for admin_topup/admin_bonus, fires a matching notification.
    reference_id makes the call idempotent: pass the same UUID on a retry
    of the same logical grant to avoid double-granting.
    Returns the new balance."""
    resp = requests.post(
        f"{url}/rest/v1/rpc/grant_credits",
        headers=headers(key),
        json={
            "p_user_id": user_id,
            "p_amount": amount,
            "p_reason": reason,
            "p_reference_id": reference_id,
        },
    )
    resp.raise_for_status()
    return resp.json()


# ── Avatar gallery ───────────────────────────────────────────

AVATAR_BUCKET = "avatars"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "avatar"


def fetch_avatars(url, key):
    resp = requests.get(
        f"{url}/rest/v1/avatars?select=id,path,url,created_at&order=created_at",
        headers=headers(key),
    )
    resp.raise_for_status()
    return resp.json()


def upload_avatar_file(url, key, key_secret, local_path):
    """Upload one image file to the avatars storage bucket and register it
    in the avatars table. Returns the new avatar row (id, path, url)."""
    local_path = Path(local_path)
    ext = local_path.suffix.lower()
    if ext not in IMAGE_EXTS:
        raise ValueError(f"Unsupported file type: {ext}")

    avatar_id = uuid.uuid4().hex[:10]
    storage_path = f"{avatar_id}{ext}"
    mime_type = mimetypes.guess_type(str(local_path))[0] or "application/octet-stream"

    with open(local_path, "rb") as f:
        file_bytes = f.read()

    resp = requests.post(
        f"{url}/storage/v1/object/{AVATAR_BUCKET}/{storage_path}",
        headers={
            "apikey": key_secret,
            "Authorization": f"Bearer {key_secret}",
            "Content-Type": mime_type,
            "x-upsert": "true",
        },
        data=file_bytes,
    )
    resp.raise_for_status()

    public_url = f"{url}/storage/v1/object/public/{AVATAR_BUCKET}/{storage_path}"

    resp = requests.post(
        f"{url}/rest/v1/avatars",
        headers={**headers(key_secret), "Prefer": "return=representation"},
        json={"id": avatar_id, "path": storage_path, "url": public_url},
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else {"id": avatar_id, "path": storage_path, "url": public_url}


def upload_avatar_folder(url, key, folder_path):
    folder = Path(folder_path).expanduser()
    if not folder.is_dir():
        raise ValueError(f"Not a folder: {folder}")
    files = sorted(p for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTS)
    if not files:
        raise ValueError("No image files (.jpg/.jpeg/.png/.webp/.gif) found in that folder.")

    uploaded, failed = [], []
    for f in files:
        try:
            row = upload_avatar_file(url, key, key, f)
            uploaded.append((f.name, row["id"]))
            print(f"  ✔ {f.name} → id {row['id']}")
        except requests.HTTPError as e:
            failed.append((f.name, str(e)))
            print(f"  ✘ {f.name} failed: {e}")
        except Exception as e:
            failed.append((f.name, str(e)))
            print(f"  ✘ {f.name} failed: {e}")
    return uploaded, failed


def delete_avatar(url, key, avatar_id, storage_path):
    # Remove the file from storage first.
    resp = requests.post(
        f"{url}/storage/v1/object/remove",
        headers=headers(key),
        json={"prefixes": [storage_path]},
    )
    resp.raise_for_status()
    # Then remove the table row. (If another user still references this
    # avatar_id via gpa_data.avatar_id, the FK will block this — that's
    # intentional, it stops you from deleting an avatar someone has picked.)
    resp = requests.delete(f"{url}/rest/v1/avatars?id=eq.{avatar_id}", headers=headers(key))
    resp.raise_for_status()


def print_avatars(avatars):
    if not avatars:
        print("No avatars uploaded yet.")
        return
    print(f"\n{'#':<4}{'ID':<14}{'Path':<24}{'URL'}")
    print("-" * 100)
    for i, a in enumerate(avatars):
        print(f"{i:<4}{a['id']:<14}{a['path']:<24}{a['url']}")


# ── News cover images ────────────────────────────────────────
# Separate from avatars: own bucket, own table, no FK from gpa_data —
# these are referenced only by posts.image_url (a plain text URL, not a
# foreign key), so deleting one never blocks on "a user still has it
# selected" the way avatar deletes can.

NEWS_IMAGE_BUCKET = "news-images"


def fetch_news_images(url, key):
    resp = requests.get(
        f"{url}/rest/v1/news_images?select=id,path,url,created_at&order=created_at",
        headers=headers(key),
    )
    resp.raise_for_status()
    return resp.json()


def upload_news_image_file(url, key, key_secret, local_path):
    """Upload one image file to the news-images storage bucket and register
    it in the news_images table. Returns the new row (id, path, url)."""
    local_path = Path(local_path)
    ext = local_path.suffix.lower()
    if ext not in IMAGE_EXTS:
        raise ValueError(f"Unsupported file type: {ext}")

    image_id = uuid.uuid4().hex[:10]
    storage_path = f"{image_id}{ext}"
    mime_type = mimetypes.guess_type(str(local_path))[0] or "application/octet-stream"

    with open(local_path, "rb") as f:
        file_bytes = f.read()

    resp = requests.post(
        f"{url}/storage/v1/object/{NEWS_IMAGE_BUCKET}/{storage_path}",
        headers={
            "apikey": key_secret,
            "Authorization": f"Bearer {key_secret}",
            "Content-Type": mime_type,
            "x-upsert": "true",
        },
        data=file_bytes,
    )
    resp.raise_for_status()

    public_url = f"{url}/storage/v1/object/public/{NEWS_IMAGE_BUCKET}/{storage_path}"

    resp = requests.post(
        f"{url}/rest/v1/news_images",
        headers={**headers(key_secret), "Prefer": "return=representation"},
        json={"id": image_id, "path": storage_path, "url": public_url},
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else {"id": image_id, "path": storage_path, "url": public_url}


def delete_news_image(url, key, image_id, storage_path):
    resp = requests.post(
        f"{url}/storage/v1/object/remove",
        headers=headers(key),
        json={"prefixes": [storage_path]},
    )
    resp.raise_for_status()
    resp = requests.delete(f"{url}/rest/v1/news_images?id=eq.{image_id}", headers=headers(key))
    resp.raise_for_status()


def print_news_images(images):
    if not images:
        print("No news cover images uploaded yet.")
        return
    print(f"\n{'#':<4}{'ID':<14}{'Path':<24}{'URL'}")
    print("-" * 100)
    for i, img in enumerate(images):
        print(f"{i:<4}{img['id']:<14}{img['path']:<24}{img['url']}")


# ── Course catalogs (Department × Year × Semester × Level) ─────
#
# These are admin-built course lists that students pull into the app's
# "Upload courses" picker — no per-student PIN involved. The local
# course_builder.py GUI produces the JSON file this flow reads; this flow
# is what actually uploads it to Supabase, scoped to one exact slot.

DEPARTMENTS = [
    "Agricultural and Bioresources Engineering", "Agricultural Economics",
    "Agricultural Extension", "Animal Science and Technology", "Architecture",
    "Biochemistry", "Biology", "Biomedical Engineering", "Biotechnology",
    "Building Technology", "Chemical Engineering", "Chemistry",
    "Civil Engineering", "Computer Engineering", "Computer Science",
    "Crop Science and Technology", "Cyber Security", "Dental Technology",
    "Electrical and Electronic Engineering", "Electrical Engineering",
    "Electronics Engineering", "Entrepreneurship and Innovation",
    "Environmental Health Science", "Environmental Management",
    "Environmental Management and Evaluation",
    "Estate Management and Valuation",
    "Fisheries and Aquaculture Technology", "Food Science and Technology",
    "Forensic Science", "Forestry and Wildlife Technology", "Geology",
    "Human Anatomy", "Human Physiology", "Information Technology",
    "Logistics and Transport Technology", "Maritime Technology and Logistics",
    "Materials and Metallurgical Engineering", "Mathematics",
    "Mechanical Engineering", "Mechatronics Engineering", "Microbiology",
    "Optometry", "Petroleum Engineering", "Physics",
    "Polymer and Textile Engineering", "Project Management Technology",
    "Prosthetics and Orthotics", "Public Health Technology",
    "Quantity Surveying", "Radiography", "Science Laboratory Technology",
    "Soil Science and Technology", "Software Engineering", "Statistics",
    "Supply Chain Management", "Surveying and Geoinformatics",
    "Telecommunications Engineering", "Urban and Regional Planning",
]
CATALOG_YEARS = list(range(2020, 2027))
CATALOG_SEMESTERS = ["1st", "2nd"]
CATALOG_LEVELS = [1, 2, 3, 4, 5]

CANCEL = object()  # sentinel returned by choosers when the user backs out


def choose(options, label, default=None):
    """Numbered single-pick menu. Blank input accepts `default` if given.
    'b' cancels (returns CANCEL sentinel)."""
    print(f"\n{label}")
    for i, opt in enumerate(options):
        tag = "  (default)" if opt == default else ""
        print(f"  {i:<3} {opt}{tag}")
    while True:
        raw = input("> ").strip().lower()
        if raw in ("b", "back"):
            return CANCEL
        if raw == "" and default is not None:
            return default
        if raw.isdigit() and int(raw) < len(options):
            return options[int(raw)]
        print("Invalid choice. Enter a number from the list, or 'b' to cancel.")


def choose_department(default=None):
    """Department picker with type-to-filter, since the full list is long."""
    pool = DEPARTMENTS
    while True:
        print(f"\nDepartment{f'  (default: {default})' if default else ''}")
        for i, d in enumerate(pool):
            print(f"  {i:<3} {d}")
        print("Type a number to pick, part of a name to filter, blank to accept the default, or 'b' to cancel.")
        raw = input("> ").strip()
        if raw.lower() in ("b", "back"):
            return CANCEL
        if raw == "" and default is not None:
            return default
        if raw.isdigit() and int(raw) < len(pool):
            return pool[int(raw)]
        filtered = [d for d in DEPARTMENTS if raw.lower() in d.lower()]
        if not filtered:
            print("No departments match that. Try again.")
            pool = DEPARTMENTS
            continue
        pool = filtered


def load_catalog_json(path):
    """Read and sanity-check a JSON file produced by course_builder.py.
    Returns (data_dict, error_message). Only `courses` is required —
    department/year/semester/level in the file are used as suggested
    defaults only; the admin still confirms the real target via the
    Year → Semester → Department → Level menu."""
    p = Path(str(path).strip().strip('"').strip("'")).expanduser()
    if not p.exists():
        return None, f"File not found: {p}"
    try:
        data = json.loads(p.read_text())
    except (json.JSONDecodeError, OSError) as e:
        return None, f"Couldn't read/parse file: {e}"

    courses = data.get("courses")
    if not isinstance(courses, list) or not courses:
        return None, "File has no 'courses' list (or it's empty)."

    cleaned = []
    for i, c in enumerate(courses):
        if not isinstance(c, dict):
            return None, f"courses[{i}] is not an object."
        code = str(c.get("code", "")).strip()
        title = str(c.get("title", "")).strip()
        units = c.get("units", "")
        if not code:
            return None, f"courses[{i}] is missing a code."
        try:
            units = float(units)
        except (TypeError, ValueError):
            return None, f"courses[{i}] ({code}) has a non-numeric units value."
        if units == int(units):
            units = int(units)
        cleaned.append({"code": code, "title": title, "units": units})

    data["courses"] = cleaned
    return data, None


def fetch_course_catalogs(url, key):
    resp = requests.get(
        f"{url}/rest/v1/course_catalogs"
        "?select=id,department,year,semester,level,courses,updated_at"
        "&order=department.asc,year.asc,semester.asc,level.asc",
        headers=headers(key),
    )
    resp.raise_for_status()
    return resp.json()


def upsert_course_catalog(url, key, department, year, semester, level, courses):
    resp = requests.post(
        f"{url}/rest/v1/course_catalogs?on_conflict=department,year,semester,level",
        headers={
            **headers(key),
            "Prefer": "resolution=merge-duplicates,return=representation",
        },
        json={
            "department": department,
            "year": year,
            "semester": semester,
            "level": level,
            "courses": courses,
        },
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0] if rows else None


def delete_course_catalog(url, key, catalog_id):
    resp = requests.delete(f"{url}/rest/v1/course_catalogs?id=eq.{catalog_id}", headers=headers(key))
    resp.raise_for_status()


def print_catalogs(rows):
    if not rows:
        print("No course catalogs uploaded yet.")
        return
    print(f"\n{'#':<4}{'Department':<38}{'Year':<7}{'Sem':<6}{'Lvl':<5}{'Courses':<9}{'Updated'}")
    print("-" * 110)
    for i, r in enumerate(rows):
        n = len(r.get("courses") or [])
        print(f"{i:<4}{r['department']:<38}{r['year']:<7}{r['semester']:<6}{r['level']:<5}{n:<9}{r.get('updated_at','')}")


def pick_catalog_file():
    """Prompt for a catalog JSON file. Accepts a direct file path, OR a
    folder path — in which case it lists the .json files inside so you
    can pick one by number instead of having to type the exact filename.
    Blank input tries ./generated_catalogs in the current directory first."""
    default_dir = Path("generated_catalogs")
    while True:
        hint = f" (blank = {default_dir}/)" if default_dir.is_dir() else ""
        raw = input(f"Path to catalog JSON file or folder, or 'b' to cancel{hint}: ").strip().strip('"').strip("'")

        if raw.lower() in ("b", "back"):
            return None

        if not raw:
            if default_dir.is_dir():
                target = default_dir
            else:
                return None
        else:
            target = Path(raw).expanduser()

        if not target.exists():
            print(f"Not found: {target}")
            continue

        if target.is_file():
            return target

        files = sorted(target.glob("*.json"))
        if not files:
            print(f"No .json files in {target}/")
            continue
        print(f"\nJSON files in {target}/:")
        for i, f in enumerate(files):
            print(f"  {i:<3} {f.name}")
        sel = input("Pick a number, or 'b' to cancel: ").strip().lower()
        if sel in ("b", "back"):
            return None
        if sel.isdigit() and int(sel) < len(files):
            return files[int(sel)]
        print("Invalid choice.")


def catalog_upload_flow(url, key):
    path = pick_catalog_file()
    if path is None:
        print("Cancelled.")
        return
    data, err = load_catalog_json(path)
    if err:
        print(f"Can't use that file: {err}")
        return

    courses = data["courses"]
    print(f"\nLoaded {len(courses)} course(s) from {path}:")
    for c in courses[:5]:
        print(f"  {c['code']:<12} {c['title']:<40} {c['units']}")
    if len(courses) > 5:
        print(f"  … and {len(courses) - 5} more")

    file_year = data.get("year")
    file_sem = data.get("semester")
    file_dept = data.get("department")
    file_level = data.get("level")

    year = choose([str(y) for y in CATALOG_YEARS], "Select year:", default=str(file_year) if file_year else None)
    if year is CANCEL:
        print("Cancelled.")
        return
    year = int(year)

    semester = choose(CATALOG_SEMESTERS, "Select semester:", default=file_sem if file_sem in CATALOG_SEMESTERS else None)
    if semester is CANCEL:
        print("Cancelled.")
        return

    department = choose_department(default=file_dept if file_dept in DEPARTMENTS else None)
    if department is CANCEL:
        print("Cancelled.")
        return

    level_labels = [f"Year {n}" for n in CATALOG_LEVELS]
    default_level_label = f"Year {file_level}" if file_level in CATALOG_LEVELS else None
    level_label = choose(level_labels, "Select level:", default=default_level_label)
    if level_label is CANCEL:
        print("Cancelled.")
        return
    level = int(level_label.split()[-1])

    print(f"\nAbout to upload {len(courses)} course(s) to:")
    print(f"  Department : {department}")
    print(f"  Year       : {year}")
    print(f"  Semester   : {semester}")
    print(f"  Level      : {level_label}")
    print("This will REPLACE any existing catalog already stored for this exact combination.")
    confirm = input("Are you sure? [y/N]: ").strip().lower()
    if confirm != "y":
        print("Cancelled.")
        return

    try:
        row = upsert_course_catalog(url, key, department, year, semester, level, courses)
    except requests.HTTPError as e:
        print(f"Upload failed: {e}")
        return
    print(f"Uploaded. id={row['id'] if row else '?'}  {department} · {year} · {semester} Semester · {level_label} · {len(courses)} courses")


def print_users(users, credits, roles, query=""):
    q = query.lower()
    filtered = [u for u in users if not q or q in (u.get("email") or "").lower()]
    if not filtered:
        print("No matching users.")
        return filtered
    print(f"\n{'#':<4}{'Email':<35}{'Balance':<10}{'Role':<14}{'✓':<4}{'User ID'}")
    print("-" * 100)
    for i, u in enumerate(filtered):
        bal = credits.get(u["id"], 0)
        profile = roles.get(u["id"], {})
        role = profile.get("role") or "student"
        verified = "yes" if profile.get("verified") else ""
        print(f"{i:<4}{(u.get('email') or '(no email)'):<35}{bal:<10}{role:<14}{verified:<4}{u['id']}")
    return filtered


def fetch_pending_reports(url, key):
    """Return pending (unresolved) comment_reports rows, oldest first."""
    resp = requests.get(
        f"{url}/rest/v1/comment_reports"
        "?resolved_at=is.null"
        "&select=id,comment_id,reporter_id,reason,other_text,created_at"
        "&order=comment_id.asc,created_at.asc",
        headers=headers(key),
    )
    resp.raise_for_status()
    return resp.json()


def fetch_comments_by_ids(url, key, comment_ids):
    if not comment_ids:
        return {}
    ids_param = ",".join(comment_ids)
    resp = requests.get(
        f"{url}/rest/v1/comments?id=in.({ids_param})"
        "&select=id,body,author_id,is_deleted,post_id",
        headers=headers(key),
    )
    resp.raise_for_status()
    return {row["id"]: row for row in resp.json()}


def admin_delete_comment(url, key, comment_id):
    resp = requests.post(
        f"{url}/rest/v1/rpc/admin_delete_comment",
        headers=headers(key),
        json={"p_comment_id": comment_id},
    )
    resp.raise_for_status()


def dismiss_comment_reports(url, key, comment_id):
    resp = requests.post(
        f"{url}/rest/v1/rpc/dismiss_comment_reports",
        headers=headers(key),
        json={"p_comment_id": comment_id},
    )
    resp.raise_for_status()


REASON_LABELS = {
    "harassment": "Harassment or bullying",
    "hate_speech": "Hate speech / abusive",
    "spam": "Spam",
    "misinformation": "Misinformation",
    "inappropriate": "Inappropriate content",
    "impersonation": "Impersonation",
    "other": "Other",
}


def group_reports_by_comment(reports):
    """[{comment_id, reason, ...}, ...] -> {comment_id: [report, report, ...]}
    preserving the oldest-first order already applied by the query."""
    grouped = {}
    for r in reports:
        grouped.setdefault(r["comment_id"], []).append(r)
    return grouped


def review_reports_flow(url, key, roles):
    """Interactive queue: one comment at a time, oldest reported first."""
    try:
        reports = fetch_pending_reports(url, key)
    except requests.HTTPError as e:
        print(f"Failed to load reports: {e}")
        return

    if not reports:
        print("No pending reports.")
        return

    grouped = group_reports_by_comment(reports)
    comment_ids = list(grouped.keys())
    try:
        comments = fetch_comments_by_ids(url, key, comment_ids)
    except requests.HTTPError as e:
        print(f"Failed to load reported comments: {e}")
        return

    print(f"\n{len(comment_ids)} comment(s) with pending reports.\n")

    for comment_id in comment_ids:
        comment = comments.get(comment_id)
        comment_reports = grouped[comment_id]

        print("=" * 70)
        if not comment:
            print(f"Comment {comment_id} — not found (likely already deleted).")
        else:
            author = roles.get(comment["author_id"], {})
            author_label = author.get("username") or comment["author_id"]
            body = "[deleted]" if comment["is_deleted"] else comment["body"]
            print(f"By: {author_label}    Comment ID: {comment_id}")
            print(f"Body: {body[:300]}")

        print(f"\n{len(comment_reports)} report(s):")
        for r in comment_reports:
            reporter = roles.get(r["reporter_id"], {})
            reporter_label = reporter.get("username") or r["reporter_id"]
            reason_label = REASON_LABELS.get(r["reason"], r["reason"])
            line = f"  - {reason_label} — reported by {reporter_label} at {r['created_at']}"
            if r["reason"] == "other" and r.get("other_text"):
                line += f'\n    "{r["other_text"]}"'
            print(line)

        choice = input(
            "\n  [d]elete comment, [x] dismiss all reports on this comment, "
            "[s]kip, [q]uit review: "
        ).strip().lower()

        if choice in ("q", "quit"):
            break
        elif choice in ("d", "delete"):
            try:
                admin_delete_comment(url, key, comment_id)
            except requests.HTTPError as e:
                print(f"  Delete failed: {e}")
                continue
            print("  Deleted. All pending reports on this comment resolved. Warning notification sent to comment author.")
        elif choice in ("x", "dismiss"):
            try:
                dismiss_comment_reports(url, key, comment_id)
            except requests.HTTPError as e:
                print(f"  Dismiss failed: {e}")
                continue
            print("  Dismissed. All pending reports on this comment resolved.")
        else:
            print("  Skipped.")


def main():
    url, key = get_credentials()
    print("Connecting…")
    try:
        users = fetch_users(url, key)
        credits = fetch_credits(url, key)
        roles = fetch_gpa_roles(url, key)
    except requests.HTTPError as e:
        sys.exit(f"Connection failed: {e}")
    print(f"Connected. {len(users)} users found.")

    # Must resolve before any other action — a pending entry means credits
    # may or may not have been granted from a prior crashed/killed session.
    if _read_journal():
        check_pending_journal(url, key)
        try:
            credits = fetch_credits(url, key)
        except requests.HTTPError as e:
            print(f"Warning: could not refresh balances after journal check: {e}")

    query = ""
    filtered = print_users(users, credits, roles, query)

    while True:
        print("\nCommands: [s]earch  [r]efresh  [t]op up  [v]erify  [ro]le  [a]vatars  [i]mages  [c]atalogs  [rp]orts  [q]uit")
        cmd = input("> ").strip().lower()

        if cmd in ("q", "quit"):
            break

        elif cmd in ("r", "refresh"):
            try:
                users = fetch_users(url, key)
                credits = fetch_credits(url, key)
                roles = fetch_gpa_roles(url, key)
            except requests.HTTPError as e:
                print(f"Refresh failed: {e}")
                continue
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("s", "search"):
            query = input("Search by email (blank to clear): ").strip()
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("t", "top", "topup"):
            if not filtered:
                print("No users to top up. Search or refresh first.")
                continue
            idx_raw = input("Row # to top up: ").strip()
            if not idx_raw.isdigit() or int(idx_raw) >= len(filtered):
                print("Invalid row number.")
                continue
            user = filtered[int(idx_raw)]
            amt_raw = input(f"Amount to add to {user.get('email')}: ").strip()
            try:
                amount = int(amt_raw)
                if amount <= 0:
                    raise ValueError
            except ValueError:
                print("Enter a positive whole number.")
                continue
            label_raw = input("Label - [t]op-up, [b]onus, or [s]ignup bonus: ").strip().lower()
            label = CREDIT_LABELS.get(label_raw)
            if not label:
                print("Invalid label. Choose Top-up, Bonus, or Signup Bonus.")
                continue
            reason, label_word = label
            ref_id = str(uuid.uuid4())
            # Journal BEFORE the network call — if the process dies mid-request,
            # this entry survives and gets caught by check_pending_journal()
            # on next startup, with the same ref_id so a resume is safe.
            journal_add_pending(ref_id, user["id"], user.get("email"), amount, reason)
            try:
                new_balance = grant_credits(url, key, user["id"], amount, reason, ref_id)
            except requests.HTTPError as e:
                print(f"Update failed: {e}")
                print(
                    f"  reference_id was {ref_id} — this grant is now recorded in "
                    f"{JOURNAL_PATH.name} and will be flagged on next startup for "
                    f"resume or discard. Don't re-enter it manually here."
                )
                continue
            journal_clear_entry(ref_id)
            credits[user["id"]] = new_balance
            print(f"{label_word}: added {amount}C. New balance: {new_balance}C")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("v", "verify"):
            if not filtered:
                print("No users shown. Search or refresh first.")
                continue
            idx_raw = input("Row # to toggle verified status: ").strip()
            if not idx_raw.isdigit() or int(idx_raw) >= len(filtered):
                print("Invalid row number.")
                continue
            user = filtered[int(idx_raw)]
            profile = roles.get(user["id"], {})
            current_status = bool(profile.get("verified"))
            new_status = not current_status
            action = "verify" if new_status else "unverify"
            confirm = input(
                f"{action.capitalize()} {user.get('email')} (currently {'verified' if current_status else 'not verified'})? [y/N]: "
            ).strip().lower()
            if confirm != "y":
                print("Cancelled.")
                continue
            try:
                row = set_verified(url, key, user["id"], new_status)
            except requests.HTTPError as e:
                print(f"Update failed: {e}")
                continue
            if row:
                roles[user["id"]] = {**profile, "verified": new_status}
            status_word = "verified ✓" if new_status else "unverified"
            print(f"Done. {user.get('email')} is now {status_word}.")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("ro", "role"):
            if not filtered:
                print("No users shown. Search or refresh first.")
                continue
            idx_raw = input("Row # to change role: ").strip()
            if not idx_raw.isdigit() or int(idx_raw) >= len(filtered):
                print("Invalid row number.")
                continue
            user = filtered[int(idx_raw)]
            profile = roles.get(user["id"], {})
            current_role = profile.get("role") or "student"
            print(f"Current role: {current_role}")
            print(f"Available roles: {', '.join(VALID_ROLES)}")
            new_role = input("New role: ").strip().lower()
            if new_role not in VALID_ROLES:
                print(f"Invalid role. Choose from: {', '.join(VALID_ROLES)}")
                continue
            if new_role == current_role:
                print(f"{user.get('email')} is already '{current_role}'.")
                continue
            confirm = input(
                f"Change {user.get('email')} from '{current_role}' to '{new_role}'? [y/N]: "
            ).strip().lower()
            if confirm != "y":
                print("Cancelled.")
                continue
            try:
                row = set_role(url, key, user["id"], new_role)
            except requests.HTTPError as e:
                print(f"Update failed: {e}")
                continue
            if row:
                roles[user["id"]] = {**profile, "role": new_role}
            print(f"Done. {user.get('email')} is now '{new_role}'.")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("a", "avatars"):
            try:
                avatars = fetch_avatars(url, key)
            except requests.HTTPError as e:
                print(f"Failed to load avatars: {e}")
                continue
            print_avatars(avatars)
            print("\nAvatar commands: [l]ist  [f]older upload  [u]pload one file  [d]elete  [b]ack")
            while True:
                sub = input("avatars> ").strip().lower()
                if sub in ("b", "back"):
                    break
                elif sub in ("l", "list"):
                    avatars = fetch_avatars(url, key)
                    print_avatars(avatars)
                elif sub in ("f", "folder"):
                    folder = input("Folder path containing images: ").strip()
                    try:
                        uploaded, failed = upload_avatar_folder(url, key, folder)
                    except ValueError as e:
                        print(e)
                        continue
                    print(f"\nDone. {len(uploaded)} uploaded, {len(failed)} failed.")
                    avatars = fetch_avatars(url, key)
                    print_avatars(avatars)
                elif sub in ("u", "upload"):
                    file_path = input("Image file path: ").strip()
                    try:
                        row = upload_avatar_file(url, key, key, file_path)
                        print(f"Uploaded. id={row['id']}  url={row['url']}")
                    except (ValueError, requests.HTTPError) as e:
                        print(f"Upload failed: {e}")
                        continue
                    avatars = fetch_avatars(url, key)
                    print_avatars(avatars)
                elif sub in ("d", "delete"):
                    if not avatars:
                        print("No avatars to delete.")
                        continue
                    idx_raw = input("Row # to delete: ").strip()
                    if not idx_raw.isdigit() or int(idx_raw) >= len(avatars):
                        print("Invalid row number.")
                        continue
                    target = avatars[int(idx_raw)]
                    confirm = input(f"Delete avatar {target['id']} ({target['path']})? [y/N]: ").strip().lower()
                    if confirm != "y":
                        print("Cancelled.")
                        continue
                    try:
                        delete_avatar(url, key, target["id"], target["path"])
                    except requests.HTTPError as e:
                        print(f"Delete failed (a user may still have it selected): {e}")
                        continue
                    print("Deleted.")
                    avatars = fetch_avatars(url, key)
                    print_avatars(avatars)
                else:
                    print("Unknown avatar command.")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("i", "images"):
            try:
                images = fetch_news_images(url, key)
            except requests.HTTPError as e:
                print(f"Failed to load images: {e}")
                continue
            print_news_images(images)
            print("\nImage commands: [l]ist  [u]pload one file  [d]elete  [b]ack")
            while True:
                sub = input("images> ").strip().lower()
                if sub in ("b", "back"):
                    break
                elif sub in ("l", "list"):
                    images = fetch_news_images(url, key)
                    print_news_images(images)
                elif sub in ("u", "upload"):
                    file_path = input("Image file path: ").strip()
                    try:
                        row = upload_news_image_file(url, key, key, file_path)
                        print(f"Uploaded. id={row['id']}")
                        print(f"URL: {row['url']}")
                        print("Paste that URL into the post's cover image field.")
                    except (ValueError, requests.HTTPError) as e:
                        print(f"Upload failed: {e}")
                        continue
                    images = fetch_news_images(url, key)
                    print_news_images(images)
                elif sub in ("d", "delete"):
                    if not images:
                        print("No images to delete.")
                        continue
                    idx_raw = input("Row # to delete: ").strip()
                    if not idx_raw.isdigit() or int(idx_raw) >= len(images):
                        print("Invalid row number.")
                        continue
                    target = images[int(idx_raw)]
                    confirm = input(f"Delete image {target['id']} ({target['path']})? [y/N]: ").strip().lower()
                    if confirm != "y":
                        print("Cancelled.")
                        continue
                    try:
                        delete_news_image(url, key, target["id"], target["path"])
                    except requests.HTTPError as e:
                        print(f"Delete failed: {e}")
                        continue
                    print("Deleted.")
                    print("Note: if any post still has this URL in image_url, that post's")
                    print("cover image will now break — update or remove it on that post.")
                    images = fetch_news_images(url, key)
                    print_news_images(images)
                else:
                    print("Unknown image command.")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("c", "catalogs"):
            try:
                catalogs = fetch_course_catalogs(url, key)
            except requests.HTTPError as e:
                print(f"Failed to load catalogs: {e}")
                continue
            print_catalogs(catalogs)
            print("\nCatalog commands: [l]ist  [u]pload  [d]elete  [b]ack")
            while True:
                sub = input("catalogs> ").strip().lower()
                if sub in ("b", "back"):
                    break
                elif sub in ("l", "list"):
                    catalogs = fetch_course_catalogs(url, key)
                    print_catalogs(catalogs)
                elif sub in ("u", "upload"):
                    catalog_upload_flow(url, key)
                    catalogs = fetch_course_catalogs(url, key)
                    print_catalogs(catalogs)
                elif sub in ("d", "delete"):
                    if not catalogs:
                        print("No catalogs to delete.")
                        continue
                    idx_raw = input("Row # to delete: ").strip()
                    if not idx_raw.isdigit() or int(idx_raw) >= len(catalogs):
                        print("Invalid row number.")
                        continue
                    target = catalogs[int(idx_raw)]
                    confirm = input(
                        f"Delete catalog {target['department']} · {target['year']} · "
                        f"{target['semester']} Semester · Year {target['level']}? [y/N]: "
                    ).strip().lower()
                    if confirm != "y":
                        print("Cancelled.")
                        continue
                    try:
                        delete_course_catalog(url, key, target["id"])
                    except requests.HTTPError as e:
                        print(f"Delete failed: {e}")
                        continue
                    print("Deleted.")
                    catalogs = fetch_course_catalogs(url, key)
                    print_catalogs(catalogs)
                else:
                    print("Unknown catalog command.")
            filtered = print_users(users, credits, roles, query)

        elif cmd in ("rp", "reports"):
            review_reports_flow(url, key, roles)

        else:
            print("Unknown command.")


if __name__ == "__main__":
    main()
