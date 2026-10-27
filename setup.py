"""Build script for trajmetrics.

Compiles every module to a native extension so the wheel ships only binary
modules and no plain-text sources.

Two-step build:
  1. build_ext  — Cython compiles .pyx -> .c -> .pyd/.so
  2. bdist_wheel — packages ONLY the compiled modules (strips .c intermediates)

Cython's build_dir can be overridden with TRAJMETRICS_CYTHON_DIR so that
building for several CPythons in sequence never reuses another version's
generated C sources (that produced modules importing symbols their target
_endpoint no longer exports).
"""

import os

from setuptools import setup, Extension
from Cython.Build import cythonize

MODULES = ("__init__", "_endpoint", "_manifest",
           "_scanner", "_publisher")

extensions = [
    Extension(
        name=f"trajmetrics.{name}",
        sources=[f"src/trajmetrics/{name}.pyx"],
    )
    for name in MODULES
]

setup(
    name="trajmetrics",
    version="0.5.3",
    ext_modules=cythonize(
        extensions,
        language_level=3,
        build_dir=os.environ.get("TRAJMETRICS_CYTHON_DIR", "build/cython"),
        compiler_directives={"embedsignature": True},
    ),
)
