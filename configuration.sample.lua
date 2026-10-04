--[[
Voice Companion configuration
=============================

HOW TO USE
  1. Copy this file to "configuration.lua" in the same folder
     (on Android: /sdcard/koreader/plugins/voicecompanion.koplugin/).
  2. Put your API key below and change anything else you like.
  3. Restart KOReader.

  You can skip this file entirely: changing a setting in
  Tools → Voice Companion → Settings creates configuration.lua for you.
  Saving from the menu rewrites the whole file, so values are kept but
  comments you add are lost.

  configuration.lua is ignored by git, so your key is never committed and
  plugin updates never overwrite it.

  Anything you leave out uses the built-in default, so the file can be as
  short as:   return { providers = { openrouter = { api_key = "sk-or-…" } } }

  The file is plain Lua: strings in "quotes", numbers without, each entry
  ends with a comma, and lines starting with -- are comments.  If it has a
  mistake, Settings and Diagnostics show the error.
]]

return {
    -- Which provider below is used for AI voices and explanations.
    provider = "openrouter",

    providers = {
        -- OpenRouter: one key for many models. https://openrouter.ai/keys
        openrouter = {
            base_url = "https://openrouter.ai/api/v1",
            api_key = "sk-or-v1-PUT-YOUR-KEY-HERE",

            -- Model that writes pronunciation help and explanations.
            -- Fast and cheap is best here. Browse: https://openrouter.ai/models
            chat_model = "google/gemini-3.8-flash",

            -- Model that speaks.  https://openrouter.ai/models?output_modalities=speech
            --   "hexgrad/kokoro-82m"                  cheap, natural, 8 languages
            --   "openai/gpt-4o-mini-tts-2025-12-15"   supports speed and style instructions
            tts_model = "hexgrad/kokoro-82m",

            -- Voice name; must be one the speech model supports.
            -- Kokoro (first letter = language, second = gender):
            --   American English: af_heart, af_bella, af_nicole, af_sarah, af_sky,
            --                     am_adam, am_michael, am_eric, am_liam, am_onyx
            --   British English:  bf_emma, bf_isabella, bf_alice, bf_lily,
            --                     bm_george, bm_daniel, bm_lewis, bm_fable
            --   Spanish: ef_dora, em_alex   French: ff_siwis   Italian: if_sara, im_nicola
            --   Portuguese: pf_dora, pm_alex   Hindi: hf_alpha, hm_omega
            --   Japanese: jf_alpha, jm_kumo    Chinese: zf_xiaoxiao, zm_yunxi
            -- OpenAI: alloy, ash, ballad, coral, echo, fable, nova, onyx, sage, shimmer
            voice = "af_heart",

            -- "mp3" (smaller downloads) or "pcm" (raw audio).
            audio_format = "mp3",
            -- Only for "pcm": sample rate of the raw audio (24000 for Kokoro/OpenAI).
            sample_rate = 24000,

            -- Extra fields added to every speech request, for model-specific
            -- options.  Example for OpenAI gpt-4o-mini-tts:
            --   tts_extra = { instructions = "Read calmly, like an audiobook narrator." },
        },

        -- OpenAI directly. https://platform.openai.com/api-keys
        openai = {
            base_url = "https://api.openai.com/v1",
            api_key = "",
            chat_model = "gpt-4o-mini",
            tts_model = "gpt-4o-mini-tts",
            voice = "alloy",
            audio_format = "mp3",
        },

        -- Any other OpenAI-compatible server works the same way, e.g. a
        -- Kokoro-FastAPI server on your home network:
        -- homeserver = {
        --     base_url = "http://192.168.1.10:8880/v1",
        --     api_key = "not-needed",
        --     tts_model = "kokoro",
        --     voice = "af_heart",
        --     chat_model = "",
        -- },
    },

    -- Default voice: "cloud" (AI voice from the provider) or "local"
    -- (the device's own text-to-speech; works offline, no cost).
    voice_engine = "cloud",

    -- Device voice settings.
    local_tts = {
        -- Language tag of the device voice: "en-US", "en-GB", "fr-FR", …
        -- On Android it must be installed in Android's text-to-speech settings.
        language = "en-US",
        rate = 1.0,    -- 0.5 = half speed, 2.0 = double
        pitch = 1.0,
        -- Linux only: a command that writes a WAV file.  Placeholders:
        -- {text_file} {out} {lang} {rate_wpm}.  Empty = espeak-ng if installed.
        --   command = "piper --model ~/voices/en_US-amy-medium.onnx --output_file {out} < {text_file}",
        command = "",
    },

    -- Pronunciation coach.
    pronounce = {
        engine = "cloud",      -- voice used by the coach: "cloud" or "local"
        slow_speed = 0.7,      -- speed of the "slow" playback
    },

    -- Explanations by voice.
    explain = {
        language = "English",  -- language of the explanations
        max_context_chars = 6000,  -- how much surrounding book text is sent
        speak_answer = true,   -- read the answer aloud automatically
    },

    -- Reading the book aloud.
    read_aloud = {
        engine = "cloud",
        highlight = true,          -- highlight the sentence being read
        -- Sentences are grouped into requests of about this many characters
        -- (0 = one sentence each).  Larger groups: fewer requests, fewer
        -- pauses, and a steadier AI voice; the whole group is highlighted.
        chunk_chars = 300,
        prefetch = 2,              -- groups fetched ahead (cloud voices)
        parallel = 2,              -- requests at once while fetching ahead
    },

    -- Cut the silence some models (Gemini TTS) add before and after each
    -- clip, which is heard as a pause between sentences.  pcm audio only.
    trim_silence = true,

    timeout = 60,    -- seconds to wait for one network request
    cache_mb = 50,   -- audio kept on disk so repeats are free
}
