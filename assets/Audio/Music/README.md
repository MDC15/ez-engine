# Music

Looping background tracks. WAV 48 kHz is the safe choice: the mixer plays
native-rate clips, anything else must be converted with `Audio.resample`
first (see `docs/api.md`). Keep files small — they decode fully to memory.
