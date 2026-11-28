# Contributing to Tessera

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Report a bug or ask for something

Open an [issue](https://github.com/vik101/Tessera/issues). For a bug, include what you did, what you expected, what happened, your Tessera and macOS versions, and Tessera's log ([how](docs/troubleshooting.md#report-a-bug)).

## Change the code

1. Read [Developing Tessera](docs/development.md): how the code fits together, and how to build and test it.
2. Make the change. Almost every behaviour change belongs in `Sources/TesseraCore`, which has no AppKit and fast tests.
3. Add a test in `Tests/TesseraCoreTests`, and run `swift test`.
4. If you changed a command, run `python3 scripts/docs/commands.py` to update `docs/commands.md`.
5. Update the docs page your change touches, and add a line to `CHANGELOG.md`.
6. Open a pull request. CI builds it, runs the unit tests and about 880 checks against real windows on macOS 15 and 26.

## Write docs

The docs in `docs/` are for people using Tessera, not for its code.

- **Plain words, short sentences.** Aim for a reader of about ten. Keep a technical word only when there's no plain one, and explain it the first time.
- **Lead with the point.** The first sentence of each page and section says what it gives the reader.
- **Show shapes as pictures.** A layout, a flow or a before-and-after is a picture (`scripts/docs/images.py`) or a Mermaid diagram, not a paragraph.
- **Tables for things to look up,** lists only for steps or parallel items.
- **Check every fact against the code.** A wrong doc is worse than none.
