# Voice Companion (KOReader plugin)

Plain Lua (LuaJIT) plugin for KOReader: TTS via OpenAI-compatible APIs or the device voice, read-aloud, pronunciation coach and explanations.

## Commands
- Test: `luajit spec/run.lua`. There is no single-test filter: each spec is a `spec/*_spec.lua` file loaded by `spec/run.lua`.
- Lint: `luacheck .`
- Package: `tools/package.sh` → `dist/voicecompanion.koplugin.zip`
- **Verify:** `luajit spec/run.lua && luacheck .`
- Real-book check (sentence splitting, read-aloud groups, highlight = spoken text) on KOReader's own crengine, headless: `KOREADER=<koreader install dir> tools/crengine_check.sh book.epub stats|groups|sentences [page] [n]`. `stats` should report 0 odd ends and 0 mismatches. Run it after any change to `reader/booktext.lua` or the grouping in `features/readaloud.lua`. `KOREADER` is an extracted AppImage's `squashfs-root/usr/lib/koreader`. Project Gutenberg EPUBs work well as test books.

## Layout
- `main.lua`: plugin entry. It holds the menu, highlight and dictionary buttons, gestures (Dispatcher), and the lifecycle hooks.
- `voicecompanion/voice.lua`: the one place that makes sound. It handles cloud/local planning, cache, prefetch, and the `on_state` callback.
- `voicecompanion/async.lua`: forks blocking network work and polls for the result from the UI loop.
- `voicecompanion/features/`: readaloud, pronounce, explain
- `voicecompanion/ui/`: settings menu, `controlbar.lua` (the on-page playback bar)
- `voicecompanion/audio/`, `voicecompanion/tts/`: players and engines (Android over JNI, Linux CLI)
- `voicecompanion/reader/booktext.lua`: sentence walking and highlighting on crengine xpointers
- `spec/stubs.lua`: `package.preload` stubs for the KOReader modules. A new KOReader `require` in a module under test needs a stub here.

## Gotchas
- KOReader is not installed here. UI widgets (controlbar, dialogs) and the Android/JNI paths can't be run locally; only the logic is covered by specs, plus crengine text handling via `tools/crengine_check.sh`. Say so when reporting.
- KOReader frontend source for API lookups, if still present: `/tmp/claude-1001/-home-iman-dev-projects-misc/644c020f-49b5-42aa-9e45-281ca9640562/scratchpad/squashfs-root/usr/lib/koreader/frontend`
- `Async` children must never touch the UI, JNI or devices. They may only use files and sockets.
- `Voice:_halt()` silences playback without reporting a state change (it's used between sequence items). `stop()` also reports `"idle"`.
- The bar is a ReaderView view module plus a reader touch zone, not a modal widget, so taps elsewhere still turn pages.
- On a device, `cache/voicecompanion/timing.log` holds the request and playback timings, and `diagnostics.log` holds the crash markers from the Diagnostics tests.
- Commits: no AI co-author trailer.

## Compact instructions
When compacting, keep: current task, decisions made, changed files, failing tests.
