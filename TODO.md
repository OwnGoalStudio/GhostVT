# TODO — App Intents (0.5.2)

- [x] `iGhostVT/Backend/Shortcuts/`: one-shot XPC client, `SessionEntity` + query, `KeyName` enum
- [x] Session intents: List, New, Send Text, Send Key, Get Screen Text, Kill
- [x] Composite intents: Run Command, Wait for Prompt, Is Session Busy, Get Session Directory
- [x] Foreground intents: Show Session, Open New Tab, Open App (scene picking seam)
- [x] `AppShortcutsProvider` with phrases; `ighostvt://` URL scheme
- [x] Share `ScreenRenderer` / `KeyNames` with the app target
- [x] `make check` + `make test`; commit; push
- [ ] `/ui-copy-polish` on the intent changes only (translate all 11 languages, clean stale text)
- [ ] `make set-version 0.5.2`, tag, release
- [ ] Ask `../owngoalpackages` to update the repo entry
