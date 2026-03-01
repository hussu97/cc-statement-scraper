"""Bank-specific browser download handlers."""

from __future__ import annotations

import importlib
import pkgutil
from pathlib import Path

from scraper.banks.base import BankAdapter


def discover_adapters() -> dict[str, BankAdapter]:
    """Auto-discover all bank adapters in this package.

    Scans every sub-module of :mod:`scraper.banks.adapters` and collects
    modules that expose an ``ADAPTER`` attribute of type :class:`BankAdapter`.
    Returns a mapping of ``{BANK_CODE: BankAdapter}``.

    Adding a new bank requires only:
    1. Creating a new module in this package.
    2. Defining ``ADAPTER = BankAdapter(...)`` at module level.

    No changes to ``downloader.py`` or this file are needed.
    """
    adapters: dict[str, BankAdapter] = {}
    package_path = str(Path(__file__).parent)
    package_name = __name__

    for module_info in pkgutil.iter_modules([package_path]):
        module_name = f"{package_name}.{module_info.name}"
        try:
            module = importlib.import_module(module_name)
        except Exception:  # noqa: BLE001
            continue

        adapter = getattr(module, "ADAPTER", None)
        if isinstance(adapter, BankAdapter):
            adapters[adapter.code] = adapter

    return adapters
