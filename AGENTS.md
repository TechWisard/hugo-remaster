# Project working rules

Build a faithful remaster of Hugo: Black Diamond Fever, starting with a reliable
resource pipeline and a playable Godot project. Report milestones according to
what actually runs; the development course is not a recovered original level.

- Keep original game images, containers, textures, models, audio, videos and
  derived screenshots out of Git. Import them locally into ignored directories.
- Never execute binaries from an original game distribution during extraction.
- Do not add automatic game downloads, authentication secrets or absolute local
  workspace paths to tracked files.
- Do not enable GitHub Actions or upload Actions artifacts. Run validation locally.
- Preserve the distinction between verified format fields and uncertain semantics.
- Run the importer tests and Godot scene smoke test when changing their behavior.
- Keep a clean-checkout fallback playable without original assets.
- Add Russian user instructions and honest limitations for each delivered milestone.
- Prefer cohesive playable improvements to cosmetic changes or duplicated checks.
