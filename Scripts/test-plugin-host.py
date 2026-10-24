#!/usr/bin/env python3
"""Run the opt-in, local-only plugin regression suite when it is present."""
from pathlib import Path
import runpy

suite = Path(__file__).resolve().parents[1] / 'Tests/PluginHostRegression/test-plugin-host.py'
if not suite.is_file():
    raise SystemExit('Local plugin tests are not installed in Tests/PluginHostRegression.')
runpy.run_path(str(suite), run_name='__main__')
