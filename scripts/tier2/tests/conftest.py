"""Pytest configuration for Windows tests."""

import pytest


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line(
        "markers", "windows: mark test as requiring Windows golden image"
    )
