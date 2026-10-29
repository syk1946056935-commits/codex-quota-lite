# Changelog

## 1.0.4

- Prepare the plugin for public distribution without machine-specific user paths.
- Add an installer that resolves Node.js and stages a versioned local deployment.
- Use a separate community marketplace ID to avoid overwriting personal development installs.
- Add MIT license, installation and privacy documentation, and Windows/Linux test workflows.

## 1.0.3

- Move floating-window quota reads off the WPF UI thread and cancel them on close.
- Bind the widget to the Codex desktop process identity, excluding standalone CLIs and reused PIDs.
- Keep all quota pools, prefer Codex, and allow switching between pools.
