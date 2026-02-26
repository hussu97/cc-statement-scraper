from fastapi import APIRouter

from ccs_platform.api.v1.endpoints import (
    banks,
    categories,
    dashboard,
    diagnostics,
    exports,
    jobs,
    profiles,
    runtime_settings,
    schedules,
    statements,
    system,
    transactions,
)


router = APIRouter()
router.include_router(system.router)
router.include_router(profiles.router)
router.include_router(banks.router)
router.include_router(jobs.router)
router.include_router(statements.router)
router.include_router(transactions.router)
router.include_router(dashboard.router)
router.include_router(categories.router)
router.include_router(runtime_settings.router)
router.include_router(schedules.router)
router.include_router(exports.router)
router.include_router(diagnostics.router)

__all__ = ["router"]
