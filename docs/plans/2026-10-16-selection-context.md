# Selection context implementation plan

Issue: [ISQ-459](https://linear.app/isqrd/issue/ISQ-459).

The approved change attaches selected saved text and its location to the existing
composer. Attachment is passive, retains unsent text, and cannot expand the
conversation's editable files. This plan travels with the implementation PR.

- [x] Inspect command routing, composer, selection extraction, source guards and tests.
- [x] Establish a clean focused baseline (five suites).
- [x] Add failing public-flow tests for captured text, scope/dirty/stale refusal,
  focus, draft preservation, size limits and explicit Send.
- [x] Reuse the native selection extractor through a pure internal API. Add
  `NvimAIChatAttach` for line ranges and visual `<leader>at` for exact selections.
- [x] Check scope and saved disk/buffer agreement before attaching; append a
  labeled snapshot as editable composer text. Preserve publisher and provider APIs.
- [x] Exercise character, line and block selections, hidden/reopened chat and
  the actual production Send route. Add a real-key TUI case and capture.
- [x] Update README.md and doc/draft.txt, record validation, run formatting and
  the full provider-free suite, then review the branch and open its PR.

Implementation reaches lua/ai/context.lua, lua/ai/chat.lua,
lua/ai/chat_view.lua and lua/ai/init.lua, plus public-flow/TUI tests and both usage
documents. No backend, publisher, configuration format or dependency is added.

The main failure cases are wrong/stale selection bytes, context from a file
outside scope, loss of an unsent draft, accidental submission, and focus changes
that turn selection keys into review decisions. The existing 32 KiB composer
limit applies to the entire message including context. Attached text is a snapshot
at capture time, not a live file reference or an expansion of edit permissions.
