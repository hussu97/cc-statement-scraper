# Changelog

## [Unreleased]

### Backend

- **security** Remove hardcoded `"Apple123!"` fallback password in `auth/service.py`; raise `RuntimeError` at startup if a login credential env var is absent in production (ROADMAP 1.1)
- **security** Add `session.rollback()` on exception in `get_db` FastAPI dependency so partial writes are never committed on error (ROADMAP 1.2)
- **security** Validate `CCS_PLATFORM_SESSION_SECRET_KEY` at startup in production — raises `RuntimeError` if the value is the insecure default or shorter than 32 bytes (ROADMAP 1.3)
- **security** Eliminate thread-unsafe `os.environ` mutation for bank credential injection; credentials are now fetched as a plain dict and passed explicitly through the adapter call chain so concurrent worker threads cannot corrupt each other's credentials (ROADMAP 1.4)
- **security** Upload endpoint (`POST /jobs/upload`) now loads ADCB PDF passwords from the `runtime_settings` table instead of `os.environ`, so credentials updated via the admin UI are reflected without a restart (ROADMAP 1.5)
