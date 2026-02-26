from __future__ import annotations

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ccs_platform.db import models


DEFAULT_PROFILE_KEY = "alice"
SECONDARY_PROFILE_KEY = "bob"

DEFAULT_PROFILES: tuple[tuple[str, str, bool], ...] = (
    (DEFAULT_PROFILE_KEY, "Alice", True),
    (SECONDARY_PROFILE_KEY, "Bob", False),
)


def _normalize_profile_key(value: str) -> str:
    return value.strip().lower()


def ensure_profile_seeds(db: Session) -> None:
    existing = {row.key: row for row in db.execute(select(models.Profile)).scalars().all()}
    created_keys: set[str] = set()

    for key, name, is_default in DEFAULT_PROFILES:
        row = existing.get(key)
        if row is None:
            row = models.Profile(key=key, name=name, is_default=is_default)
            db.add(row)
            db.flush()
            existing[key] = row
            created_keys.add(key)
            continue
        row.name = name
        row.is_default = is_default

    # Enforce only one default profile.
    default_count = 0
    for row in existing.values():
        if row.is_default:
            default_count += 1
            if default_count > 1:
                row.is_default = False

    alice = existing.get(DEFAULT_PROFILE_KEY)
    if alice and not alice.is_default:
        alice.is_default = True

    banks = db.execute(select(models.Bank.code).order_by(models.Bank.code.asc())).scalars().all()
    if not banks:
        return

    if DEFAULT_PROFILE_KEY in created_keys:
        alice_profile = existing[DEFAULT_PROFILE_KEY]
        for bank_code in banks:
            db.add(models.ProfileBank(profile_id=alice_profile.id, bank_code=bank_code))


def get_default_profile(db: Session) -> models.Profile:
    row = db.execute(
        select(models.Profile)
        .where(models.Profile.is_default.is_(True))
        .order_by(models.Profile.id.asc())
    ).scalar_one_or_none()
    if row is not None:
        return row

    row = db.execute(
        select(models.Profile).where(models.Profile.key == DEFAULT_PROFILE_KEY).order_by(models.Profile.id.asc())
    ).scalar_one_or_none()
    if row is not None:
        return row
    raise RuntimeError("No profile records found")


def get_profile_by_key(db: Session, profile_key: str) -> models.Profile | None:
    normalized = _normalize_profile_key(profile_key)
    if not normalized:
        return None
    return db.execute(
        select(models.Profile).where(models.Profile.key == normalized)
    ).scalar_one_or_none()


def list_profiles_with_banks(db: Session) -> list[tuple[models.Profile, list[str]]]:
    profiles = db.execute(select(models.Profile).order_by(models.Profile.id.asc())).scalars().all()
    if not profiles:
        return []

    profile_ids = [row.id for row in profiles]
    mappings = db.execute(
        select(models.ProfileBank.profile_id, models.ProfileBank.bank_code)
        .where(models.ProfileBank.profile_id.in_(profile_ids))
        .order_by(models.ProfileBank.bank_code.asc())
    ).all()

    banks_by_profile: dict[int, list[str]] = {profile_id: [] for profile_id in profile_ids}
    for profile_id, bank_code in mappings:
        banks_by_profile.setdefault(profile_id, []).append(bank_code)

    return [(profile, banks_by_profile.get(profile.id, [])) for profile in profiles]


def replace_profile_banks(db: Session, *, profile_key: str, bank_codes: list[str]) -> tuple[models.Profile, list[str]]:
    profile = get_profile_by_key(db, profile_key)
    if profile is None:
        raise KeyError(profile_key)

    normalized = sorted({token.upper().strip() for token in bank_codes if token and token.strip()})
    if normalized:
        valid_codes = set(
            db.execute(
                select(models.Bank.code).where(models.Bank.code.in_(normalized))
            ).scalars().all()
        )
        unknown = [code for code in normalized if code not in valid_codes]
        if unknown:
            raise ValueError(f"Unknown bank codes: {', '.join(unknown)}")

    db.execute(delete(models.ProfileBank).where(models.ProfileBank.profile_id == profile.id))
    for bank_code in normalized:
        db.add(models.ProfileBank(profile_id=profile.id, bank_code=bank_code))
    db.flush()
    return profile, normalized
