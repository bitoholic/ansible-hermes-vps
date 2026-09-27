"""Shared sibling-module loader for every scripts/ entry point that ever holds a decrypted secret in its
process memory (scripts/deploy, scripts/secrets, scripts/check_secrets_store.py).

Python puts the invoked script's own directory FIRST on sys.path. A file added there (json.py,
tempfile.py; msvcrt.py, which subprocess tries to import and which does not exist on Linux; an
extension module hermes_redact*.so, gitignored; a hermes_redact/ package) would be imported in place
of the real one, inside a process that holds the decrypted store. load_sibling() loads one scripts/*.py
module by its explicit path instead, never through sys.path, so nothing else can take its place.

This module cannot protect its OWN import, which is why each entry point still repeats a few lines
inline rather than importing them from here: `sys.dont_write_bytecode`, `sys.pycache_prefix` (also
stops an unchecked-hash .pyc planted in scripts/__pycache__ from being loaded in place of the source —
gitignored, so `git diff` stays clean) and the sys.path filter must all run *before* anything else is
imported, including this module, or the guard they provide would not yet be in effect when this file
itself is loaded. What every entry point safely shares from here on is load_sibling(): the part that
actually varies per call (which module to load) and is easy to get subtly wrong (module registration
order, which loader attribute to call) rather than the part that must run first and is the same three
statements everywhere.
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.realpath(__file__))


def load_sibling(name):
    """Load scripts/<name>.py from its explicit path (never through sys.path, so nothing else can take its place)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
