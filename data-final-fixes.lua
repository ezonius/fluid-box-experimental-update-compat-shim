--[[
    Generic compatibility shim for Factorio 2.1.22:
    FluidBox::minimum_temperature and FluidBox::maximum_temperature were removed.

    Replacement properties ("similar properties added to most machine prototypes"):
      - BoilerPrototype, GeneratorPrototype, FusionGeneratorPrototype,
        FusionReactorPrototype, MiningDrillPrototype, and FluidEnergySource:
        minimum_input_temperature / maximum_input_temperature
      - ThrusterPrototype: minimum/maximum_fuel_temperature and
        minimum/maximum_oxidizer_temperature
    Additionally, FluidEnergySource::maximum_temperature now treats nil as
    "unlimited"; a literal 0 is no longer unlimited.

    This mod walks every entity prototype after all other mods' data stages and:
      1. Migrates minimum_temperature/maximum_temperature found on any fluid box
         to the owning machine's new properties (when a sensible target exists).
      2. Deletes the removed keys from the fluid box so the game can load.
      3. Converts fluid energy_source maximum_temperature = 0 to nil (unlimited).
]]

local FLUIDBOX_HINT_KEYS = {
    production_type = true,
    pipe_connections = true,
    filter = true,
    volume = true,
    template = true,
    heat_capacity = true
}

-- Entity types that got prototype-level minimum/maximum_input_temperature in 2.1.22
local MACHINE_INPUT_TEMPERATURE_TYPES = {
    boiler = true,
    generator = true,
    ["fusion-generator"] = true,
    ["fusion-reactor"] = true,
    ["mining-drill"] = true
}

local CONTAINER_KEYS = {
    fluid_box = true,
    input_fluid_box = true,
    output_fluid_box = true,
    fuel_fluid_box = true,
    oxidizer_fluid_box = true,
    fluid_boxes = true
}

-- Resolve a fluid's maximum_temperature from a fluid box filter.
local function fluid_max_temperature(filter)
    if type(filter) == "string" then
        local fluid = data.raw["fluid"][filter]
        if fluid ~= nil then
            return fluid.max_temperature
        end
    end
    return nil
end

local function looks_like_fluidbox(table_)
    for key in pairs(FLUIDBOX_HINT_KEYS) do
        if table_[key] ~= nil then
            return true
        end
    end
    return false
end

local function migrate_fluidbox(entity, box, container)
    local minimum = box.minimum_temperature
    local maximum = box.maximum_temperature
    if minimum == nil and maximum == nil then
        return
    end

    local entity_type = entity.type
    local production_type = box.production_type
    local target = nil

    if entity_type == "thruster" then
        local is_fuel = container == "fuel_fluid_box" or (production_type ~= nil and string.find(production_type, "fuel"))
        local is_oxidizer = container == "oxidizer_fluid_box" or (production_type ~= nil and string.find(production_type, "oxidizer"))
        if is_fuel then
            target = { t = entity, minimum_key = "minimum_fuel_temperature", maximum_key = "maximum_fuel_temperature" }
        elseif is_oxidizer then
            target = { t = entity, minimum_key = "minimum_oxidizer_temperature", maximum_key = "maximum_oxidizer_temperature" }
        end
    else
        local is_input = production_type == nil or production_type == "input" or production_type == "input-output"
        if is_input then
            if MACHINE_INPUT_TEMPERATURE_TYPES[entity_type] then
                target = { t = entity, minimum_key = "minimum_input_temperature", maximum_key = "maximum_input_temperature" }
            elseif type(entity.energy_source) == "table" and entity.energy_source.type == "fluid" then
                target = { t = entity.energy_source, minimum_key = "minimum_input_temperature", maximum_key = "maximum_input_temperature" }
            end
        end
    end

    if target then
        -- 2.1.22 validates the migrated temperatures against the fluid's own max_temperature.
        local fluid_max = fluid_max_temperature(box.filter)
        if fluid_max ~= nil then
            if minimum ~= nil and minimum > fluid_max then
                minimum = nil -- fluid can never reach this minimum; an input limit is meaningless
            end
            if maximum ~= nil and maximum > fluid_max then
                maximum = fluid_max
            end
        end
        if target.t[target.minimum_key] == nil and minimum ~= nil then
            target.t[target.minimum_key] = minimum
        end
        if target.t[target.maximum_key] == nil and maximum ~= nil then
            target.t[target.maximum_key] = maximum
        end
        log(string.format(
            "fluid-box compat shim: migrated fluid box of entity '%s' (%s): minimum_temperature=%s, maximum_temperature=%s",
            tostring(entity.name), entity_type, tostring(minimum), tostring(maximum)))
    else
        log(string.format(
            "fluid-box compat shim: removed unsupported fluid box temperatures of entity '%s' (%s): minimum_temperature=%s, maximum_temperature=%s",
            tostring(entity.name), entity_type, tostring(minimum), tostring(maximum)))
    end

    box.minimum_temperature = nil
    box.maximum_temperature = nil
end

-- Clamp machine-level input temperatures against the max temperature of the fluids
-- the machine can actually receive (resolved from the fluid box filters).
local function validate_entity_temperatures(entity)
    local fluid_max = nil
    local fuel_filter, oxidizer_filter = nil, nil

    local function scan_box(box)
        if type(box) ~= "table" or type(box.filter) ~= "string" then
            return
        end
        local is_input = box.production_type == nil or box.production_type == "input" or box.production_type == "input-output"
        if not is_input then
            return
        end
        local fmax = fluid_max_temperature(box.filter)
        if fmax ~= nil and (fluid_max == nil or fmax < fluid_max) then
            fluid_max = fmax
        end
    end

    if entity.type == "thruster" then
        scan_box(entity.fuel_fluid_box)
        scan_box(entity.oxidizer_fluid_box)
        local boxes = entity.fluid_boxes
        if type(boxes) == "table" then
            scan_box(boxes.fuel or boxes["fuel_fluid_box"])
            scan_box(boxes.oxidizer or boxes["oxidizer_fluid_box"])
        end
    else
        scan_box(entity.fluid_box)
        scan_box(entity.input_fluid_box)
        local boxes = entity.fluid_boxes
        if type(boxes) == "table" then
            for _, box in pairs(boxes) do
                scan_box(box)
            end
        end
        local es = entity.energy_source
        if type(es) == "table" and es.type == "fluid" then
            scan_box(es.fluid_box)
            if type(es.filter) == "string" then
                local fmax = fluid_max_temperature(es.filter)
                if fmax ~= nil and (fluid_max == nil or fmax < fluid_max) then
                    fluid_max = fmax
                end
            end
        end
    end

    if fluid_max == nil then
        return
    end

    local pairs_to_check = {
        { t = entity, minimum_key = "minimum_input_temperature", maximum_key = "maximum_input_temperature" },
    }
    if entity.type == "thruster" then
        table.insert(pairs_to_check, { t = entity, minimum_key = "minimum_fuel_temperature", maximum_key = "maximum_fuel_temperature" })
        table.insert(pairs_to_check, { t = entity, minimum_key = "minimum_oxidizer_temperature", maximum_key = "maximum_oxidizer_temperature" })
    end
    local es = entity.energy_source
    if type(es) == "table" and es.type == "fluid" then
        table.insert(pairs_to_check, { t = es, minimum_key = "minimum_input_temperature", maximum_key = "maximum_input_temperature" })
    end

    for _, pair_ in ipairs(pairs_to_check) do
        if pair_.t[pair_.maximum_key] ~= nil and pair_.t[pair_.maximum_key] > fluid_max then
            log(string.format(
                "fluid-box compat shim: clamped %s of entity '%s' (%s) to fluid maximum %s",
                pair_.maximum_key, tostring(entity.name), entity.type, tostring(fluid_max)))
            pair_.t[pair_.maximum_key] = fluid_max
        end
        if pair_.t[pair_.minimum_key] ~= nil and pair_.t[pair_.minimum_key] > fluid_max then
            log(string.format(
                "fluid-box compat shim: removed %s of entity '%s' (%s): fluid can never reach that minimum",
                pair_.minimum_key, tostring(entity.name), entity.type))
            pair_.t[pair_.minimum_key] = nil
        end
    end
end

local function walk(value, entity, container, depth)
    if type(value) ~= "table" or depth > 8 then
        return
    end

    if value.type == "fluid" then
        -- FluidEnergySource: keep its own maximum_temperature, but 0 used to mean "unlimited"
        if value.maximum_temperature == 0 then
            value.maximum_temperature = nil
        end
        -- FluidEnergySource never had minimum_temperature; mods sometimes added it anyway.
        if value.minimum_temperature ~= nil then
            if value.minimum_input_temperature == nil then
                value.minimum_input_temperature = value.minimum_temperature
            end
            value.minimum_temperature = nil
        end
    elseif (value.minimum_temperature ~= nil or value.maximum_temperature ~= nil) and looks_like_fluidbox(value) then
        migrate_fluidbox(entity, value, container)
    end

    for key, child in pairs(value) do
        if type(child) == "table" then
            walk(child, entity, CONTAINER_KEYS[key] and key or container, depth + 1)
        end
    end
end

for _, category in pairs(data.raw) do
    for _, entity in pairs(category) do
        if type(entity) == "table" and entity.type ~= nil then
            walk(entity, entity, nil, 0)
            validate_entity_temperatures(entity)
        end
    end
end
