# Tomodachi Life: Living the Dream (`010051F0207B2000`)

Update 1.0.4 (v262144) over the base game, SDK 20.5.3. Nintendo's sead / agl / gsys engine (NintendoWare G3d2 / Ui2d / Vfx2, Havok) on NVN. Modules `main` and `sdk`. Draws its own Mii heads (`Model/MiiHead*.bfres.zs`, about 6,000 Mii model and texture files); it reads the console's Mii database only to import Miis (`Database::GetCount` source 1, empty on the host) and never mounts the MiiModel system data. Runs at 30 fps as on the Switch.

Bring-up on a Mac (M3 Pro), 2026-10-27, from the provisional profile:

- **Boot:** `oe::EnableAlbumImageTakenNotification` crashed on the Prepare Thread (the SDK's version reads the am proxy the host never made): now a no-op (`hle_oe.c`). `time::ClockSnapshot::CreateWithAdjustableSystemClock` and the adjustable clocks' `Adjust` aborted without the time service (`hle_time.c`).
- **`render_cond on`:** `SetRenderEnableConditional` from the first scenes.
- **`font_engine_lock on`:** `UpdateTextureCacheThread` (priority 45, mask 0x7, core 0) renders glyphs while the `Scene Prepare Thread` (50, core 0) measures text, with one `fontll::ScalableFontEngine` and no lock; the Switch never runs the two side by side. About one boot in two crashed in `FSS_get_advance` (sdk+0x37cdfc); 0 in 8 with the lock (`hle_fontll.c`).
- **`dup_slot_shadow on`:** the passes that make its 256x256 face and icon textures (a new one every few frames) attach one texture at colour slots 0 and 1 and write its alpha through slot 1 (mask 0x8). Left unattached (as for Breath of the Wild's write-mask-0 duplicates), the alpha writes were lost and green blocks showed; the duplicate slot now draws into a shadow merged back with its write mask (`nvn_mtl.m` `dsh_attach`).
- **"Your system time has changed since the last time you played" at every start:** the check at main+0x871410 takes `CalculateSpanBetween` as a bool (`tbz w0, #0`); the host answered it as a Result, 0 = false. It also compares the saved and new snapshots' user clock contexts and their offsets, so the host's steady clock now runs from a real-time base and its contexts carry one time point in every run (`hle_time.c`).
- Not seen in play yet: 2 of 14,388 shaders failed to translate (global memory store / load without a storage buffer), and 188 have a binding whose slot was not decoded (`tex_dyn_slots` is off).
