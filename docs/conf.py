# Configuration file for the Sphinx documentation builder (Read the Docs builds
# this directory; the pages are the plain Markdown files beside this file, so they
# read the same on GitHub and on https://rocelet.ethernetfmc.com).
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

numfig = True

# -- Project information -----------------------------------------------------

project = 'rocelet'
copyright = '2026, Opsero Electronic Design Inc.'
author = 'Jeff Johnson'

# -- General configuration ---------------------------------------------------

extensions = [
  'myst_parser',
]

# Generate anchors for headings up to level 4 so that the pages can link to
# each other's sections with plain markdown links (page.md#section-slug).
myst_heading_anchors = 4

templates_path = ['_templates']

# Build products and the diagram generator are not pages.
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

# -- Options for HTML output -------------------------------------------------

html_theme = 'sphinx_rtd_theme'

# (no custom static files: an empty list keeps the build free of a
# 'html_static_path entry does not exist' warning)
html_static_path = []
