from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from sqlalchemy.orm import Session

from ccs_platform.db import models
from ccs_platform.core.settings import PlatformSettings
from ccs_platform.adapters.storage import StorageAdapter


@dataclass
class JobContext:
    settings: PlatformSettings
    storage: StorageAdapter
    assert_not_cancelled: Callable[[Session, int], None]
    update_progress: Callable[[Session, models.Job, int], None]
