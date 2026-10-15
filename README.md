# Fluid Box 2.1.22 Compat Shim

Factorio **2.1.22** (experimental) removed `FluidBox::minimum_temperature` and
`FluidBox::maximum_temperature`. Mods that still set these properties (often
inherited from older prototype copies) fail to load with errors such as:

```
Error while loading entity prototype "steam-engine" (generator):
FluidBox minimum_temperature and maximum_temperature have been removed.
Similar properties have been added to most machine prototypes.
```

This mod is a **generic** shim: it does not target specific mods. After all
other mods have run their data stages, it scans every entity prototype in
`data.raw` and:

1. **Migrates** fluid-box `minimum_temperature` / `maximum_temperature` to the
   new replacement properties on the owning machine:
   - `boiler`, `generator`, `fusion-generator`, `fusion-reactor`,
     `mining-drill` → prototype-level `minimum_input_temperature` /
     `maximum_input_temperature`
   - entities with a **fluid** `energy_source` →
     `energy_source.minimum_input_temperature` / `maximum_input_temperature`
   - `thruster` → `minimum/maximum_fuel_temperature` and
     `minimum/maximum_oxidizer_temperature`
   - output-only fluid boxes have no replacement; the removed keys are deleted.
2. **Deletes** any leftover removed keys from fluid boxes so prototypes load.
3. **Converts** fluid energy-source `maximum_temperature = 0` (old "unlimited")
   to `nil` (new "unlimited").

Known affected mods (migrations are logged to the game log):

- `planet-muluna` (sets `steam-engine`/`steam-turbine` fluid box temperature,
  oxidized boiler, cryolab, recycling steam turbine)
- `quality-seeds` (fluid energy source on the space cultivator)
- `corrundum` (red steam engine)
- `fluid-nutrients`

Optional dependencies on these mods are declared only for load ordering, so
the shim always runs after they modify prototypes. Any other mod is covered
generically as long as it sets the properties during data/data-updates stage.

## Notes / limitations

- The shim runs in `data-final-fixes`. If a broken mod sets these properties
  in its *own* `data-final-fixes` stage and happens to load after this mod, add
  an optional dependency to this mod's `info.json` to fix ordering:
  `"? <that-mod-name>"`.
- Only the first fluid box's value migrates when a machine has several input
  boxes that each specify a temperature (later duplicates are dropped).
- Runtime (control stage) code in other mods that *reads*
  `fluid_box.minimum_temperature` off Lua prototypes will now see `nil`; that
  is out of scope for a data-stage shim.
