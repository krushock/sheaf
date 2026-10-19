# Contributing to Sheaf

Bug reports, ideas and pull requests are welcome. Please open an issue first for anything large, so we can agree on the approach before you spend time on it.

## Before you send a change

- Run `make test` (the engine tests) and `make build`. For changes to the engine, `make corpus` runs it over every PDF that ships with macOS and Xcode; it should report 0 problems.
- Match the style of the code around your change. Comments explain why, in plain sentences.
- New interface text goes through the string catalog. Run `make strings` and add a Russian translation in `Scripts/translations/` if you can; if you can't, say so in the pull request.
- If the change needs checking by hand, add it to [VERIFY.md](VERIFY.md).
- Never commit signing identities, team IDs, certificates, keys, passwords or tokens. Release settings come from the environment (see [RELEASING.md](RELEASING.md)).
- Use PDFs you made yourself, or the fixtures in `Packages/SheafKit/Tests/SheafKitTests/Fixtures`, for tests and screenshots. Never use other people's documents.

## Licensing of contributions

Sheaf is licensed under the GNU General Public License, version 3 or later ([LICENSE](LICENSE)). By submitting a contribution, you agree:
- that it is your own work, or that you have the right to submit it;
- that it is licensed under the GPL, version 3 or later;
- that the maintainer may also distribute it as part of Sheaf under other terms, such as those of the Mac App Store, which the GPL alone does not allow.
