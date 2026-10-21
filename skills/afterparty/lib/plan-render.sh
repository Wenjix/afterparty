# shellcheck shell=bash
# Rendering replays the captured document; no policy or discovery runs here.
plan_render_markdown() { cat "$1/document"; }
